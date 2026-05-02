import Foundation

/// NIP-25 — Reaction events (kind 7).
///
/// `content` is a single unicode emoji character or a NIP-30 `:shortcode:` reference.
/// Tags carry the target's identifiers per the spec:
///   - `["e", <eventId>, <relayHint>?, <pubkey>?]`  — the event being reacted to (REQUIRED)
///   - `["p", <pubkey>, <relayHint>?]`              — the author of the target event (SHOULD)
///   - `["k", "<kind>"]`                            — the kind of the target event (MAY)
///   - `["emoji", <shortcode>, <imageURL>]`         — included only for NIP-30 custom emoji reactions
///
/// Mirrors `Nip29.buildReaction` so the feed reaction path matches the
/// shape of the existing group-chat reaction path.
nonisolated enum Nip25 {
    static let kindReaction = 7

    /// Build the canonical NIP-25 tag set without signing. Used by the PoW path,
    /// which mines a nonce tag onto these tags before signing.
    static func reactionTags(
        targetEvent: NostrEvent,
        customEmoji: (shortcode: String, url: String)? = nil,
        relayHint: String? = nil
    ) -> [[String]] {
        var eTag: [String] = ["e", targetEvent.id]
        var pTag: [String] = ["p", targetEvent.pubkey]
        if let hint = relayHint, !hint.isEmpty {
            eTag.append(hint)
            eTag.append(targetEvent.pubkey)
            pTag.append(hint)
        }

        var tags: [[String]] = [
            eTag,
            pTag,
            ["k", String(targetEvent.kind)]
        ]
        if let custom = customEmoji {
            tags.append(["emoji", custom.shortcode, custom.url])
        }
        if let clientTag = NostrEvent.clientTagIfEnabled() {
            tags.append(clientTag)
        }
        return tags
    }

    static func buildReaction(
        privkey32: Data,
        pubkey: String,
        targetEvent: NostrEvent,
        emoji: String,
        customEmoji: (shortcode: String, url: String)? = nil,
        relayHint: String? = nil,
        createdAt: Int = Int(Date().timeIntervalSince1970)
    ) throws -> NostrEvent {
        let tags = reactionTags(targetEvent: targetEvent, customEmoji: customEmoji, relayHint: relayHint)
        return try NostrEvent.sign(
            privkey32: privkey32,
            pubkey: pubkey,
            kind: kindReaction,
            createdAt: createdAt,
            tags: tags,
            content: emoji
        )
    }
}
