import Foundation
import ObjectBox

/// Actor wrapper around the `DmMessageEntity` ObjectBox box. Mirrors `GroupStore`'s
/// debounced batched-write pattern so we don't pay a `box.put` per incoming DM, and
/// gives `DmRepository` durable storage so conversations survive cold start (Android
/// `DmPersistence`). Decrypted messages are stored as a JSON payload column keyed by
/// `"<owner>|<giftWrapId>"` for idempotent upsert.
actor DmStore {

    static let shared = DmStore()

    private var box: Box<DmMessageEntity>?

    private var pending: [DmMessageEntity] = []
    private var flushTask: Task<Void, Never>?

    /// Debounce window. Matches `GroupStore` / the Android client.
    private let flushThreshold = 50

    private func ensureBox() -> Box<DmMessageEntity>? {
        if box == nil { box = ObjectBoxSetup.store.box(for: DmMessageEntity.self) }
        return box
    }

    // MARK: - Write (debounced upsert)

    func enqueue(ownerPubkey: String, conversationKey: String, msg: DmMessage) {
        guard !ownerPubkey.isEmpty, !msg.giftWrapId.isEmpty else { return }
        let entity = DmMessageEntity(ownerPubkey: ownerPubkey, conversationKey: conversationKey, msg: msg)
        pending.append(entity)
        if pending.count >= flushThreshold {
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
        guard !pending.isEmpty, let box = ensureBox() else { return }

        // Collapse to the latest state per key so a message + its later reaction edits
        // (each enqueued as a fresh entity) write once with the newest payload, and a
        // unique-key in-batch collision can't abort the whole put.
        var latest: [String: DmMessageEntity] = [:]
        for e in pending { latest[e.ownerPlusGiftWrap] = e }
        pending.removeAll()
        let entities = Array(latest.values)

        do {
            // Resolve existing row ids so put() updates in place (upsert) rather than
            // tripping the unique constraint on ownerPlusGiftWrap.
            for e in entities {
                if let existing = try box.query({ DmMessageEntity.ownerPlusGiftWrap == e.ownerPlusGiftWrap })
                    .build().findFirst() {
                    e.id = existing.id
                }
            }
            try box.put(entities)
        } catch {}
    }

    // MARK: - Read

    /// All persisted messages for the account, as `(conversationKey, DmMessage)` pairs.
    /// Unordered — `DmRepository` sorts each conversation by `createdAt` on hydration.
    func loadAll(ownerPubkey: String) -> [(convKey: String, msg: DmMessage)] {
        guard !ownerPubkey.isEmpty, let box = ensureBox() else { return [] }
        do {
            let query = try box.query { DmMessageEntity.ownerPubkey == ownerPubkey }.build()
            let entities = try query.find()
            return entities.compactMap { $0.toEntry() }
        } catch { return [] }
    }

    // MARK: - Maintenance

    func deleteAllForOwner(_ ownerPubkey: String) {
        guard !ownerPubkey.isEmpty, let box = ensureBox() else { return }
        do {
            let query = try box.query { DmMessageEntity.ownerPubkey == ownerPubkey }.build()
            _ = try query.remove()
        } catch {}
    }

    /// Drop every persisted DM across all owners. Called from `AppDataWipe` on logout.
    func removeAll() {
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
        guard let box = ensureBox() else { return }
        try? box.removeAll()
    }
}
