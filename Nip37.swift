import Foundation

/// NIP-37: encrypted, addressable drafts.
/// Spec: https://github.com/nostr-protocol/nips/blob/master/37.md
///
/// A draft is a kind-31234 wrapper event whose `content` is a NIP-44
/// self-encryption (recipient = author) of a stringified inner event:
/// `{ kind, pubkey, created_at, tags, content }`. The wrapper carries
/// `["d", <uuid>]` (addressable identifier) and `["k", <innerKind>]`.
/// An empty-content wrapper with the same `d` tag means "deleted".
nonisolated enum Nip37 {

    static let kindDraft: Int = 31234

    struct Draft: Identifiable {
        let dTag: String          // UUID (addressable identifier)
        let innerKind: Int        // typically 1
        let content: String       // plaintext (mentions already materialized)
        let tags: [[String]]      // inner tags (e/p/imeta/etc.)
        let createdAt: Int        // inner created_at (epoch seconds)
        let wrapperEventId: String

        var id: String { dTag }
    }

    static func newDraftId() -> String {
        UUID().uuidString
    }

    static func wrapperTags(dTag: String, innerKind: Int) -> [[String]] {
        [["d", dTag], ["k", String(innerKind)]]
    }

    /// Serialize the inner draft payload to JSON. The output is what gets
    /// NIP-44 self-encrypted into the wrapper's `content`. Key order is not
    /// significant — relays only see the encrypted blob.
    static func serializeInner(pubkeyHex: String, innerKind: Int, content: String, tags: [[String]],
                               createdAt: Int = Int(Date().timeIntervalSince1970)) -> String {
        var out = "{\"kind\":"
        out.append(String(innerKind))
        out.append(",\"pubkey\":\"")
        out.append(escape(pubkeyHex))
        out.append("\",\"created_at\":")
        out.append(String(createdAt))
        out.append(",\"tags\":")
        out.append(encodeTags(tags))
        out.append(",\"content\":\"")
        out.append(escape(content))
        out.append("\"}")
        return out
    }

    private static func encodeTags(_ tags: [[String]]) -> String {
        var out = "["
        for (i, tag) in tags.enumerated() {
            if i > 0 { out.append(",") }
            out.append("[")
            for (j, item) in tag.enumerated() {
                if j > 0 { out.append(",") }
                out.append("\"")
                out.append(escape(item))
                out.append("\"")
            }
            out.append("]")
        }
        out.append("]")
        return out
    }

    /// Decode the inner JSON for a wrapper event. Returns nil if the JSON is
    /// malformed or the wrapper is missing its `d` tag.
    static func parseDraft(wrapper: NostrEvent, decryptedJSON: String) -> Draft? {
        guard let data = decryptedJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let dTag = wrapper.tags.first { $0.count >= 2 && $0[0] == "d" }?[1]
        guard let dTag else { return nil }
        let innerKind = (obj["kind"] as? Int) ?? 1
        let content = (obj["content"] as? String) ?? ""
        let createdAt = (obj["created_at"] as? Int) ?? wrapper.createdAt
        let rawTags = obj["tags"] as? [[Any]] ?? []
        let tags = rawTags.map { $0.map { "\($0)" } }
        return Draft(
            dTag: dTag,
            innerKind: innerKind,
            content: content,
            tags: tags,
            createdAt: createdAt,
            wrapperEventId: wrapper.id
        )
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if scalar.value < 0x20 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
