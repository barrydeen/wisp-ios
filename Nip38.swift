import Foundation

/// NIP-38 User Statuses. Spec: https://github.com/nostr-protocol/nips/blob/master/38.md
///
/// Addressable kind-30315 events. The `d` tag identifies the status type
/// ("general" for free-form text, "music" for now-playing). We only handle
/// "general" — clearing publishes a newer 30315 with empty content (replaces
/// the previous addressable event).
enum Nip38 {
    static let kindUserStatus: Int = 30315
    static let dTagGeneral: String = "general"

    /// Build & sign a kind-30315 status event. Empty content is a valid
    /// "clear" — relays will replace any earlier 30315/general event.
    static func buildStatus(
        privkey32: Data,
        pubkey: String,
        content: String,
        dTag: String = dTagGeneral,
        createdAt: Int = Int(Date().timeIntervalSince1970)
    ) throws -> NostrEvent {
        var tags: [[String]] = [["d", dTag]]
        if let clientTag = NostrEvent.clientTagIfEnabled() { tags.append(clientTag) }
        return try NostrEvent.sign(
            privkey32: privkey32,
            pubkey: pubkey,
            kind: kindUserStatus,
            createdAt: createdAt,
            tags: tags,
            content: content
        )
    }
}
