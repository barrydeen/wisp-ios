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
                SuccessToast.shared.show(
                    "Zapped \(amountSats.formatted()) \(amountSats == 1 ? "sat" : "sats")",
                    icon: "bolt.fill",
                    accent: .wispZapColor
                )
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
                let friendly = Self.friendlyMessage(for: err.localizedDescription)
                if let eventId {
                    self.errors[eventId] = friendly
                } else {
                    self.lastErrorBanner = friendly
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

    /// Map raw SDK / sender error strings into user-readable copy. The
    /// underlying wallet stack (Spark, NWC) surfaces nested Swift type
    /// descriptions like `BreezSdkSpark.SdkError.SparkError("Tree service
    /// error: insufficient funds")` which is noise to a non-developer.
    /// Pattern-match the well-known failure modes and fall back to a
    /// cleaned-up version of the original string for everything else.
    static func friendlyMessage(for raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("insufficient funds") || lower.contains("insufficient balance") {
            return "Not enough sats in your wallet."
        }
        if lower.contains("no route") || lower.contains("route not found") || lower.contains("unreachable") {
            return "Couldn't find a payment route to the recipient. Try again later."
        }
        if lower.contains("expired") || lower.contains("invoice has expired") {
            return "The lightning invoice expired before it could be paid. Try again."
        }
        if lower.contains("timeout") || lower.contains("timed out") {
            return "The payment timed out. Check your connection and try again."
        }
        if lower.contains("no lud16") || lower.contains("no lightning address") {
            return "This account doesn't have a lightning address."
        }
        if lower.contains("lnurl") && lower.contains("400") {
            return "The recipient's lightning provider rejected this zap. Try a different amount."
        }
        if lower.contains("amount too small") || lower.contains("below minimum") {
            return "Amount is below the recipient's minimum. Try a larger zap."
        }
        if lower.contains("amount too large") || lower.contains("above maximum") {
            return "Amount is above the recipient's maximum. Try a smaller zap."
        }
        // Strip the SDK noise wrapper if present:
        //   `Payment failed: BreezSdkSpark.SdkError.SparkError("…")` →  `…`
        if let inner = extractQuotedReason(in: raw) {
            return inner.prefix(1).uppercased() + inner.dropFirst() + (inner.hasSuffix(".") ? "" : ".")
        }
        return raw
    }

    /// Pull the substring between the first `("` and the matching `")` —
    /// the conventional shape of a wrapped Swift enum description like
    /// `Foo.Bar("the actual message")`. Returns nil when no such wrapper
    /// is present.
    private static func extractQuotedReason(in raw: String) -> String? {
        guard let open = raw.range(of: "(\""),
              let close = raw.range(of: "\")", range: open.upperBound..<raw.endIndex) else { return nil }
        return String(raw[open.upperBound..<close.lowerBound])
    }
}
