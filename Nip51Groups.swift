import Foundation

/// NIP-51 kind-10009 ("simple groups") slice — the user's persisted list of
/// joined NIP-29 groups, used for cross-device sync.
nonisolated enum Nip51Groups {

    static let kindSimpleGroups = 10009

    struct SimpleGroupEntry: Hashable {
        let groupId: String
        let relayUrl: String
        let name: String?
    }

    static func parse(_ event: NostrEvent) -> [SimpleGroupEntry] {
        guard event.kind == kindSimpleGroups else { return [] }
        return event.tags.compactMap { tag in
            guard tag.count >= 3, tag[0] == "group" else { return nil }
            let groupId = tag[1].trimmingCharacters(in: .whitespacesAndNewlines)
            var relayUrl = tag[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while relayUrl.hasSuffix("/") { relayUrl.removeLast() }
            guard !groupId.isEmpty,
                  relayUrl.hasPrefix("wss://") || relayUrl.hasPrefix("ws://") else { return nil }
            let name = tag.count >= 4 ? tag[3].trimmingCharacters(in: .whitespacesAndNewlines) : nil
            return SimpleGroupEntry(groupId: groupId, relayUrl: relayUrl,
                                    name: (name?.isEmpty == false) ? name : nil)
        }
    }

    /// Tags for a kind-10009 event: one `["group", id, relay, name?]` per joined room
    /// plus one `["r", relay]` per unique relay (for NIP-65 hint discovery).
    static func buildTags(from entries: [SimpleGroupEntry]) -> [[String]] {
        var tags: [[String]] = []
        var relays = Set<String>()
        for entry in entries {
            if let name = entry.name, !name.isEmpty {
                tags.append(["group", entry.groupId, entry.relayUrl, name])
            } else {
                tags.append(["group", entry.groupId, entry.relayUrl])
            }
            relays.insert(entry.relayUrl)
        }
        for relay in relays.sorted() {
            tags.append(["r", relay])
        }
        return tags
    }
}
