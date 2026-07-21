import Foundation
import Observation

/// In-memory state for the active user's NIP-29 groups. Mirrors the Kotlin
/// `GroupRepository` shape: joined rooms sorted by `lastMessageAt`,
/// per-room unread/notification flags, and a small write-through to
/// `GroupStore` for durability.
@Observable
@MainActor
final class GroupRepository {

    /// Owner / active-user pubkey (hex). All persistence is scoped to this id.
    let ownerPubkey: String

    var joinedGroups: [GroupRoom] = []
    var unreadGroupKeys: Set<String> = []
    var notifiedGroupKeys: Set<String> = []

    @ObservationIgnored private var roomsByKey: [String: GroupRoom] = [:]
    @ObservationIgnored private var seenMessageIds: Set<String> = []
    @ObservationIgnored private let store = GroupStore.shared

    init(ownerPubkey: String) {
        self.ownerPubkey = ownerPubkey
    }

    // MARK: - Hydration

    /// Load every joined group + last 200 messages each from disk.
    /// Call once when the repo is constructed for a fresh login.
    func seedFromDisk() async {
        let rooms = await store.loadAllMeta(ownerPubkey: ownerPubkey)
        for room in rooms {
            let msgs = await store.loadMessages(ownerPubkey: ownerPubkey,
                                                relayUrl: room.relayUrl, groupId: room.groupId)
            var hydrated = room
            hydrated.messages = msgs
            for m in msgs { seenMessageIds.insert(m.id) }
            roomsByKey[hydrated.id] = hydrated
        }
        // Restore per-pubkey flags.
        unreadGroupKeys = Set(UserDefaults.standard.stringArray(forKey: unreadKey) ?? [])
        notifiedGroupKeys = Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? [])
        rebuildList()
    }

    // MARK: - Join / leave

    @discardableResult
    func addGroup(relayUrl: String, groupId: String, name: String? = nil) -> GroupRoom {
        let key = "\(relayUrl)|\(groupId)"
        if let existing = roomsByKey[key] { return existing }
        let metadata = GroupMetadata(groupId: groupId, name: name, picture: nil, about: nil,
                                     isPrivate: false, isClosed: false,
                                     isRestricted: false, isHidden: false)
        let room = GroupRoom(groupId: groupId, relayUrl: relayUrl, metadata: metadata,
                             messages: [], lastMessageAt: 0, admins: [], members: [])
        roomsByKey[key] = room
        Task { await store.upsertMeta(ownerPubkey: ownerPubkey, room: room) }
        rebuildList()
        return room
    }

    func removeGroup(relayUrl: String, groupId: String) {
        let key = "\(relayUrl)|\(groupId)"
        roomsByKey.removeValue(forKey: key)
        unreadGroupKeys.remove(key)
        notifiedGroupKeys.remove(key)
        persistFlagSets()
        Task { await store.deleteMeta(ownerPubkey: ownerPubkey,
                                      relayUrl: relayUrl, groupId: groupId) }
        rebuildList()
    }

    // MARK: - Updates

    func updateMetadata(_ metadata: GroupMetadata, relayUrl: String) {
        let key = "\(relayUrl)|\(metadata.groupId)"
        guard var room = roomsByKey[key] else { return }
        room.metadata = metadata
        roomsByKey[key] = room
        Task { await store.upsertMeta(ownerPubkey: ownerPubkey, room: room) }
        rebuildList()
    }

    func updateAdmins(_ admins: [String], relayUrl: String, groupId: String) {
        let key = "\(relayUrl)|\(groupId)"
        guard var room = roomsByKey[key] else { return }
        room.admins = admins
        roomsByKey[key] = room
        Task { await store.upsertMeta(ownerPubkey: ownerPubkey, room: room) }
        rebuildList()
    }

    func updateMembers(_ members: [String], relayUrl: String, groupId: String) {
        let key = "\(relayUrl)|\(groupId)"
        guard var room = roomsByKey[key] else { return }
        room.members = members
        roomsByKey[key] = room
        Task { await store.upsertMeta(ownerPubkey: ownerPubkey, room: room) }
        rebuildList()
    }

    func addMessage(_ message: GroupMessage, relayUrl: String, groupId: String) {
        let key = "\(relayUrl)|\(groupId)"
        guard var room = roomsByKey[key] else { return }
        // Dedup by event id.
        guard seenMessageIds.insert(message.id).inserted else { return }
        room.messages.append(message)
        // Tie-break equal timestamps by id so clamped messages keep a stable order.
        room.messages.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        if message.createdAt > room.lastMessageAt {
            room.lastMessageAt = message.createdAt
        }
        roomsByKey[key] = room
        if message.senderPubkey != ownerPubkey {
            unreadGroupKeys.insert(key)
            persistFlagSets()
        }
        let owner = ownerPubkey
        Task {
            await store.enqueueMessage(ownerPubkey: owner, relayUrl: relayUrl,
                                       groupId: groupId, message: message)
            await store.upsertMeta(ownerPubkey: owner, room: room)
        }
        rebuildList()
    }

    func addReaction(messageId: String, reactorPubkey: String, emoji: String,
                     emojiUrl: String?, relayUrl: String, groupId: String) {
        let key = "\(relayUrl)|\(groupId)"
        guard var room = roomsByKey[key] else { return }
        if let emojiUrl, !emojiUrl.isEmpty {
            room.reactionEmojiUrls[emoji] = emojiUrl
        }
        if let idx = room.messages.firstIndex(where: { $0.id == messageId }) {
            var msg = room.messages[idx]
            var reactors = msg.reactions[emoji, default: []]
            if !reactors.contains(reactorPubkey) {
                reactors.append(reactorPubkey)
                msg.reactions[emoji] = reactors
                room.messages[idx] = msg
            }
        }
        roomsByKey[key] = room
        rebuildList()
    }

    // MARK: - Flags

    func setNotified(_ enabled: Bool, relayUrl: String, groupId: String) {
        let key = "\(relayUrl)|\(groupId)"
        if enabled { notifiedGroupKeys.insert(key) }
        else { notifiedGroupKeys.remove(key) }
        persistFlagSets()
    }

    func markRead(relayUrl: String, groupId: String) {
        let key = "\(relayUrl)|\(groupId)"
        unreadGroupKeys.remove(key)
        persistFlagSets()
    }

    // MARK: - Lookups

    func getRoom(relayUrl: String, groupId: String) -> GroupRoom? {
        roomsByKey["\(relayUrl)|\(groupId)"]
    }

    func getJoinedGroupKeys() -> [(relayUrl: String, groupId: String, name: String?)] {
        joinedGroups.map { ($0.relayUrl, $0.groupId, $0.metadata?.name) }
    }

    // MARK: - Internals

    private func rebuildList() {
        joinedGroups = roomsByKey.values.sorted { lhs, rhs in
            if lhs.lastMessageAt != rhs.lastMessageAt {
                return lhs.lastMessageAt > rhs.lastMessageAt
            }
            return (lhs.metadata?.name ?? lhs.groupId) < (rhs.metadata?.name ?? rhs.groupId)
        }
    }

    private var unreadKey: String { "group_unread_\(ownerPubkey)" }
    private var notifiedKey: String { "group_notified_\(ownerPubkey)" }

    private func persistFlagSets() {
        UserDefaults.standard.set(Array(unreadGroupKeys), forKey: unreadKey)
        UserDefaults.standard.set(Array(notifiedGroupKeys), forKey: notifiedKey)
    }
}
