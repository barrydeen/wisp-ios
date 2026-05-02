import Foundation

/// NIP-51 kind 30015 "interest set" — a parameterized-replaceable list of hashtags
/// the user has grouped together. Companion to `Nip51Lists` (relay sets) and
/// `Nip51Groups` (group membership lists).
///
/// Tag layout:
///   ["d", dTag]
///   ["title", name]
///   ["t", hashtag]   // one per hashtag, lowercased, leading `#` stripped
nonisolated enum Nip51Hashtags {
    static let kindHashtagSet = 30015

    /// Normalize a hashtag for storage / equality:
    ///   - trim whitespace
    ///   - drop a single leading `#`
    ///   - lowercase
    ///   - reject empty results
    /// Allowed characters: letters, digits, `_`, `-`. Anything else fails the parse.
    static func normalize(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
        for ch in lowered where !allowed.contains(ch) { return nil }
        return lowered
    }

    static func parseHashtagSet(_ event: NostrEvent) -> HashtagSet? {
        guard event.kind == kindHashtagSet else { return nil }
        var dTag: String?
        var title: String?
        var name: String?
        var seen = Set<String>()
        var hashtags: [String] = []
        for tag in event.tags {
            guard tag.count >= 2 else { continue }
            switch tag[0] {
            case "d": dTag = tag[1]
            case "title": title = tag[1]
            case "name": name = tag[1]
            case "t":
                if let n = normalize(tag[1]), seen.insert(n).inserted {
                    hashtags.append(n)
                }
            default: break
            }
        }
        guard let dTag, !dTag.isEmpty else { return nil }
        return HashtagSet(
            pubkey: event.pubkey,
            dTag: dTag,
            name: title ?? name ?? dTag,
            hashtags: hashtags,
            createdAt: event.createdAt
        )
    }

    static func buildHashtagSetTags(dTag: String, name: String, hashtags: [String]) -> [[String]] {
        var tags: [[String]] = [["d", dTag], ["title", name]]
        for h in hashtags {
            if let n = normalize(h) { tags.append(["t", n]) }
        }
        return tags
    }
}
