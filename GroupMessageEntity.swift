import Foundation
import ObjectBox

// objectbox: entity
//
// `nonisolated` so the `GroupStore` actor and the ObjectBox generated
// descriptors / bindings (which extend this type) don't cross actor
// boundaries on every property access. See `EventEntity.swift` for context.
nonisolated class GroupMessageEntity {
    var id: Id = 0

    /// Source NIP-29 event id (kind 9).
    // objectbox: unique
    var eventId: String = ""

    /// `"\(ownerPubkey)|\(relayUrl)|\(groupId)"`. Indexed for fast per-room lookup.
    // objectbox: index
    var roomKey: String = ""

    var senderPubkey: String = ""
    var content: String = ""

    // objectbox: index
    var createdAt: Int = 0

    /// `q`-tag reply target id (or `e`-tag with `reply` marker fallback).
    var replyToId: String? = nil

    required init() {}

    convenience init(ownerPubkey: String, relayUrl: String, groupId: String, message: GroupMessage) {
        self.init()
        self.eventId = message.id
        self.roomKey = groupRoomKey(ownerPubkey: ownerPubkey, relayUrl: relayUrl, groupId: groupId)
        self.senderPubkey = message.senderPubkey
        self.content = message.content
        self.createdAt = message.createdAt
        self.replyToId = message.replyToId
    }

    func toMessage() -> GroupMessage {
        GroupMessage(id: eventId, senderPubkey: senderPubkey, content: content,
                     createdAt: createdAt, replyToId: replyToId)
    }
}
