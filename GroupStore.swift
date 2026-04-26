import Foundation
import ObjectBox

/// Actor wrapper around the two NIP-29 ObjectBox boxes (`GroupMetaEntity`,
/// `GroupMessageEntity`). Mirrors the Android pattern of debounced batched
/// writes for messages so we don't pay a `box.put` per incoming chat message.
actor GroupStore {

    static let shared = GroupStore()

    private var metaBox: Box<GroupMetaEntity>?
    private var messageBox: Box<GroupMessageEntity>?

    private var pendingMessages: [GroupMessageEntity] = []
    private var flushTask: Task<Void, Never>?

    /// Debounce window. Matches the Android client.
    private let flushDelay: Duration = .milliseconds(200)
    /// Batch size threshold — flush eagerly past this many queued messages.
    private let flushThreshold = 50

    private func ensureBoxes() -> (Box<GroupMetaEntity>, Box<GroupMessageEntity>)? {
        if metaBox == nil { metaBox = ObjectBoxSetup.store.box(for: GroupMetaEntity.self) }
        if messageBox == nil { messageBox = ObjectBoxSetup.store.box(for: GroupMessageEntity.self) }
        guard let metaBox, let messageBox else { return nil }
        return (metaBox, messageBox)
    }

    // MARK: - Meta (rooms)

    func upsertMeta(ownerPubkey: String, room: GroupRoom) {
        guard let (metaBox, _) = ensureBoxes() else { return }
        let key = groupRoomKey(ownerPubkey: ownerPubkey, relayUrl: room.relayUrl, groupId: room.groupId)
        do {
            let existing = try metaBox.query { GroupMetaEntity.roomKey == key }.build().findFirst()
            let entity = existing ?? GroupMetaEntity()
            entity.roomKey = key
            entity.ownerPubkey = ownerPubkey
            entity.relayUrl = room.relayUrl
            entity.groupId = room.groupId
            entity.name = room.metadata?.name ?? entity.name
            entity.picture = room.metadata?.picture ?? entity.picture
            entity.about = room.metadata?.about ?? entity.about
            entity.isPrivate    = room.metadata?.isPrivate    ?? entity.isPrivate
            entity.isClosed     = room.metadata?.isClosed     ?? entity.isClosed
            entity.isRestricted = room.metadata?.isRestricted ?? entity.isRestricted
            entity.isHidden     = room.metadata?.isHidden     ?? entity.isHidden
            if !room.admins.isEmpty {
                entity.adminsJson = (try? String(data: JSONSerialization.data(withJSONObject: room.admins), encoding: .utf8)) ?? entity.adminsJson
            }
            if !room.members.isEmpty {
                entity.membersJson = (try? String(data: JSONSerialization.data(withJSONObject: room.members), encoding: .utf8)) ?? entity.membersJson
            }
            if room.lastMessageAt > entity.lastMessageAt {
                entity.lastMessageAt = room.lastMessageAt
            }
            try metaBox.put(entity)
        } catch { /* swallow — DB errors are non-fatal here */ }
    }

    func deleteMeta(ownerPubkey: String, relayUrl: String, groupId: String) {
        guard let (metaBox, messageBox) = ensureBoxes() else { return }
        let key = groupRoomKey(ownerPubkey: ownerPubkey, relayUrl: relayUrl, groupId: groupId)
        do {
            if let entity = try metaBox.query({ GroupMetaEntity.roomKey == key }).build().findFirst() {
                try metaBox.remove(entity)
            }
            // Also wipe its messages.
            let msgQuery = try messageBox.query({ GroupMessageEntity.roomKey == key }).build()
            _ = try msgQuery.remove()
        } catch {}
    }

    func loadAllMeta(ownerPubkey: String) -> [GroupRoom] {
        guard let (metaBox, _) = ensureBoxes() else { return [] }
        do {
            let query = try metaBox.query { GroupMetaEntity.ownerPubkey == ownerPubkey }.build()
            let entities = try query.find()
            return entities.map { $0.toRoom() }
        } catch { return [] }
    }

    // MARK: - Messages (debounced)

    func enqueueMessage(ownerPubkey: String, relayUrl: String, groupId: String, message: GroupMessage) {
        let entity = GroupMessageEntity(ownerPubkey: ownerPubkey, relayUrl: relayUrl,
                                        groupId: groupId, message: message)
        pendingMessages.append(entity)
        if pendingMessages.count >= flushThreshold {
            flushNow()
        } else {
            scheduleFlush()
        }
    }

    private func scheduleFlush() {
        if flushTask != nil { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            await self?.flushNow()
        }
    }

    private func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingMessages.isEmpty,
              let (_, messageBox) = ensureBoxes() else { return }
        let batch = pendingMessages
        pendingMessages.removeAll()
        do { try messageBox.put(batch) } catch {}
    }

    func loadMessages(ownerPubkey: String, relayUrl: String, groupId: String,
                      limit: Int = 200) -> [GroupMessage] {
        guard let (_, messageBox) = ensureBoxes() else { return [] }
        let key = groupRoomKey(ownerPubkey: ownerPubkey, relayUrl: relayUrl, groupId: groupId)
        do {
            let query = try messageBox.query { GroupMessageEntity.roomKey == key }
                .ordered(by: GroupMessageEntity.createdAt, flags: .descending)
                .build()
            let entities = try query.find(offset: 0, limit: limit)
            return entities.map { $0.toMessage() }.reversed()  // chronological for UI
        } catch { return [] }
    }

    func wipe(ownerPubkey: String) {
        guard let (metaBox, messageBox) = ensureBoxes() else { return }
        do {
            let metaQ = try metaBox.query { GroupMetaEntity.ownerPubkey == ownerPubkey }.build()
            let metaEntities = try metaQ.find()
            let keys = metaEntities.map { $0.roomKey }
            _ = try metaQ.remove()
            for key in keys {
                let q = try messageBox.query { GroupMessageEntity.roomKey == key }.build()
                _ = try q.remove()
            }
        } catch {}
    }

    /// Drop every cached group + message across all owners. Called from
    /// `AppDataWipe` on logout. Pending in-memory writes are abandoned.
    func removeAll() {
        flushTask?.cancel()
        flushTask = nil
        pendingMessages.removeAll()
        guard let (metaBox, messageBox) = ensureBoxes() else { return }
        try? metaBox.removeAll()
        try? messageBox.removeAll()
    }
}
