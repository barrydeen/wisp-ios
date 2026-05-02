import Foundation

/// NIP-51 list events used for relay-feed surfaces:
///   - kind 10012: favorite relays (replaceable)
///   - kind 30002: named relay set    (parameterized replaceable, keyed by `d` tag)
///
/// Kept distinct from `Nip51Groups` (which covers kind 30001 simple group lists).
nonisolated enum Nip51Lists {
    static let kindFavoriteRelays = 10012
    static let kindRelaySet = 30002
    static let kindRelayList = 10002        // NIP-65 read/write relays
    static let kindDmRelays = 10050         // NIP-17 inbox relays
    static let kindSearchRelays = 10007     // NIP-51 search relay set
    static let kindBlockedRelays = 10006    // NIP-51 blocked relay set

    /// Normalize a relay URL for storage / equality. Lowercases the scheme + host,
    /// trims a single trailing slash, rejects anything that isn't `ws://` or `wss://`.
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              let host = url.host?.lowercased(),
              !host.isEmpty else { return nil }

        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }

        var out = "\(scheme)://\(host)"
        if let port = url.port { out += ":\(port)" }
        out += path
        if let q = url.query, !q.isEmpty { out += "?\(q)" }
        return out
    }

    static func isValidUrl(_ raw: String) -> Bool {
        normalize(raw) != nil
    }

    // MARK: - Favorite relays (kind 10012)

    static func parseFavoriteRelays(_ event: NostrEvent) -> [String] {
        guard event.kind == kindFavoriteRelays else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for tag in event.tags {
            guard tag.count >= 2, tag[0] == "relay" || tag[0] == "r" else { continue }
            guard let url = normalize(tag[1]) else { continue }
            if seen.insert(url).inserted { out.append(url) }
        }
        return out
    }

    static func buildFavoriteRelayTags(_ urls: [String]) -> [[String]] {
        urls.compactMap { normalize($0).map { ["relay", $0] } }
    }

    // MARK: - Named relay set (kind 30002)

    static func parseRelaySet(_ event: NostrEvent) -> RelaySet? {
        guard event.kind == kindRelaySet else { return nil }
        var dTag: String?
        var title: String?
        var name: String?
        var seen = Set<String>()
        var relays: [String] = []
        for tag in event.tags {
            guard tag.count >= 2 else { continue }
            switch tag[0] {
            case "d": dTag = tag[1]
            case "title": title = tag[1]
            case "name": name = tag[1]
            case "relay", "r":
                if let url = normalize(tag[1]), seen.insert(url).inserted {
                    relays.append(url)
                }
            default: break
            }
        }
        guard let dTag, !dTag.isEmpty else { return nil }
        return RelaySet(
            pubkey: event.pubkey,
            dTag: dTag,
            name: title ?? name ?? dTag,
            relays: relays,
            createdAt: event.createdAt
        )
    }

    static func buildRelaySetTags(dTag: String, name: String, relays: [String]) -> [[String]] {
        var tags: [[String]] = [["d", dTag], ["title", name]]
        for url in relays {
            if let n = normalize(url) { tags.append(["relay", n]) }
        }
        return tags
    }

    // MARK: - General relay list (NIP-65, kind 10002)

    /// Parse a kind:10002 event into `[GeneralRelay]`. A 2-element `["r", url]` tag
    /// means both read+write; a 3-element tag with `"read"` or `"write"` marks the side.
    static func parseGeneralRelayList(_ event: NostrEvent) -> [GeneralRelay] {
        guard event.kind == kindRelayList else { return [] }
        var seen = Set<String>()
        var out: [GeneralRelay] = []
        for tag in event.tags {
            guard tag.count >= 2, tag[0] == "r" else { continue }
            guard let url = normalize(tag[1]), seen.insert(url).inserted else { continue }
            if tag.count == 2 {
                out.append(GeneralRelay(url: url, read: true, write: true))
            } else {
                switch tag[2].lowercased() {
                case "read":  out.append(GeneralRelay(url: url, read: true,  write: false))
                case "write": out.append(GeneralRelay(url: url, read: false, write: true))
                default:      out.append(GeneralRelay(url: url, read: true,  write: true))
                }
            }
        }
        return out
    }

    /// Build NIP-65 `["r", url]` / `["r", url, "read"|"write"]` tags. Relays with
    /// neither read nor write are omitted (they would be a no-op).
    static func buildGeneralRelayTags(_ relays: [GeneralRelay]) -> [[String]] {
        var tags: [[String]] = []
        for r in relays {
            guard let n = normalize(r.url) else { continue }
            if r.read && r.write {
                tags.append(["r", n])
            } else if r.read {
                tags.append(["r", n, "read"])
            } else if r.write {
                tags.append(["r", n, "write"])
            }
        }
        return tags
    }

    // MARK: - Simple relay-set lists (kinds 10050 / 10007 / 10006)

    /// Parse a kind:10050 / 10007 / 10006 event's `["relay", url]` (or `"r"`) tags.
    static func parseRelaySetList(_ event: NostrEvent) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in event.tags {
            guard tag.count >= 2, tag[0] == "relay" || tag[0] == "r" else { continue }
            guard let url = normalize(tag[1]) else { continue }
            if seen.insert(url).inserted { out.append(url) }
        }
        return out
    }

    /// Build `["relay", url]` tags for kind 10050 / 10007 / 10006.
    static func buildRelaySetListTags(_ urls: [String]) -> [[String]] {
        urls.compactMap { normalize($0).map { ["relay", $0] } }
    }

    /// Slugify a free-form name into a stable d-tag identifier.
    static func dTag(forName name: String) -> String {
        let lowered = name.lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        var out = ""
        var lastWasDash = false
        for ch in lowered {
            if allowed.contains(ch) {
                out.append(ch)
                lastWasDash = (ch == "-")
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "set-\(Int(Date().timeIntervalSince1970))" : trimmed
    }
}
