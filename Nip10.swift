import Foundation

/// NIP-10 helpers: parsing reply / root markers and constructing reply tags.
nonisolated enum Nip10 {

    /// Returns the root event id of `event`, or nil if the event has no `e` tags.
    /// Prefers a marked `root` e-tag; falls back to the first e-tag (legacy positional).
    static func rootId(of event: NostrEvent) -> String? {
        let eTags = eTagsExcludingMentions(event)
        if let marked = eTags.first(where: { $0.count >= 4 && $0[3] == "root" }) {
            return marked[1]
        }
        return eTags.first?[1]
    }

    /// Returns the id of the event being directly replied to.
    /// Prefers marked `reply`, then marked `root`, then the last e-tag (legacy positional).
    static func replyTarget(of event: NostrEvent) -> String? {
        let eTags = eTagsExcludingMentions(event)
        if let reply = eTags.first(where: { $0.count >= 4 && $0[3] == "reply" }) {
            return reply[1]
        }
        if let root = eTags.first(where: { $0.count >= 4 && $0[3] == "root" }) {
            return root[1]
        }
        return eTags.last?[1]
    }

    /// Build the e/p tag set for a kind:1 reply to `replyTo`.
    /// - If `replyTo` already participates in a thread (has a root marker), the new event keeps that
    ///   root and marks `replyTo` as `reply`.
    /// - Otherwise `replyTo` itself becomes the root.
    /// Always re-emits every distinct `p` tag from the parent so the whole chain stays notified, plus
    /// `replyTo.pubkey`.
    static func buildReplyTags(replyTo: NostrEvent, relayHint: String = "") -> [[String]] {
        var tags: [[String]] = []

        let parentETags = eTagsExcludingMentions(replyTo)
        let existingRoot = parentETags.first(where: { $0.count >= 4 && $0[3] == "root" })
            ?? parentETags.first

        if let root = existingRoot, root[1] != replyTo.id {
            let rootHint = root.count >= 3 ? root[2] : ""
            tags.append(["e", root[1], rootHint, "root"])
            tags.append(["e", replyTo.id, relayHint, "reply"])
        } else {
            tags.append(["e", replyTo.id, relayHint, "root"])
        }

        tags.append(contentsOf: participantTags(replyingTo: replyTo))

        return tags
    }

    /// The `p` tags a reply to `parent` must carry so the whole thread stays
    /// notified: every distinct `p` tag already on `parent`, in order, followed
    /// by `parent.pubkey` if it isn't already among them.
    ///
    /// This is the carry-forward that keeps a deep chain intact — e.g. with A↔B
    /// and then B replying to B's own note, A's pubkey rides along from the
    /// parent's `p` tags instead of being dropped. Used by both the public
    /// composer path and `buildReplyTags`.
    static func participantTags(replyingTo parent: NostrEvent) -> [[String]] {
        var tags: [[String]] = []
        var seenP = Set<String>()
        for tag in parent.tags where tag.count >= 2 && tag[0] == "p" {
            if seenP.insert(tag[1]).inserted {
                tags.append(["p", tag[1]])
            }
        }
        if seenP.insert(parent.pubkey).inserted {
            tags.append(["p", parent.pubkey])
        }
        return tags
    }

    private static func eTagsExcludingMentions(_ event: NostrEvent) -> [[String]] {
        event.tags.filter { tag in
            guard tag.count >= 2, tag[0] == "e" else { return false }
            if tag.count >= 4, tag[3] == "mention" { return false }
            return true
        }
    }
}
