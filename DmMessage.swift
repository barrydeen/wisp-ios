import Foundation

/// A reaction (kind-7 rumor, `k=14`) attached to a DM message. Deduped by
/// `(authorPubkey, emoji)` in `DmRepository.addReaction`.
struct DmReaction: Codable, Equatable {
    let authorPubkey: String
    /// Unicode char or `:shortcode:` for custom emoji.
    let emoji: String
    let timestamp: Int
    /// Custom-emoji image URL (NIP-30), if `emoji` is a `:shortcode:`.
    let emojiUrl: String?
}

/// Metadata for a NIP-17 kind-15 encrypted file message. The blob at `fileUrl`
/// is AES-256-GCM ciphertext (Blossom-hosted); `keyHex`/`nonceHex` decrypt it.
/// Mirrors Android `EncryptedMedia` tag set.
struct EncryptedFileMetadata: Codable, Equatable {
    let fileUrl: String
    let mimeType: String
    /// Always "aes-gcm" today.
    let algorithm: String
    let keyHex: String
    let nonceHex: String
    /// sha256 of the encrypted blob (`x` tag).
    let encryptedHash: String?
    /// sha256 of the original plaintext (`ox` tag).
    let originalHash: String?
    let size: Int?
    /// "WxH".
    let dimensions: String?
    let blurhash: String?
}

struct DmMessage: Identifiable, Equatable, Codable {
    /// Delivery lifecycle for an outgoing message. Received messages and anything
    /// loaded from disk are always `.sent` (the default makes decoding old rows safe).
    enum SendState: String, Codable { case sending, sent, failed }

    /// Stable composite id. For delivered messages: "<giftWrapId>:<rumorCreatedAt>" —
    /// encodes which envelope delivered this message so duplicate gift wraps from
    /// multiple relays collapse cleanly. For an in-flight optimistic message it is a
    /// temporary "pending:<uuid>" id, rewritten to the composite id once published.
    var id: String
    let senderPubkey: String
    /// For chat messages this is the text; for kind-15 file messages this is the Blossom URL.
    let content: String
    /// Rumor's createdAt (the actual semantic time the message was authored), NOT the wrap's
    /// randomized time.
    let createdAt: Int
    let giftWrapId: String
    let rumorId: String
    let replyToId: String?
    /// All conversation participants except the local user, sorted.
    let participants: [String]
    var relayUrls: Set<String> = []
    /// Emoji reactions on this message (kind-7 `k=14`), deduped by (author, emoji).
    var reactions: [DmReaction] = []
    /// NIP-30 shortcode → image URL map carried on the rumor (for rendering custom emoji in content).
    var emojiMap: [String: String] = [:]
    /// Set when this is a kind-15 encrypted file message.
    var fileMetadata: EncryptedFileMetadata? = nil
    /// Outgoing delivery state. Defaults to `.sent` so received messages and rows
    /// decoded from disk (which predate this field) are unaffected — see the custom
    /// `init(from:)` below, which actually applies these defaults on decode.
    var sendState: SendState = .sent

    var isFile: Bool { fileMetadata != nil }

    enum CodingKeys: String, CodingKey {
        case id, senderPubkey, content, createdAt, giftWrapId, rumorId
        case replyToId, participants, relayUrls, reactions, emojiMap, fileMetadata, sendState
    }
}

extension DmMessage {
    /// Tolerant decoder: Swift's *synthesized* `Codable` does NOT apply a stored
    /// property's default value when a key is missing — it throws `keyNotFound`. That
    /// would drop every DM row persisted before a field was added (e.g. `sendState`,
    /// added with optimistic send) on hydration. Decoding the post-`id` fields with
    /// `decodeIfPresent`, falling back to the same defaults, keeps old rows readable.
    /// Encoding stays synthesized (always writes the current shape).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        senderPubkey = try c.decode(String.self, forKey: .senderPubkey)
        content = try c.decode(String.self, forKey: .content)
        createdAt = try c.decode(Int.self, forKey: .createdAt)
        giftWrapId = try c.decode(String.self, forKey: .giftWrapId)
        rumorId = try c.decode(String.self, forKey: .rumorId)
        replyToId = try c.decodeIfPresent(String.self, forKey: .replyToId)
        participants = try c.decode([String].self, forKey: .participants)
        relayUrls = try c.decodeIfPresent(Set<String>.self, forKey: .relayUrls) ?? []
        reactions = try c.decodeIfPresent([DmReaction].self, forKey: .reactions) ?? []
        emojiMap = try c.decodeIfPresent([String: String].self, forKey: .emojiMap) ?? [:]
        fileMetadata = try c.decodeIfPresent(EncryptedFileMetadata.self, forKey: .fileMetadata)
        sendState = try c.decodeIfPresent(SendState.self, forKey: .sendState) ?? .sent
    }
}

struct DmConversation: Identifiable, Equatable {
    var id: String { conversationKey }
    let conversationKey: String
    let participants: [String]
    let messages: [DmMessage]
    let lastMessageAt: Int

    var isGroup: Bool { participants.count > 1 }
    var peerPubkey: String { participants.first ?? conversationKey }
}
