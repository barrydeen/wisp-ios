import Foundation
import CryptoKit

struct NostrEvent {
    let id: String
    let pubkey: String
    let kind: Int
    let createdAt: Int
    let tags: [[String]]
    let content: String
    let sig: String

    nonisolated init(id: String, pubkey: String, kind: Int, createdAt: Int, tags: [[String]], content: String, sig: String) {
        self.id = id
        self.pubkey = pubkey
        self.kind = kind
        self.createdAt = createdAt
        self.tags = tags
        self.content = content
        self.sig = sig
    }

    var isRootNote: Bool {
        kind == 1 && !tags.contains { $0.first == "e" }
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let pubkey = json["pubkey"] as? String,
              let kind = json["kind"] as? Int,
              let createdAt = json["created_at"] as? Int,
              let content = json["content"] as? String,
              let sig = json["sig"] as? String else { return nil }
        let rawTags = json["tags"] as? [[Any]] ?? []
        self.id = id
        self.pubkey = pubkey
        self.kind = kind
        self.createdAt = createdAt
        self.tags = rawTags.map { $0.map { "\($0)" } }
        self.content = content
        self.sig = sig
    }

    static func fromJSON(_ s: String) -> NostrEvent? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return NostrEvent(json: obj)
    }

    /// Canonical NIP-01 serialization: `[0,pubkey,created_at,kind,tags,content]`,
    /// no whitespace, NIP-01 escape rules. Used for both event id (this hashed)
    /// and rumor id (same algorithm; rumor's id is unsigned but well-defined).
    static func serializeForId(pubkey: String, createdAt: Int, kind: Int, tags: [[String]], content: String) -> String {
        var out = "[0,\""
        out.append(pubkey)
        out.append("\",")
        out.append(String(createdAt))
        out.append(",")
        out.append(String(kind))
        out.append(",[")
        for (i, tag) in tags.enumerated() {
            if i > 0 { out.append(",") }
            out.append("[")
            for (j, item) in tag.enumerated() {
                if j > 0 { out.append(",") }
                out.append("\"")
                out.append(escapeJSON(item))
                out.append("\"")
            }
            out.append("]")
        }
        out.append("],\"")
        out.append(escapeJSON(content))
        out.append("\"]")
        return out
    }

    static func computeId(pubkey: String, createdAt: Int, kind: Int, tags: [[String]], content: String) -> String {
        let serialized = serializeForId(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
        let hash = SHA256.hash(data: Data(serialized.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Compute id, Schnorr-sign, return a fully-formed signed event.
    static func sign(privkey32: Data, pubkey: String, kind: Int, createdAt: Int, tags: [[String]], content: String) throws -> NostrEvent {
        let id = computeId(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
        guard let idBytes = Hex.decode(id) else { throw NSError(domain: "NostrEvent", code: 1) }
        let sigData = try Schnorr.sign(messageId32: idBytes, privkey32: privkey32)
        return NostrEvent(id: id, pubkey: pubkey, kind: kind, createdAt: createdAt,
                          tags: tags, content: content, sig: Hex.encode(sigData))
    }

    /// Returns `["client", "Wisp iOS"]` when the user has the Wisp client tag enabled in
    /// settings (default ON), or nil to signal "do not append". Callers append it to
    /// their tag list before signing kind-1 notes, kind-9734 zap requests, etc.
    /// Never used for sealed DMs (NIP-17) or infrastructure events (NIP-42 auth, NIP-47 NWC).
    /// Reads UserDefaults directly so it can be called from any isolation context
    /// (the AppSettings store is `@MainActor`-isolated).
    static func clientTagIfEnabled() -> [String]? {
        let key = "wisp_settings_client_tag_enabled"
        let enabled = (UserDefaults.standard.object(forKey: key) as? Bool) ?? true
        return enabled ? ["client", "Wisp iOS"] : nil
    }

    /// Serialize this event as a single JSON object (e.g. for use as a NIP-44 plaintext payload).
    func toJSON() -> String {
        var out = "{\"id\":\""
        out.append(id)
        out.append("\",\"pubkey\":\"")
        out.append(pubkey)
        out.append("\",\"created_at\":")
        out.append(String(createdAt))
        out.append(",\"kind\":")
        out.append(String(kind))
        out.append(",\"tags\":[")
        for (i, tag) in tags.enumerated() {
            if i > 0 { out.append(",") }
            out.append("[")
            for (j, item) in tag.enumerated() {
                if j > 0 { out.append(",") }
                out.append("\"")
                out.append(NostrEvent.escapeJSON(item))
                out.append("\"")
            }
            out.append("]")
        }
        out.append("],\"content\":\"")
        out.append(NostrEvent.escapeJSON(content))
        out.append("\",\"sig\":\"")
        out.append(sig)
        out.append("\"}")
        return out
    }

    fileprivate static func escapeJSON(_ s: String) -> String {
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

struct NostrFilter {
    var kinds: [Int]?
    var authors: [String]?
    var ids: [String]?
    var eTags: [String]?
    var pTags: [String]?
    var qTags: [String]?
    var hTags: [String]?
    var tTags: [String]?
    var dTags: [String]?
    var aTags: [String]?
    var limit: Int?
    var since: Int?
    var until: Int?
    var search: String?

    func toJSON() -> String {
        var dict: [String: Any] = [:]
        if let kinds { dict["kinds"] = kinds }
        if let authors { dict["authors"] = authors }
        if let ids { dict["ids"] = ids }
        if let eTags { dict["#e"] = eTags }
        if let pTags { dict["#p"] = pTags }
        if let qTags { dict["#q"] = qTags }
        if let hTags { dict["#h"] = hTags }
        if let tTags { dict["#t"] = tTags }
        if let dTags { dict["#d"] = dTags }
        if let aTags { dict["#a"] = aTags }
        if let limit { dict["limit"] = limit }
        if let since { dict["since"] = since }
        if let until { dict["until"] = until }
        if let search { dict["search"] = search }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
