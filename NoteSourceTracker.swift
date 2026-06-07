import Foundation
import Observation

/// In-memory map of `eventId → Set<relayUrl>`, populated by RelayPool whenever an EVENT
/// is received from any relay (via `query` or `subscribe`). PostCardView's expander
/// reads from this to render the "Seen on" row. Cleared on logout.
@Observable
@MainActor
final class NoteSourceTracker {
    static let shared = NoteSourceTracker()

    /// `@ObservationIgnored` is load-bearing for scroll performance. `record`
    /// is called for EVERY incoming relay event (from the connection pool's
    /// receive loop), and every visible `PostCardView` reads this map (for the
    /// "Seen on" relay row + share-link relay hints). If it were observed, each
    /// relay event would re-render every visible feed row — measured at
    /// hundreds/sec during scroll (`View._printChanges()` named this map as the
    /// dominant trigger). The values are only read on demand, not displayed
    /// live, so dropping observation is purely a win.
    @ObservationIgnored private(set) var sources: [String: Set<String>] = [:]

    private init() {}

    func record(eventId: String, relayUrl: String) {
        sources[eventId, default: []].insert(relayUrl)
    }

    func relays(for eventId: String) -> [String] {
        guard let set = sources[eventId] else { return [] }
        return Array(set).sorted()
    }

    func clear() {
        sources.removeAll()
    }
}
