import Foundation
import Observation

/// Single-slot, observable source of truth for the optimistic feed row shown
/// while `PostPublisher` is mining / broadcasting the user's note. The home
/// feed reads `pending` and renders it as a dimmed `PostCardView` above the
/// normal list so the user sees their content immediately on tap-to-post
/// instead of staring at an unchanged feed for the duration of PoW.
///
/// Mirrors `PostPublisher`'s single-in-flight model — there's at most one
/// pending post at a time. When the real signed event arrives via
/// `.nostrEventPublished`, `FeedViewModel.observeOwnPublishes` inserts it
/// into the real feed and this store clears its slot in the same render
/// pass, so the dimmed row dissolves and the real card takes its place
/// without a visible flicker.
///
/// Failures (`PostPublisher.fail`) flip the slot's state to `.failed`; the
/// row stays visible with an error indicator until the user dismisses it.
@MainActor
@Observable
final class PendingPostStore {
    static let shared = PendingPostStore()

    enum State: Equatable {
        case mining
        case publishing
        case failed(message: String)
    }

    /// Optimistic placeholder. Built as a real `NostrEvent` so the feed can
    /// pipe it through the existing `PostCardView` without a parallel UI
    /// path. The `id` is a `"pending-<uuid>"` prefix that never collides
    /// with a real 64-hex event id, and the `sig` is empty — nothing in the
    /// rendering path validates either field.
    struct PendingPost: Identifiable {
        let id: String
        let event: NostrEvent
        var state: State
    }

    private(set) var pending: PendingPost?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .nostrEventPublished,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?["event"] as? NostrEvent else { return }
            Task { @MainActor [weak self] in
                self?.clearIfMatches(realEvent: event)
            }
        }
    }

    /// Capture the optimistic copy at `PostPublisher.submit` time. Caller
    /// passes the exact content / tags / kind that will reach the publisher
    /// so the dimmed row renders the same body the user will see post-mine.
    func start(content: String, tags: [[String]], pubkey: String, kind: Int) {
        let id = "pending-\(UUID().uuidString)"
        let event = NostrEvent(
            id: id,
            pubkey: pubkey,
            kind: kind,
            createdAt: Int(Date().timeIntervalSince1970),
            tags: tags,
            content: content,
            sig: ""
        )
        pending = PendingPost(id: id, event: event, state: .mining)
    }

    /// Move from `.mining` to `.publishing`. PostPublisher calls this when it
    /// hands the signed event to `RelayPool.publish`. Visible only as a copy
    /// change on the status pill ("Mining…" → "Publishing…").
    func setPublishing() {
        guard pending != nil else { return }
        pending?.state = .publishing
    }

    /// Surface a publish failure on the optimistic row. The row stays visible
    /// so the user knows the post didn't go out and can re-open the composer
    /// (the autosaved draft is still on disk via `autosaveKeyToClear` —
    /// `PostPublisher` only clears it after a successful broadcast).
    func markFailed(_ message: String) {
        pending?.state = .failed(message: message)
    }

    /// User dismisses a failed row, or the store wipes the slot after the
    /// real published event arrives.
    func clear() {
        pending = nil
    }

    /// True when the pending event has at least one `e` tag — i.e. it's a
    /// reply or quote, not a root note. The home feed checks this so it
    /// doesn't render a "pending reply" row that belongs to a thread.
    var pendingIsReply: Bool {
        guard let pending else { return false }
        return pending.event.tags.contains(where: { $0.first == "e" })
    }

    /// Match heuristic: PostPublisher is single-slot and `start` is only
    /// called for kind-1-style feed posts, so any published event from the
    /// same pubkey with the same kind while a slot exists is the matching
    /// real event. Reactions (kind 7) / DMs / private interactions go
    /// through different publishers but also fire `.nostrEventPublished`,
    /// so we still gate on kind to avoid clearing the slot prematurely.
    private func clearIfMatches(realEvent: NostrEvent) {
        guard let pending else { return }
        guard realEvent.pubkey == pending.event.pubkey else { return }
        guard realEvent.kind == pending.event.kind else { return }
        clear()
    }
}
