import Foundation
import Observation
import SwiftUI

/// Owns the post-commit lifetime (PoW mining → sign → broadcast → persist → notify)
/// independent of the compose sheet. Once `ComposeViewModel` hands off a
/// `PreparedDraft` via `submit`, the sheet dismisses immediately; the user sees
/// progress through `PostStatusPill` which observes `phase`.
///
/// Single in-flight slot — a second `submit` cancels the first (matches Android
/// `PowManager`). A rapid second post is rare in practice; the trade-off is that
/// one post's mining can be discarded, preferable to ambiguous concurrent progress
/// in a single pill.
@MainActor
@Observable
final class PostPublisher {
    static let shared = PostPublisher()
    private init() {}

    enum Phase: Equatable {
        case idle
        case mining(attempts: Int)
        case broadcasting(accepted: Int, sent: Int)
        case done(relayCount: Int)
        case failed(message: String)
    }

    private(set) var phase: Phase = .idle

    @ObservationIgnored private var inflight: Task<Void, Never>?
    @ObservationIgnored private var mineTask: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// Cancels any in-flight publish and starts a new one. Returns immediately;
    /// the sheet can dismiss as soon as this method is called.
    func submit(_ draft: PreparedDraft) {
        cancelInflight()
        // Seed the pill before the run() task gets scheduled. Without this, the
        // pill flickers in a frame late on a busy main actor.
        phase = draft.powEnabled
            ? .mining(attempts: 0)
            : .broadcasting(accepted: 0, sent: draft.relays.count)
        inflight = Task { [weak self] in
            await self?.run(draft)
        }
    }

    /// Cancel during mining only. Once `.broadcasting`, the event is in flight to
    /// relays and cancellation is meaningless. No-op outside `.mining`.
    func cancel() {
        guard case .mining = phase else { return }
        cancelInflight()
        phase = .idle
    }

    private func cancelInflight() {
        mineTask?.cancel()
        mineTask = nil
        inflight?.cancel()
        inflight = nil
        dismissTask?.cancel()
        dismissTask = nil
    }

    private func run(_ draft: PreparedDraft) async {
        var tags = draft.tags
        var createdAt = draft.createdAt

        if draft.powEnabled {
            let mined: Nip13.MineResult? = await withCheckedContinuation { cont in
                let pubkey = draft.signingKeypair.pubkey
                let kind = draft.kind
                let content = draft.content
                let powDifficulty = draft.powDifficulty
                let capturedTags = tags
                let capturedCreatedAt = createdAt
                let task = Task.detached(priority: .userInitiated) { [weak self] in
                    let result = Nip13.mine(
                        pubkey: pubkey,
                        kind: kind,
                        createdAt: capturedCreatedAt,
                        tags: capturedTags,
                        content: content,
                        targetBits: powDifficulty,
                        onProgress: { attempts in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                // Don't overwrite a later phase (e.g. user cancelled).
                                if case .mining = self.phase {
                                    self.phase = .mining(attempts: attempts)
                                }
                            }
                        }
                    )
                    cont.resume(returning: result)
                    _ = self
                }
                self.mineTask = task
            }
            mineTask = nil
            guard let mined else {
                // mine() returns nil only on Task.isCancelled; cancel() already
                // reset phase to .idle. Bail without overwriting it.
                return
            }
            tags = mined.tags
            createdAt = mined.createdAt
        }

        if Task.isCancelled { return }

        let event: NostrEvent
        do {
            event = try await Signer.sign(
                keypair: draft.signingKeypair,
                kind: draft.kind,
                tags: tags,
                content: draft.content,
                createdAt: createdAt
            )
        } catch {
            fail("Signing failed: \(error)")
            return
        }

        phase = .broadcasting(accepted: 0, sent: draft.relays.count)
        let succeeded = await RelayPool.publish(
            event: event,
            to: draft.relays,
            timeout: 8,
            onAccept: { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if case .broadcasting(let a, let s) = self.phase {
                        self.phase = .broadcasting(accepted: a + 1, sent: s)
                    }
                }
            }
        )

        if succeeded.isEmpty {
            fail("No relays accepted the post.")
            return
        }

        // Persist → NotificationCenter post mirrors the order the old in-VM
        // pipeline used: observers (open threads, feed, notifications) see the
        // event in EventStore before the broadcast asks them to ingest it.
        await EventStore.shared.persist([event])
        if let key = draft.autosaveKeyToClear {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if let dTag = draft.draftIdToClear {
            await Self.clearNip37Draft(
                dTag: dTag,
                keypair: draft.signingKeypair,
                relays: draft.relays
            )
        }
        NotificationCenter.default.post(
            name: .nostrEventPublished,
            object: nil,
            userInfo: ["event": event]
        )

        phase = .done(relayCount: succeeded.count)
        scheduleDismiss(after: 2.0)
        inflight = nil
    }

    private func fail(_ message: String) {
        phase = .failed(message: message)
        scheduleDismiss(after: 4.0)
        inflight = nil
    }

    func dismiss() {
        dismissTask?.cancel()
        phase = .idle
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.phase = .idle
        }
    }

    /// Publish a NIP-37 deletion replacement for the active draft. Best-effort —
    /// failure here doesn't surface as a post error since the actual note has
    /// already published successfully.
    private static func clearNip37Draft(dTag: String, keypair: Keypair, relays: [String]) async {
        let now = Int(Date().timeIntervalSince1970)
        let innerJSON = Nip37.serializeInner(
            pubkeyHex: keypair.pubkey,
            innerKind: 1,
            content: "",
            tags: [],
            createdAt: now
        )
        guard let cipher = try? await Signer.nip44Encrypt(
            keypair: keypair, peerPubkey: keypair.pubkey, plaintext: innerJSON
        ) else { return }
        guard let wrapper = try? await Signer.sign(
            keypair: keypair,
            kind: Nip37.kindDraft,
            tags: Nip37.wrapperTags(dTag: dTag, innerKind: 1),
            content: cipher,
            createdAt: now
        ) else { return }
        _ = await RelayPool.publish(event: wrapper, to: relays, timeout: 6)
    }
}

/// Value-type snapshot of everything `PostPublisher` needs. Mention
/// materialization, attachment URL splicing, and tag construction have already
/// happened in the VM — the publisher is purely PoW → sign → broadcast → persist.
struct PreparedDraft {
    let kind: Int
    let tags: [[String]]
    let createdAt: Int
    let content: String
    let signingKeypair: Keypair
    let powEnabled: Bool
    let powDifficulty: Int
    let relays: [String]
    /// UserDefaults key for the composer's local autosave bucket, cleared on
    /// successful publish only. nil when there was no autosave to begin with.
    let autosaveKeyToClear: String?
    /// dTag of the NIP-37 published draft to delete after successful publish.
    let draftIdToClear: String?
}
