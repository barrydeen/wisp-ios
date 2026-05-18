import Foundation

struct ThreadRoute: Hashable {
    let eventId: String
    /// Hint so the thread can start fetching the author's inbox relays before the event arrives.
    let authorPubkey: String?
    /// When set, the thread scrolls to this event id after loading (e.g. to highlight a
    /// newly-posted reply within its parent thread).
    let scrollToId: String?

    init(eventId: String, authorPubkey: String?, scrollToId: String? = nil) {
        self.eventId = eventId
        self.authorPubkey = authorPubkey
        self.scrollToId = scrollToId
    }
}
