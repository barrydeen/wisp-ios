import Foundation
import Observation

/// Event ids the user has chosen to reveal from behind a muted-author
/// placeholder.
///
/// Deliberately in-memory and never persisted: revealing is "let me read this
/// one post", not a durable exception to the mute. Reveals are scoped to the
/// visit — `ThreadView` drops its own on the way out, so reopening a thread
/// starts from hidden again — and account switch or sign-out clears the lot.
///
/// This lives in a store rather than in the row's own `@State` because thread
/// and feed rows sit in a `LazyVStack`: scrolling a revealed row out of view
/// and back tears down its state, which would silently re-hide the post the
/// user just opened.
@Observable
@MainActor
final class MutedRevealStore {
    static let shared = MutedRevealStore()

    private(set) var revealedEventIds: Set<String> = []

    private init() {}

    func isRevealed(_ eventId: String) -> Bool {
        revealedEventIds.contains(eventId)
    }

    func reveal(_ eventId: String) {
        revealedEventIds.insert(eventId)
    }

    /// Drop a whole screen's worth of reveals at once. A thread calls this as
    /// it goes away, so reopening it starts from hidden again — revealing is
    /// scoped to the visit, not to the app's lifetime.
    func hide(_ eventIds: Set<String>) {
        guard !revealedEventIds.isEmpty else { return }
        revealedEventIds.subtract(eventIds)
    }

    /// Called on account switch and sign-out — one account's reveals must not
    /// carry into another's session.
    func clear() {
        guard !revealedEventIds.isEmpty else { return }
        revealedEventIds.removeAll()
    }
}
