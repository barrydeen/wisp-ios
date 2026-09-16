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
/// one post's mining can be discarded (its draft goes back to the composer),
/// preferable to ambiguous concurrent progress in a single pill.
///
/// A publish that doesn't land — every relay rejected it, signing failed, or the
/// user stopped mining — is never silently dropped. The draft is retained here
/// for `retry()` and written back to the composer's autosave bucket, so the text
/// survives dismissing the pill and reopening the composer.
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
        /// The post never landed — every relay rejected it, or signing failed.
        case failed(message: String)
        /// The user stopped mining before a nonce was found.
        case stopped
    }

    private(set) var phase: Phase = .idle

    /// The draft behind the current phase. Retained through `.failed` /
    /// `.stopped` so `retry()` can re-run it; cleared on success and on dismiss.
    @ObservationIgnored private var pending: PreparedDraft?

    @ObservationIgnored private var inflight: Task<Void, Never>?
    @ObservationIgnored private var mineTask: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// True in the two states the user can act on. `.failed` and `.stopped` are
    /// only ever entered with `pending` set, so this tracks `phase` alone and
    /// stays correct under `@Observable` (which doesn't see `pending`).
    var canRetry: Bool {
        switch phase {
        case .failed, .stopped: return true
        case .idle, .mining, .broadcasting, .done: return false
        }
    }

    /// Cancels any in-flight publish and starts a new one. Returns immediately;
    /// the sheet can dismiss as soon as this method is called.
    func submit(_ draft: PreparedDraft) {
        // Single slot: a second post drops the one still mining. Nothing has been
        // sent at that point, so hand its text back to the composer before
        // letting go of it. (A superseded *broadcast* is left alone — the event
        // is already at the relays and may well land.)
        if case .mining = phase, let superseded = pending {
            restoreForEditing(superseded)
        }
        cancelInflight()
        pending = draft
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
    ///
    /// Stopping is not discarding: the draft goes back into the composer's
    /// autosave bucket and stays retryable from the pill, so a user who bails on
    /// a long mining run (or wants to turn PoW off first) keeps their text.
    func cancel() {
        guard case .mining = phase, let draft = pending else { return }
        cancelInflight()
        restoreForEditing(draft)
        phase = .stopped
        // Drop the optimistic feed row too — the user explicitly killed the
        // post; no reason to leave a dimmed placeholder hanging around. The
        // text isn't lost with it: it's back in the composer's autosave.
        PendingPostStore.shared.clear()
    }

    /// Re-run the retained draft from the top (mine → sign → broadcast). No-op
    /// unless the last attempt failed or was stopped.
    func retry() {
        guard canRetry, var draft = pending else { return }
        // Re-stamp the attempt. PoW commits `created_at` into the event id, so a
        // retry minutes after a stopped mining run (or after the user sat on the
        // error) would otherwise publish a note timestamped at the failed try.
        draft.createdAt = NostrClock.now()
        submit(draft)
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
                // mine() returns nil only on Task.isCancelled — either the user
                // stopped it (cancel() already moved the phase to .stopped) or a
                // newer submit superseded this one. Bail without overwriting.
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
            fail("Signing failed. Draft saved.", draft: draft)
            return
        }

        phase = .broadcasting(accepted: 0, sent: draft.relays.count)
        PendingPostStore.shared.setPublishing()
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
            fail("No relay accepted the post. Draft saved.", draft: draft)
            return
        }

        // Persist → NotificationCenter post mirrors the order the old in-VM
        // pipeline used: observers (open threads, feed, notifications) see the
        // event in EventStore before the broadcast asks them to ingest it.
        await EventStore.shared.persist([event])
        Self.clearAutosaveIfStillThisDraft(draft)
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

        // A newer `submit` may have cancelled this run mid-broadcast. The event
        // still went out, so it is persisted and announced above — but the pill
        // and the retained draft belong to the newer post now.
        if Task.isCancelled { return }
        pending = nil
        phase = .done(relayCount: succeeded.count)
        scheduleDismiss(after: 2.0)
        inflight = nil
    }

    /// Park the publish in a retryable error state. Unlike `.done`, this never
    /// auto-dismisses — the pill is the only notice the user gets that the post
    /// didn't go out, and it carries the Retry button, so it waits to be
    /// acknowledged. The draft is back in the composer either way.
    private func fail(_ message: String, draft: PreparedDraft) {
        // A run superseded by a newer `submit` unwinds through here (a cancelled
        // broadcast reports zero acceptances). Its phase and its draft belong to
        // the newer post now, so drop the stale failure rather than stomping it.
        if Task.isCancelled { return }
        restoreForEditing(draft)
        phase = .failed(message: message)
        // Mirror the failure onto the optimistic feed row so the user sees
        // the error in-context (right where their post was supposed to land)
        // in addition to the pill. No auto-dismiss on either: a failure the
        // user never saw reads exactly like a post that went out.
        PendingPostStore.shared.markFailed(message)
        inflight = nil
    }

    func dismiss() {
        dismissTask?.cancel()
        pending = nil
        phase = .idle
    }

    /// Put a rejected / stopped post's text back where the composer looks for
    /// it, so dismissing the pill doesn't take the draft with it.
    ///
    /// Skipped when a bucket already exists under that key: the user has started
    /// a newer draft in the same composer slot since hand-off, and overwriting it
    /// would trade one lost draft for another. The pill's Retry still works in
    /// that case — the publisher holds its own copy.
    @discardableResult
    static func restoreDraftForEditing(_ draft: PreparedDraft, defaults: UserDefaults = .standard) -> Bool {
        guard let key = draft.autosaveKey, let snapshot = draft.autosaveSnapshot else { return false }
        guard defaults.dictionary(forKey: key) == nil else { return false }
        defaults.set(snapshot.payload, forKey: key)
        return true
    }

    /// Drop the composer bucket once the post is out — but only while it still
    /// holds *this* draft. The composer normally empties it at hand-off, so this
    /// only bites on the retry path: a failed post can sit on the pill long
    /// enough for the user to start a new draft in the same composer slot, and a
    /// late success must not take that one with it.
    @discardableResult
    static func clearAutosaveIfStillThisDraft(_ draft: PreparedDraft, defaults: UserDefaults = .standard) -> Bool {
        guard let key = draft.autosaveKey,
              let stored = defaults.dictionary(forKey: key),
              let snapshot = draft.autosaveSnapshot,
              stored["content"] as? String == snapshot.content else { return false }
        defaults.removeObject(forKey: key)
        return true
    }

    private func restoreForEditing(_ draft: PreparedDraft) {
        Self.restoreDraftForEditing(draft)
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
        let now = NostrClock.now()
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
    /// `var` so `retry()` can re-stamp the attempt — PoW mines against this
    /// value, so it has to be settable without rebuilding the whole draft.
    var createdAt: Int
    let content: String
    let signingKeypair: Keypair
    let powEnabled: Bool
    let powDifficulty: Int
    let relays: [String]
    /// UserDefaults key for the composer's local autosave bucket. The composer
    /// empties it at hand-off and the publisher owns it from there: cleared for
    /// good on success, refilled from `autosaveSnapshot` when the post is
    /// rejected or stopped. nil when there was no autosave to begin with.
    let autosaveKey: String?
    /// The composer state that produced this post, in the same shape
    /// `ComposeViewModel.loadLocalAutosave` reads. nil for composers that don't
    /// autosave (private replies, drafts already published via NIP-37).
    let autosaveSnapshot: ComposeAutosaveSnapshot?
    /// dTag of the NIP-37 published draft to delete after successful publish.
    let draftIdToClear: String?
}

/// Boxes the composer's `UserDefaults` autosave payload so `PreparedDraft` keeps
/// its inferred `Sendable` conformance — a bare `[String: Any]` stored property
/// would forfeit it, and the draft is captured by the publisher's `Task`. The
/// payload only ever holds property-list primitives (String / Bool / Double and
/// arrays of those) and is never mutated after construction, so the unchecked
/// conformance is safe.
struct ComposeAutosaveSnapshot: @unchecked Sendable {
    let payload: [String: Any]

    /// Body text as stored, used to tell this draft apart from a newer one the
    /// user may have started in the same composer slot.
    var content: String? { payload["content"] as? String }
}
