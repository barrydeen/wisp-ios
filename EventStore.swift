import Foundation
import ObjectBox

actor EventStore {
    static let shared = EventStore()

    private var box: Box<EventEntity>?

    // 1068, 1018, 6969 are NIP-88 polls / poll responses and NIP-69 zap polls.
    private static let persistedKinds: Set<Int> = [0, 1, 6, 7, 9735, 10002, 10012, 20, 21, 22, 30000, 30002, 30003, 1068, 1018, 6969]

    private func ensureBox() -> Box<EventEntity>? {
        if box == nil {
            box = ObjectBoxSetup.store.box(for: EventEntity.self)
        }
        return box
    }

    // MARK: - Write

    func persist(_ events: [NostrEvent]) {
        guard let box = ensureBox() else { return }
        let eligible = events.filter { Self.persistedKinds.contains($0.kind) }
        guard !eligible.isEmpty else { return }

        // Dedupe within the batch — multiple sources (live subscription, profile
        // backfill, thread hydrator) often hand us the same event in the same
        // 200ms `EventPersistQueue` flush window. Without this dedup the unique
        // constraint on `EventEntity.eventId` aborts the entire put on the
        // first duplicate and the rest of the batch is dropped.
        var seen = Set<String>()
        var unique: [NostrEvent] = []
        unique.reserveCapacity(eligible.count)
        for e in eligible where seen.insert(e.id).inserted {
            unique.append(e)
        }

        // Skip events already on disk. Nostr events are immutable (signed),
        // so the on-disk row is authoritative; re-inserting the same event
        // is wasted work and would trigger the unique constraint.
        let ids = unique.map(\.id)
        let existingIds: Set<String>
        do {
            let existingQuery = try box.query { EventEntity.eventId.isIn(ids) }.build()
            existingIds = Set(try existingQuery.find().map(\.eventId))
        } catch {
            existingIds = []
        }

        let toPut = existingIds.isEmpty ? unique : unique.filter { !existingIds.contains($0.id) }
        guard !toPut.isEmpty else { return }
        let entities = toPut.map { EventEntity(from: $0) }
        try? box.put(entities)
    }

    // MARK: - Read

    func seedCache(limit: Int = 2000) -> [NostrEvent] {
        guard let box = ensureBox() else { return [] }
        do {
            let query = try box.query {
                EventEntity.kind == 1 || EventEntity.kind == 6 || EventEntity.kind == 20
                    || EventEntity.kind == Nip88.kindPoll || EventEntity.kind == Nip69.kindZapPoll
            }
            .ordered(by: EventEntity.createdAt, flags: .descending)
            .build()
            let entities = try query.find(offset: 0, limit: limit)
            return entities.compactMap { $0.toNostrEvent() }
        } catch {
            return []
        }
    }

    func newestTimestamp() -> Int? {
        guard let box = ensureBox() else { return nil }
        do {
            let query = try box.query {
                EventEntity.kind == 1 || EventEntity.kind == 6 || EventEntity.kind == 20
                    || EventEntity.kind == Nip88.kindPoll || EventEntity.kind == Nip69.kindZapPoll
            }
            .ordered(by: EventEntity.createdAt, flags: .descending)
            .build()
            return try query.findFirst()?.createdAt
        } catch {
            return nil
        }
    }

    /// Returns cached kind:6/7/9735 engagement events whose tags include any of
    /// `targetIds` as an `e` tag. Used to seed the engagement counts for a
    /// thread or feed view from disk so the user sees their last-known state
    /// instantly and the relay subscription only has to deliver deltas.
    func loadEngagement(forTargetIds targetIds: Set<String>) -> [NostrEvent] {
        guard let box = ensureBox(), !targetIds.isEmpty else { return [] }
        // Tag JSON is opaque to ObjectBox queries — the cheapest pre-filter is
        // a substring `contains` on any one target id, then per-event tag walk
        // in Swift. For a thread of N replies that's ~N substring scans of the
        // candidate set, which beats reading the entire engagement table.
        var out: [NostrEvent] = []
        var seenIds = Set<String>()
        for target in targetIds {
            do {
                let query = try box.query {
                    (EventEntity.kind == 6 || EventEntity.kind == 7 || EventEntity.kind == 9735)
                    && EventEntity.tags.contains(target)
                }.build()
                let candidates = try query.find(offset: 0, limit: 5000)
                for entity in candidates {
                    guard let event = entity.toNostrEvent(), !seenIds.contains(event.id) else { continue }
                    let matchesTarget = event.tags.contains { tag in
                        tag.count >= 2 && tag[0] == "e" && targetIds.contains(tag[1])
                    }
                    if matchesTarget {
                        seenIds.insert(event.id)
                        out.append(event)
                    }
                }
            } catch {
                continue
            }
        }
        return out
    }

    /// Returns cached kind:1 events that are part of the thread anchored at `rootId`:
    /// the root itself plus any event whose tags contain `["e", rootId, ...]`.
    /// Falls back to scanning all kind:1 events client-side because tags are stored as JSON.
    func loadThreadCache(rootId: String) -> [NostrEvent] {
        guard let box = ensureBox() else { return [] }
        do {
            let query = try box.query {
                EventEntity.kind == 1 && EventEntity.tags.contains(rootId)
            }.build()
            let entities = try query.find(offset: 0, limit: 5000)
            var results = entities.compactMap { $0.toNostrEvent() }
            // Also pull the root itself if it isn't matched by tag substring (i.e. it's the root note).
            if !results.contains(where: { $0.id == rootId }) {
                let rootQuery = try box.query { EventEntity.eventId == rootId }.build()
                if let entity = try rootQuery.findFirst(), let event = entity.toNostrEvent() {
                    results.append(event)
                }
            }
            return results
        } catch {
            return []
        }
    }

    /// Returns cached notification-relevant events (kinds 1/6/7/9735) that target the given
    /// pubkey, ordered by `createdAt` desc. Tags are stored as a JSON blob — we use a
    /// substring `contains(pubkey)` filter at the DB level to narrow candidates, then
    /// confirm tag-by-tag in Swift since the substring may also hit authors-of-content etc.
    func loadNotifications(pubkey: String, selfEventIds: Set<String>, limit: Int = 500) -> [NostrEvent] {
        guard let box = ensureBox() else { return [] }
        do {
            let query = try box.query {
                (EventEntity.kind == 1 || EventEntity.kind == 6 ||
                 EventEntity.kind == 7 || EventEntity.kind == 9735) &&
                EventEntity.tags.contains(pubkey)
            }
            .ordered(by: EventEntity.createdAt, flags: .descending)
            .build()
            let candidates = try query.find(offset: 0, limit: 4000)
            var out: [NostrEvent] = []
            out.reserveCapacity(min(candidates.count, limit))
            for entity in candidates {
                guard let event = entity.toNostrEvent() else { continue }
                var match = false
                for tag in event.tags {
                    guard tag.count >= 2 else { continue }
                    switch tag[0] {
                    case "p" where tag[1] == pubkey: match = true
                    case "e" where selfEventIds.contains(tag[1]): match = true
                    case "q" where selfEventIds.contains(tag[1]): match = true
                    default: break
                    }
                    if match { break }
                }
                if match {
                    out.append(event)
                    if out.count >= limit { break }
                }
            }
            return out
        } catch {
            return []
        }
    }

    /// Latest createdAt across cached notification-relevant kinds for the given pubkey.
    /// Drives the `since` cursor on the live-relay backfill query.
    func newestNotificationTimestamp(pubkey: String, selfEventIds: Set<String>) -> Int? {
        loadNotifications(pubkey: pubkey, selfEventIds: selfEventIds, limit: 1).first?.createdAt
    }

    // MARK: - Author lookups

    /// Bulk fetch of cached events by id, in arbitrary order. Used to seed the
    /// note-list feed before falling back to relays. Single indexed query
    /// against `EventEntity.eventId` (unique-indexed) — was an N+1 loop.
    func eventsByIds(_ ids: [String]) -> [NostrEvent] {
        guard let box = ensureBox(), !ids.isEmpty else { return [] }
        do {
            let query = try box.query { EventEntity.eventId.isIn(ids) }.build()
            return try query.find().compactMap { $0.toNostrEvent() }
        } catch {
            return []
        }
    }

    /// Most-recent kind-1 events by a given author. Used by the spam scorer to feed up to N
    /// recent notes from the same pubkey through the feature extractor.
    func loadRecentByAuthor(pubkey: String, limit: Int = 5) -> [NostrEvent] {
        guard let box = ensureBox() else { return [] }
        do {
            let query = try box.query {
                EventEntity.kind == 1 && EventEntity.pubkey == pubkey
            }
            .ordered(by: EventEntity.createdAt, flags: .descending)
            .build()
            let entities = try query.find(offset: 0, limit: limit)
            return entities.compactMap { $0.toNostrEvent() }
        } catch {
            return []
        }
    }

    /// Most-recent events of the given kinds by a single author. Lets the profile
    /// tab seed the Notes / Replies lists from cache so the user sees their
    /// latest content instantly while the relay round-trip catches up.
    /// Filters kind in Swift after the query because ObjectBox-Swift's int
    /// `isIn` semantics aren't straightforward; the over-fetch is bounded by
    /// `limit * 4` which is still cheap for a single author's events.
    func loadRecentByAuthor(pubkey: String, kinds: [Int], limit: Int) -> [NostrEvent] {
        guard let box = ensureBox(), !kinds.isEmpty else { return [] }
        do {
            let kindSet = Set(kinds)
            let query = try box.query { EventEntity.pubkey == pubkey }
                .ordered(by: EventEntity.createdAt, flags: .descending)
                .build()
            let entities = try query.find(offset: 0, limit: limit * 4)
            return entities
                .compactMap { $0.toNostrEvent() }
                .filter { kindSet.contains($0.kind) }
                .prefix(limit)
                .map { $0 }
        } catch {
            return []
        }
    }

    /// Remove every cached event by `pubkey`. Called on block so the author's existing notes
    /// disappear from feed reseeds and notification hydration.
    @discardableResult
    func removeByAuthor(_ pubkey: String) -> Int {
        guard let box = ensureBox() else { return 0 }
        do {
            let query = try box.query { EventEntity.pubkey == pubkey }.build()
            return try Int(query.remove())
        } catch {
            return 0
        }
    }

    // MARK: - Maintenance

    /// Drop every cached event. Called from `AppDataWipe` on logout. Leaves
    /// the box itself open so the next login can immediately persist again.
    func removeAll() {
        guard let box = ensureBox() else { return }
        try? box.removeAll()
    }

    func prune(maxAgeDays: Int = 90, maxEvents: Int = 50_000, protectedPubkey: String? = nil) {
        guard let box = ensureBox() else { return }
        do {
            let count = try box.count()
            guard count > maxEvents else { return }

            let cutoff = Int(Date().timeIntervalSince1970) - maxAgeDays * 86400
            if let pk = protectedPubkey {
                let query = try box.query {
                    EventEntity.createdAt < cutoff && EventEntity.pubkey.isNotEqual(to: pk)
                }.build()
                _ = try query.remove()
            } else {
                let query = try box.query {
                    EventEntity.createdAt < cutoff
                }.build()
                _ = try query.remove()
            }
        } catch {}
    }
}
