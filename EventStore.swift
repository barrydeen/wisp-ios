import Foundation
import ObjectBox

actor EventStore {
    static let shared = EventStore()

    private var box: Box<EventEntity>?

    // 1068, 1018, 6969 are NIP-88 polls / poll responses and NIP-69 zap polls.
    // 10030 / 30030 are NIP-30 user emoji list / emoji set (custom emoji packs).
    private static let persistedKinds: Set<Int> = [0, 1, 6, 7, 9735, 10002, 10012, 10030, 20, 21, 22, 30000, 30002, 30003, 30030, 1068, 1018, 6969]

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
        //
        // Chunk the isIn() query: ObjectBox builds the predicate as a recursive
        // OR tree, which blows the stack at ~200+ items. 100-item chunks keep
        // recursion depth well within limits.
        let ids = unique.map(\.id)
        var existingIds = Set<String>()
        let chunkSize = 100
        var chunkStart = 0
        while chunkStart < ids.count {
            let chunk = Array(ids[chunkStart ..< min(chunkStart + chunkSize, ids.count)])
            if let q = try? box.query({ EventEntity.eventId.isIn(chunk) }).build(),
               let found = try? q.find() {
                existingIds.formUnion(found.map(\.eventId))
            }
            chunkStart += chunkSize
        }

        let toPut = existingIds.isEmpty ? unique : unique.filter { !existingIds.contains($0.id) }
        guard !toPut.isEmpty else { return }
        let entities = toPut.map { EventEntity(from: $0) }
        try? box.put(entities)
    }

    // MARK: - Read

    /// Seed the home/feed cache from disk. `excludingEventIds` filters out
    /// gift-wrap-materialized private replies/reactions so they never bleed
    /// into the public timeline — `PrivateInteractionStore` is the source of
    /// truth for that set and the caller passes its current snapshot.
    func seedCache(limit: Int = 2000, excludingEventIds: Set<String> = []) -> [NostrEvent] {
        guard let box = ensureBox() else { return [] }
        do {
            let query = try box.query {
                EventEntity.kind == 1 || EventEntity.kind == 6 || EventEntity.kind == 20
                    || EventEntity.kind == Nip88.kindPoll || EventEntity.kind == Nip69.kindZapPoll
            }
            .ordered(by: EventEntity.createdAt, flags: .descending)
            .build()
            let entities = try query.find(offset: 0, limit: limit)
            let events = entities.compactMap { $0.toNostrEvent() }
            if excludingEventIds.isEmpty { return events }
            return events.filter { !excludingEventIds.contains($0.id) }
        } catch {
            return []
        }
    }

    /// Feed events strictly older than `before` (`createdAt`), newest-first.
    /// Mirrors `seedCache` but with a `createdAt < before` cursor so the feed
    /// can page scroll-back history in from disk. The caller filters by follows
    /// / renderability in Swift (same as the seed path's consumer).
    func loadOlder(before: Int, limit: Int = 400, excludingEventIds: Set<String> = []) -> [NostrEvent] {
        guard let box = ensureBox() else { return [] }
        do {
            let query = try box.query {
                (EventEntity.kind == 1 || EventEntity.kind == 6 || EventEntity.kind == 20
                    || EventEntity.kind == Nip88.kindPoll || EventEntity.kind == Nip69.kindZapPoll)
                    && EventEntity.createdAt < before
            }
            .ordered(by: EventEntity.createdAt, flags: .descending)
            .build()
            let entities = try query.find(offset: 0, limit: limit)
            let events = entities.compactMap { $0.toNostrEvent() }
            if excludingEventIds.isEmpty { return events }
            return events.filter { !excludingEventIds.contains($0.id) }
        } catch {
            return []
        }
    }

    /// Newest stored feed event timestamp. When `excludingPubkey` is set, the
    /// query skips that author so freshly-published own posts (e.g. a brand-new
    /// user's intro note) don't bias the `since` filter to "now - 5min" and
    /// hide every older follow note from the first feed load.
    func newestTimestamp(excludingPubkey: String? = nil) -> Int? {
        guard let box = ensureBox() else { return nil }
        do {
            if let exclude = excludingPubkey {
                let query = try box.query {
                    (EventEntity.kind == 1 || EventEntity.kind == 6 || EventEntity.kind == 20
                        || EventEntity.kind == Nip88.kindPoll || EventEntity.kind == Nip69.kindZapPoll)
                        && EventEntity.pubkey != exclude
                }
                .ordered(by: EventEntity.createdAt, flags: .descending)
                .build()
                return try query.findFirst()?.createdAt
            }
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

    /// Returns cached kind:6/7/9735 engagement events whose primary target
    /// (`engagementTargetId` — the last non-`mention` `e` tag) is any of
    /// `targetIds`. Used to seed the engagement counts for a thread or feed view
    /// from disk so the user sees their last-known state instantly and the relay
    /// subscription only has to deliver deltas.
    ///
    /// `engagementTargetId` is an indexed column (denormalized in
    /// `EventEntity.init(from:)`), so this is an `isIn` index lookup — cheap
    /// enough to run on the feed scroll hot path, unlike the prior per-target
    /// JSON-substring scan. Rows persisted before the column was added carry an
    /// empty target until `backfillEngagementTargetsIfNeeded` rewrites them.
    func loadEngagement(forTargetIds targetIds: Set<String>) -> [NostrEvent] {
        guard let box = ensureBox(), !targetIds.isEmpty else { return [] }
        var out: [NostrEvent] = []
        var seenIds = Set<String>()
        // Chunk `isIn` to keep ObjectBox's OR-tree shallow (same reason as the
        // `persist` existence check).
        let ids = Array(targetIds)
        let chunkSize = 100
        var chunkStart = 0
        while chunkStart < ids.count {
            let chunk = Array(ids[chunkStart ..< min(chunkStart + chunkSize, ids.count)])
            do {
                let query = try box.query {
                    (EventEntity.kind == 6 || EventEntity.kind == 7 || EventEntity.kind == 9735)
                    && EventEntity.engagementTargetId.isIn(chunk)
                }.build()
                let candidates = try query.find(offset: 0, limit: 5000)
                for entity in candidates {
                    guard let event = entity.toNostrEvent(), seenIds.insert(event.id).inserted else { continue }
                    out.append(event)
                }
            } catch {
                chunkStart += chunkSize
                continue
            }
            chunkStart += chunkSize
        }
        return out
    }

    /// One-time migration: populate `engagementTargetId` on kind 6/7/9735 rows
    /// persisted before the indexed column existed (ObjectBox defaults the new
    /// column to "" for existing rows, which the `isIn` index query never
    /// matches). Runs once per install, guarded by a `UserDefaults` flag, in
    /// chunks so a large engagement table doesn't spike memory. Until it
    /// completes, `loadEngagement` simply returns fewer cached rows and the live
    /// subscription backfills the rest — no correctness impact.
    private static let engagementBackfillFlag = "eventstore_engagement_backfill_v1"

    func backfillEngagementTargetsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.engagementBackfillFlag) else { return }
        guard let box = ensureBox() else { return }
        do {
            let query = try box.query {
                EventEntity.kind == 6 || EventEntity.kind == 7 || EventEntity.kind == 9735
            }.build()
            let pageSize = 2000
            var offset = 0
            while true {
                let page = try query.find(offset: offset, limit: pageSize)
                if page.isEmpty { break }
                var toUpdate: [EventEntity] = []
                for entity in page where entity.engagementTargetId.isEmpty {
                    guard let event = entity.toNostrEvent() else { continue }
                    let target = EventEntity.primaryEngagementTarget(of: event)
                    guard !target.isEmpty else { continue }
                    entity.engagementTargetId = target
                    toUpdate.append(entity)
                }
                if !toUpdate.isEmpty { try box.put(toUpdate) }
                if page.count < pageSize { break }
                offset += pageSize
            }
            UserDefaults.standard.set(true, forKey: Self.engagementBackfillFlag)
        } catch {
            // Leave the flag unset so the next launch retries.
        }
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

    /// Newest cached event of a single `kind` by `pubkey`. For replaceable
    /// singletons (kind 0 profile, 3 contacts, 10002 relay list, 30000-30003
    /// lists) this is the authoritative cached copy — lets repositories fall
    /// back to disk on a cold mem/UserDefaults miss instead of refetching from
    /// relays. Caller should still prefer fresher in-memory/UserDefaults copies.
    func loadLatestByAuthor(pubkey: String, kind: Int) -> NostrEvent? {
        guard let box = ensureBox() else { return nil }
        do {
            let query = try box.query {
                EventEntity.pubkey == pubkey && EventEntity.kind == kind
            }
            .ordered(by: EventEntity.createdAt, flags: .descending)
            .build()
            return try query.findFirst()?.toNostrEvent()
        } catch {
            return nil
        }
    }

    /// Newest cached event of `kind` for each of `pubkeys` (one per author).
    /// Lets a batch profile/relay-list resolve seed many authors from disk in a
    /// few chunked queries instead of an await-per-author loop.
    func loadLatestByAuthors(pubkeys: [String], kind: Int) -> [NostrEvent] {
        guard let box = ensureBox(), !pubkeys.isEmpty else { return [] }
        var newest: [String: NostrEvent] = [:]
        let chunkSize = 100
        var chunkStart = 0
        while chunkStart < pubkeys.count {
            let chunk = Array(pubkeys[chunkStart ..< min(chunkStart + chunkSize, pubkeys.count)])
            do {
                let query = try box.query {
                    EventEntity.kind == kind && EventEntity.pubkey.isIn(chunk)
                }
                .ordered(by: EventEntity.createdAt, flags: .descending)
                .build()
                // Newest-first; first sighting per author wins. Over-fetch to
                // tolerate lingering older replaceable copies.
                for entity in try query.find(offset: 0, limit: chunk.count * 4) {
                    guard let event = entity.toNostrEvent() else { continue }
                    if let existing = newest[event.pubkey], existing.createdAt >= event.createdAt { continue }
                    newest[event.pubkey] = event
                }
            } catch {}
            chunkStart += chunkSize
        }
        return Array(newest.values)
    }

    /// Newest cached event for each of `kinds` by `pubkey` (one per kind).
    /// Convenience batch over `loadLatestByAuthor` for callers bootstrapping
    /// several replaceable singletons at once.
    func loadReplaceableEvents(pubkey: String, kinds: [Int]) -> [NostrEvent] {
        guard ensureBox() != nil, !kinds.isEmpty else { return [] }
        var out: [NostrEvent] = []
        for kind in Set(kinds) {
            if let event = loadLatestByAuthor(pubkey: pubkey, kind: kind) {
                out.append(event)
            }
        }
        return out
    }

    /// Most-recent events of the given kinds across multiple authors, newest
    /// first. Lets member-list / people-list feeds seed from disk in one pass
    /// instead of a per-author query loop. Chunks the `isIn(pubkeys)` predicate
    /// to keep ObjectBox's OR-tree shallow (same reason as `persist`).
    func loadRecentByAuthors(pubkeys: [String], kinds: [Int], limit: Int) -> [NostrEvent] {
        guard let box = ensureBox(), !pubkeys.isEmpty, !kinds.isEmpty else { return [] }
        let kindSet = Set(kinds)
        var collected: [NostrEvent] = []
        var seen = Set<String>()
        let chunkSize = 100
        var chunkStart = 0
        while chunkStart < pubkeys.count {
            let chunk = Array(pubkeys[chunkStart ..< min(chunkStart + chunkSize, pubkeys.count)])
            do {
                let query = try box.query { EventEntity.pubkey.isIn(chunk) }
                    .ordered(by: EventEntity.createdAt, flags: .descending)
                    .build()
                let entities = try query.find(offset: 0, limit: limit * 4)
                for entity in entities {
                    guard let event = entity.toNostrEvent(),
                          kindSet.contains(event.kind),
                          seen.insert(event.id).inserted else { continue }
                    collected.append(event)
                }
            } catch {}
            chunkStart += chunkSize
        }
        return collected
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
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

    // MARK: - Emoji (NIP-30)

    /// Cached kind-10030 (user emoji list, replaceable) and kind-30030 packs
    /// authored by `pubkey`. Returns `(userList, ownPacks)` so the caller can
    /// replay them through its in-memory ingest before any network round-trip.
    func loadEmojiState(pubkey: String) -> (userList: NostrEvent?, ownPacks: [NostrEvent]) {
        guard let box = ensureBox() else { return (nil, []) }
        do {
            let listQuery = try box.query {
                EventEntity.kind == 10030 && EventEntity.pubkey == pubkey
            }
            .ordered(by: EventEntity.createdAt, flags: .descending)
            .build()
            let userList = try listQuery.findFirst()?.toNostrEvent()

            let packQuery = try box.query {
                EventEntity.kind == 30030 && EventEntity.pubkey == pubkey
            }.build()
            let ownPacks = try packQuery.find(offset: 0, limit: 200).compactMap { $0.toNostrEvent() }
            return (userList, ownPacks)
        } catch {
            return (nil, [])
        }
    }

    /// Cached kind-30030 packs matching any of the given `30030:<pubkey>:<d>` addresses.
    /// Filters in Swift after a kind-scoped query because the d-tag lives inside the
    /// JSON tag blob (not a top-level indexed column).
    func loadEmojiPacksByAddress(_ addrs: [String]) -> [NostrEvent] {
        guard let box = ensureBox(), !addrs.isEmpty else { return [] }
        // Parse "30030:<pubkey>:<d>" → (pubkey, dTag) lookup.
        var wanted: [String: Set<String>] = [:]  // pubkey → dTags
        for addr in addrs {
            let parts = addr.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, parts[0] == "30030" else { continue }
            wanted[parts[1], default: []].insert(parts[2])
        }
        guard !wanted.isEmpty else { return [] }
        do {
            let pubkeys = Array(wanted.keys)
            let query = try box.query {
                EventEntity.kind == 30030 && EventEntity.pubkey.isIn(pubkeys)
            }.build()
            let candidates = try query.find(offset: 0, limit: 1000)
            return candidates.compactMap { entity -> NostrEvent? in
                guard let event = entity.toNostrEvent() else { return nil }
                guard let dTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1] else { return nil }
                return wanted[event.pubkey]?.contains(dTag) == true ? event : nil
            }
        } catch {
            return []
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

/// Standard single-event-by-id resolver. Checks local caches in the cheapest-
/// first order before any relay round-trip, so every by-id path (thread root /
/// ancestors, quoted notes, notification deep-links) is cache-first:
///   1. `NotificationRepository` in-memory LRU — just-arrived events that may
///      not be flushed to the on-disk `EventStore` yet.
///   2. on-disk `EventStore`.
/// Returns nil on a full local miss; the caller falls back to a relay query.
@MainActor
enum EventLookup {
    static func local(id: String) async -> NostrEvent? {
        if let cached = NotificationRepository.shared.event(forId: id) { return cached }
        return await EventStore.shared.eventsByIds([id]).first
    }
}
