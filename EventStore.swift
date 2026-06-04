import Foundation
import ObjectBox

actor EventStore {
    static let shared = EventStore()

    private var box: Box<EventEntity>?

    // 1068, 1018, 6969 are NIP-88 polls / poll responses and NIP-69 zap polls.
    // 10030 / 30030 are NIP-30 user emoji list / emoji set (custom emoji packs).
    private static let persistedKinds: Set<Int> = [0, 1, 6, 7, 9735, 10002, 10012, 10030, 20, 21, 22, 30000, 30002, 30003, 30030, 1068, 1018, 6969]

    /// Kinds retained on disk *even for a blocked author* so the block-list
    /// settings UI, name/avatar resolution, and installed emoji packs keep
    /// working (and toggling a block back off is instant). Everything else from
    /// a blocked author — notes, reposts, reactions, zaps, media, polls — is
    /// dropped at `persist` so it can never surface from any read path.
    private static let blockExemptKinds: Set<Int> = [0, 10002, 10012, 10030, 30030, 30000, 30002, 30003]

    /// Whether an event survives the block filter at persistence time. Pure +
    /// testable: an exempt-kind always survives; otherwise it survives only if
    /// its author (or a kind-6 repost's inner author) isn't blocked.
    static func survivesBlock(_ event: NostrEvent) -> Bool {
        if blockExemptKinds.contains(event.kind) { return true }
        return !SafetyFilter.shared.isHardBlocked(event: event)
    }

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

        let deduped = existingIds.isEmpty ? unique : unique.filter { !existingIds.contains($0.id) }
        guard !deduped.isEmpty else { return }

        // Block at the source: a blocked author's content must never reach disk,
        // no matter which read path later reseeds it (feed, thread cache, quoted
        // note, notifications). This is the single chokepoint that makes the
        // scattered render-time `shouldDrop` checks belt-and-suspenders rather
        // than load-bearing. Exempt kinds (profile / relay / emoji / lists) are
        // retained so block-list UI and name resolution still work.
        let toPut = deduped.filter { Self.survivesBlock($0) }
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

    /// Per-target reply counts from disk: how many cached kind:1 events reply to
    /// each of `targetIds`. Count-only (no `NostrEvent` materialization) because
    /// the feed card renders just a reply *number* — this lets the feed seed a
    /// last-known reply count on a cold open without the cost of walking the
    /// whole reply table into objects. Attribution mirrors the engagement-ingest
    /// rule: a reply belongs to its last non-`mention` `e`-target. A NIP-18 quote
    /// (`q`-tag pointing at a tracked note) is a quote, not a reply, so it's
    /// excluded — same as `EngagementRepository.ingest`.
    func loadReplyCounts(forTargetIds targetIds: Set<String>) -> [String: Int] {
        guard let box = ensureBox(), !targetIds.isEmpty else { return [:] }
        var counts: [String: Int] = [:]
        var seenIds = Set<String>()
        for target in targetIds {
            do {
                let query = try box.query {
                    EventEntity.kind == 1 && EventEntity.tags.contains(target)
                }.build()
                let candidates = try query.find(offset: 0, limit: 5000)
                for entity in candidates {
                    guard let event = entity.toNostrEvent(), seenIds.insert(event.id).inserted else { continue }
                    // A quote targeting a tracked note is not a reply.
                    let isQuote = event.tags.contains { $0.count >= 2 && $0[0] == "q" && targetIds.contains($0[1]) }
                    if isQuote { continue }
                    let eTargets = event.tags.compactMap { tag -> String? in
                        guard tag.count >= 2, tag[0] == "e" else { return nil }
                        if tag.count >= 4, tag[3] == "mention" { return nil }
                        return tag[1]
                    }
                    guard let primary = eTargets.last,
                          primary != event.id,
                          targetIds.contains(primary) else { continue }
                    counts[primary, default: 0] += 1
                }
            } catch {
                continue
            }
        }
        return counts
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

    /// Remove every cached event by `pubkey`, plus any kind-6 repost that wraps
    /// `pubkey`'s content. Called on block so the author's existing notes — and
    /// other people's reposts of them — disappear from feed reseeds, thread
    /// caches, and notification hydration.
    @discardableResult
    func removeByAuthor(_ pubkey: String) -> Int {
        guard let box = ensureBox() else { return 0 }
        var removed = 0
        do {
            let query = try box.query { EventEntity.pubkey == pubkey }.build()
            removed += try Int(query.remove())
        } catch {}

        // Kind-6 reposts are authored by the reposter, so the query above misses
        // them. Find reposts that mention `pubkey` (tag JSON substring is the
        // cheapest pre-filter), confirm the inner author in Swift, then delete.
        do {
            let repostQuery = try box.query {
                EventEntity.kind == 6 && EventEntity.tags.contains(pubkey)
            }.build()
            let candidates = try repostQuery.find(offset: 0, limit: 5000)
            let stale = candidates.filter { entity in
                guard let event = entity.toNostrEvent() else { return false }
                return SafetyFilter.repostInnerPubkey(event) == pubkey
            }
            if !stale.isEmpty {
                try box.remove(stale)
                removed += stale.count
            }
        } catch {}
        return removed
    }

    /// Sweep on login / mute-list sync: purge on-disk content for every author
    /// already on the block list. `persist` drops *new* blocked content and
    /// `removeByAuthor` handles *newly*-blocked authors, but neither covers
    /// content persisted before this author was blocked (or before this filter
    /// shipped). Idempotent and cheap when the block set is small.
    func removeBlockedAuthors(_ pubkeys: Set<String>) {
        guard !pubkeys.isEmpty, ensureBox() != nil else { return }
        for pubkey in pubkeys {
            _ = removeByAuthor(pubkey)
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
