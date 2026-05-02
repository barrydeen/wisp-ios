import Foundation

nonisolated enum Nip18 {

    /// Tags for a kind-1 quote-repost referencing another event.
    /// Spec: `q` for the quoted id, `p` for the quoted author.
    static func buildQuoteTags(event: NostrEvent, relayHint: String = "") -> [[String]] {
        return [
            ["q", event.id, relayHint],
            ["p", event.pubkey]
        ]
    }

    /// Append a quote URI (`\nnostr:nevent1...`) to the given content.
    static func appendNoteUri(content: String, eventIdHex: String, relayHints: [String] = [], authorHex: String? = nil) -> String {
        guard let idBytes = Hex.decode(eventIdHex) else { return content }
        let authorBytes: [UInt8]?
        if let authorHex, let bytes = Hex.decode(authorHex) {
            authorBytes = Array(bytes)
        } else {
            authorBytes = nil
        }
        guard let nevent = Nip19.neventEncode(eventId32: Array(idBytes), relays: relayHints, author32: authorBytes) else {
            return content
        }
        if content.isEmpty { return "nostr:\(nevent)" }
        return "\(content)\nnostr:\(nevent)"
    }
}
