import Foundation
import Observation

/// Per-eventId state for the post-submit zap animation. Owns the in-flight Task
/// so the zap survives `ZapSheet` dismissal — without this, the sheet's `.onDisappear`
/// would tear down the Task that was awaiting `ZapSender.sendZap` and the payment
/// would silently cancel mid-flight.
///
/// PostCardView reads `inFlight.contains(eventId)` to swap in the pulsing bolt and
/// `bursting.contains(eventId)` to render the success burst. Errors land in
/// `errors[eventId]` and are surfaced via the card's existing `actionAlert`.
///
/// Mirrors the Android `SocialActionManager._zapInProgress` / `_zapSuccess` /
/// `_zapError` triplet.
@Observable
@MainActor
final class ZapAnimationStore {
    static let shared = ZapAnimationStore()

    /// Event ids whose zap is currently in flight. Drives the pulsing bolt.
    private(set) var inFlight: Set<String> = []
    /// Event ids currently rendering the success burst. Auto-cleared 1.1 s after success.
    private(set) var bursting: Set<String> = []
    /// Per-eventId error message; PostCardView observes its entry and clears it
    /// once it's hoisted into the alert.
    private(set) var errors: [String: String] = [:]
    /// Catch-all error message for callers without an event id (live-stream host
    /// zap, profile zap). Not yet rendered — kept so we don't drop errors silently.
    private(set) var lastErrorBanner: String?

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Tasks for `eventId == nil` callers, keyed by `recipientPubkey + amountSats + ts`.
    @ObservationIgnored private var anonymousTasks: [UUID: Task<Void, Never>] = [:]

    /// Burst duration (s). Matches Android `LightningOverlay.kt` 1100 ms tween.
    private let burstDuration: TimeInterval = 1.1

    private init() {}

    /// Hand off the zap. Returns immediately; the underlying `ZapSender.sendZap`
    /// runs on a retained Task. `eventId == nil` is allowed (profile / live-stream
    /// host zaps) — those skip per-id state but still play sound + haptic on success.
    func send(
        keypair: Keypair,
        wallet: WalletStore,
        recipientPubkey: String,
        recipientLud16: String?,
        eventId: String?,
        amountSats: Int64,
        message: String = "",
        relayHints: [String] = [],
        extraTags: [[String]] = [],
        isAnonymous: Bool = false,
        isPrivate: Bool = false,
        onSuccessSats: ((Int64) -> Void)? = nil
    ) {
        if let eventId, inFlight.contains(eventId) {
            // Re-entrancy guard. The bolt is already pulsing for this event;
            // a second submit would just duplicate the payment.
            return
        }
        if let eventId {
            inFlight.insert(eventId)
            errors.removeValue(forKey: eventId)
        }

        let task = Task { [weak self] in
            let result = await ZapSender.sendZap(
                keypair: keypair,
                wallet: wallet,
                recipientPubkey: recipientPubkey,
                recipientLud16: recipientLud16,
                eventId: eventId,
                amountSats: amountSats,
                message: message,
                relayHints: relayHints,
                extraTags: extraTags,
                isAnonymous: isAnonymous,
                isPrivate: isPrivate
            )
            guard let self else { return }
            // Cooperative-cancellation guard: cancelAll() (account switch / logout)
            // must not fire success haptic + sound on the next user's screen.
            if Task.isCancelled { return }

            if let eventId {
                self.inFlight.remove(eventId)
            }

            switch result {
            case .success:
                Haptics.shared.zapBuzz()
                NotificationSounds.shared.play(.zap)
                onSuccessSats?(amountSats)
                if let eventId {
                    self.bursting.insert(eventId)
                    // Per-eventId clear so two concurrent bursts don't race a
                    // shared timer.
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(self?.burstDuration ?? 1.1))
                        self?.bursting.remove(eventId)
                    }
                }
            case .failure(let err):
                if let eventId {
                    self.errors[eventId] = err.localizedDescription
                } else {
                    self.lastErrorBanner = err.localizedDescription
                }
            }

            if let eventId {
                self.tasks.removeValue(forKey: eventId)
            }
        }

        if let eventId {
            tasks[eventId] = task
        } else {
            let key = UUID()
            anonymousTasks[key] = task
            // Clean up on completion so the dictionary doesn't grow unbounded.
            Task { [weak self] in
                _ = await task.value
                self?.anonymousTasks.removeValue(forKey: key)
            }
        }
    }

    /// PostCardView calls this once it has hoisted the error into its alert,
    /// so the alert doesn't re-fire on subsequent reads of the same value.
    func clearError(eventId: String) {
        errors.removeValue(forKey: eventId)
    }

    func clearLastErrorBanner() {
        lastErrorBanner = nil
    }

    /// Cancel every in-flight zap and reset state. Called from the account-switch
    /// and logout paths so user A's pending zap doesn't fire its success effects
    /// (haptic, thunder sound, burst) on user B's screen after a switch.
    func cancelAll() {
        for task in tasks.values { task.cancel() }
        for task in anonymousTasks.values { task.cancel() }
        tasks.removeAll()
        anonymousTasks.removeAll()
        inFlight.removeAll()
        bursting.removeAll()
        errors.removeAll()
        lastErrorBanner = nil
    }
}
