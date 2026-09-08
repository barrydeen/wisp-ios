import Foundation

/// NIP-09: event deletion via kind-5.
/// Spec: https://github.com/nostr-protocol/nips/blob/master/09.md
nonisolated enum Nip09 {

    static let kindDeletion: Int = 5

    /// Delete a regular (non-addressable) event by its id.
    static func deletionTagsForEvent(id: String, kind: Int) -> [[String]] {
        [["e", id], ["k", String(kind)]]
    }

    /// Delete an addressable event by its `kind:pubkey:dTag` coordinate.
    static func deletionTagsForAddressable(kind: Int, pubkey: String, dTag: String) -> [[String]] {
        [["a", "\(kind):\(pubkey):\(dTag)"], ["k", String(kind)]]
    }

    // MARK: - Reading deletion requests

    /// Filter for the deletion requests targeting `eventId`.
    ///
    /// `authors` should carry the target event's author when it's known: a
    /// deletion request is only meaningful from the author of the event it
    /// names, so constraining the query keeps a stranger's stray kind-5 out of
    /// the response entirely.
    static func deletionFilter(eventId: String, authors: [String]?) -> NostrFilter {
        var f = NostrFilter()
        f.kinds = [kindDeletion]
        f.eTags = [eventId]
        if let authors, !authors.isEmpty { f.authors = authors }
        f.limit = 8
        return f
    }

    /// The event ids a kind-5 asks to retract. Empty for any other kind, so
    /// callers can feed it arbitrary events without pre-filtering.
    static func deletedEventIds(_ event: NostrEvent) -> [String] {
        guard event.kind == kindDeletion else { return [] }
        return event.tags.compactMap { tag in
            tag.count >= 2 && tag[0] == "e" ? tag[1] : nil
        }
    }
}
