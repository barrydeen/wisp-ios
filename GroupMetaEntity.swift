import Foundation
import ObjectBox

// objectbox: entity
//
// `nonisolated` so the `GroupStore` actor and the ObjectBox generated
// descriptors / bindings (which extend this type) don't cross actor
// boundaries on every property access. See `EventEntity.swift` for context.
nonisolated class GroupMetaEntity {
    var id: Id = 0

    /// `"\(ownerPubkey)|\(relayUrl)|\(groupId)"` — see `groupRoomKey(...)` in GroupModels.
    // objectbox: unique
    var roomKey: String = ""

    // objectbox: index
    var ownerPubkey: String = ""

    var relayUrl: String = ""
    var groupId: String = ""

    var name: String? = nil
    var picture: String? = nil
    var about: String? = nil

    var isPrivate: Bool = false
    var isClosed: Bool = false
    var isRestricted: Bool = false
    var isHidden: Bool = false

    /// JSON-encoded `[String]` of admin pubkeys (hex).
    var adminsJson: String = "[]"
    /// JSON-encoded `[String]` of member pubkeys (hex).
    var membersJson: String = "[]"

    var lastMessageAt: Int = 0

    required init() {}

    convenience init(ownerPubkey: String, room: GroupRoom) {
        self.init()
        self.roomKey = groupRoomKey(ownerPubkey: ownerPubkey, relayUrl: room.relayUrl, groupId: room.groupId)
        self.ownerPubkey = ownerPubkey
        self.relayUrl = room.relayUrl
        self.groupId = room.groupId
        self.name = room.metadata?.name
        self.picture = room.metadata?.picture
        self.about = room.metadata?.about
        self.isPrivate    = room.metadata?.isPrivate ?? false
        self.isClosed     = room.metadata?.isClosed ?? false
        self.isRestricted = room.metadata?.isRestricted ?? false
        self.isHidden     = room.metadata?.isHidden ?? false
        self.adminsJson = (try? String(data: JSONSerialization.data(withJSONObject: room.admins), encoding: .utf8)) ?? "[]"
        self.membersJson = (try? String(data: JSONSerialization.data(withJSONObject: room.members), encoding: .utf8)) ?? "[]"
        self.lastMessageAt = room.lastMessageAt
    }

    func decodeAdmins() -> [String] {
        guard let data = adminsJson.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return arr
    }

    func decodeMembers() -> [String] {
        guard let data = membersJson.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return arr
    }

    func toRoom() -> GroupRoom {
        let metadata = GroupMetadata(groupId: groupId, name: name, picture: picture, about: about,
                                     isPrivate: isPrivate, isClosed: isClosed,
                                     isRestricted: isRestricted, isHidden: isHidden)
        return GroupRoom(groupId: groupId, relayUrl: relayUrl, metadata: metadata,
                         messages: [], lastMessageAt: lastMessageAt,
                         admins: decodeAdmins(), members: decodeMembers())
    }
}
