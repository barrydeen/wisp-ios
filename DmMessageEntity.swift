import Foundation
import ObjectBox

// objectbox: entity
//
// `nonisolated` so the `DmStore` actor and the ObjectBox generated descriptors /
// bindings (which extend this type) don't cross actor boundaries on every property
// access. See `EventEntity.swift` / `GroupMessageEntity.swift` for context.
//
// Thin entity: the whole decrypted `DmMessage` is serialized into `payloadJson`.
// Only the columns we actually query (`ownerPlusGiftWrap` for upsert dedup,
// `ownerPubkey` for per-account load/wipe) are first-class. Grouping by
// `conversationKey` and ordering by `createdAt` happen in memory after `loadAll`.
nonisolated class DmMessageEntity {
    var id: Id = 0

    /// `"\(ownerPubkey)|\(giftWrapId)"`. Unique idempotent upsert key — duplicate
    /// gift wraps from multiple relays collapse to one row.
    // objectbox: unique
    var ownerPlusGiftWrap: String = ""

    /// Active account pubkey. Indexed for `loadAll` / `deleteAllForOwner`.
    // objectbox: index
    var ownerPubkey: String = ""

    /// Sorted-participant conversation key (returned alongside the decoded message).
    var conversationKey: String = ""

    /// Rumor createdAt — kept as a column for cheap ordering if ever needed.
    var createdAt: Int = 0

    /// JSON-encoded `DmMessage` (content, sender, rumorId, replyToId, participants,
    /// relayUrls, reactions, emojiMap, fileMetadata).
    var payloadJson: String = ""

    required init() {}

    convenience init(ownerPubkey: String, conversationKey: String, msg: DmMessage) {
        self.init()
        self.ownerPlusGiftWrap = "\(ownerPubkey)|\(msg.giftWrapId)"
        self.ownerPubkey = ownerPubkey
        self.conversationKey = conversationKey
        self.createdAt = msg.createdAt
        self.payloadJson = (try? String(data: JSONEncoder().encode(msg), encoding: .utf8) ?? "") ?? ""
    }

    /// Decode back into `(conversationKey, DmMessage)`, or nil if the payload is corrupt.
    func toEntry() -> (convKey: String, msg: DmMessage)? {
        guard let data = payloadJson.data(using: .utf8),
              let msg = try? JSONDecoder().decode(DmMessage.self, from: data) else { return nil }
        return (conversationKey, msg)
    }
}
