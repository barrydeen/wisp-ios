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
    /// Stable composite id: "<giftWrapId>:<rumorCreatedAt>". Encodes which envelope delivered
    /// this message so duplicate gift wraps from multiple relays collapse cleanly.
    let id: String
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

    var isFile: Bool { fileMetadata != nil }
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
