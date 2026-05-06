import Foundation
import Observation

struct CustomEmoji: Identifiable, Hashable {
    let shortcode: String
    let url: String
    var id: String { shortcode }
}

struct ResolvedEmojiPack: Hashable {
    let address: String          // "30030:<pubkey>:<d>"
    let pubkey: String
    let dTag: String
    let title: String?
    let emojis: [CustomEmoji]
}

/// Parsed user emoji list (kind 10030).
struct UserEmojiList {
    var directEmojis: [CustomEmoji]   // inline `["emoji", shortcode, url]` tags
    var packAddresses: [String]       // `["a", "30030:<pubkey>:<d>"]` tag values
    var createdAt: Int
}

/// Owns the active user's emoji UX state:
///   • The user-curated **quick reactions** list (unicode chars + `:shortcode:` keys)
///     that fronts the reaction picker, plus a **frequency map** for sort order.
///   • Parsed **kind-10030** state (inline emojis + pack references).
///   • Resolved **kind-30030** packs the user references — fetched on refresh.
///
/// Quick reactions and frequency persist to UserDefaults per-pubkey under
/// `wisp.emoji.state.<pubkey>`. Pack/kind-10030 state is rebuilt from relays on
/// each `refresh(for:)` call (cheap to repeat — first call hits the network,
/// subsequent calls return immediately for the same pubkey).
@Observable
@MainActor
final class EmojiRepository {
    static let shared = EmojiRepository()
    private init() {}

    // MARK: - Public state (observed)

    /// Backward-compat: flat list used by the composer's autocomplete.
    /// Built from `directEmojis ∪ resolvedPacks` on refresh.
    private(set) var emoji: [CustomEmoji] = []

    /// User-curated quick reactions (unicode chars or `:shortcode:` strings). Persisted.
    private(set) var quickReactions: [String] = []

    /// Per-emoji-key usage counter. Persisted.
    private(set) var frequency: [String: Int] = [:]

    /// Inline `["emoji", shortcode, url]` tags from the user's own kind-10030.
    private(set) var directEmojis: [CustomEmoji] = []

    /// `30030:<pubkey>:<d>` strings from the user's kind-10030 `a` tags.
    private(set) var referencedPackAddrs: [String] = []

    /// addr → resolved pack (title + emojis), populated by fetching each kind-30030.
    private(set) var resolvedPacks: [String: ResolvedEmojiPack] = [:]

    /// shortcode → url, union of `directEmojis` and all `resolvedPacks` entries.
    /// Direct emojis win on shortcode collisions (matches Android `resolveEmojis`).
    private(set) var resolvedCustomMap: [String: String] = [:]

    /// kind-10030 createdAt — used so we publish replacement events with a strictly newer timestamp.
    private(set) var userListCreatedAt: Int = 0

    /// Bumped each time `recomputeResolved()` rewrites `resolvedCustomMap`.
    /// Lets observers (notably `RichContentView.parseCache`) key their caches
    /// off the current emoji state — when a late pack arrives and resolves
    /// a previously-unknown shortcode, the bump invalidates stale parses
    /// without re-renders looping on equality of the dict itself.
    private(set) var generation: Int = 0

    // MARK: - Internal

    private var loadedForPubkey: String?

    private static func defaultsKey(for pubkey: String) -> String {
        "wisp.emoji.state.\(pubkey)"
    }

    private struct PersistedState: Codable {
        var quickReactions: [String]
        var frequency: [String: Int]
    }

    // MARK: - Computed

    /// The picker's display order: every quick-list entry sorted by frequency
    /// descending. Stable: ties preserve the original `quickReactions` order.
    var sortedQuickReactions: [String] {
        quickReactions
            .enumerated()
            .sorted { lhs, rhs in
                let lf = frequency[lhs.element] ?? 0
                let rf = frequency[rhs.element] ?? 0
                if lf != rf { return lf > rf }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - Lifecycle

    /// Refresh emoji state for the given pubkey. Loads persisted quick-reactions/frequency
    /// from UserDefaults, seeds in-memory state from the ObjectBox cache, then fetches
    /// kind-10030 + referenced kind-30030 events from relays in the background.
    /// Cheap to call repeatedly — subsequent calls for the same pubkey are no-ops.
    func refresh(for pubkey: String) async {
        if loadedForPubkey == pubkey { return }
        loadedForPubkey = pubkey

        loadPersisted(pubkey: pubkey)

        // Seed from ObjectBox first so the UI sees a populated `resolvedCustomMap`
        // immediately on cold start, before any relay round-trip. The network
        // refresh below is layered on top: replaceable kind-10030 events use a
        // strictly-newer createdAt check, and kind-30030 packs are upserted by
        // `(pubkey, d-tag)`, so re-ingesting cached events into the same ingest
        // path is correct and idempotent.
        let cachedSeed = await EventStore.shared.loadEmojiState(pubkey: pubkey)
        ingestUserList(cachedSeed.userList)
        for ev in cachedSeed.ownPacks {
            ingestEmojiSet(ev)
        }
        if !referencedPackAddrs.isEmpty {
            let cachedReferenced = await EventStore.shared.loadEmojiPacksByAddress(referencedPackAddrs)
            for ev in cachedReferenced {
                ingestEmojiSet(ev)
            }
        }
        recomputeResolved()

        let writeRelays: [String]
        if let board = RelayScoreBoard.load(pubkey: pubkey) {
            writeRelays = board.scoredRelays.prefix(8).map { $0.url }
        } else {
            writeRelays = ["wss://relay.damus.io", "wss://relay.primal.net"]
        }
        guard !writeRelays.isEmpty else { return }

        // Pull the user's kind-10030 (one event, replaceable) and any kind-30030 events
        // they have authored themselves. External packs (`a`-tag refs) are fetched in a
        // second pass below once we know which addresses to ask about.
        let ownEvents = await RelayPool.query(
            relays: writeRelays,
            filter: NostrFilter(kinds: [10030, 30030], authors: [pubkey], limit: 50),
            timeout: 6
        )
        ingestUserList(ownEvents.first { $0.kind == 10030 })
        for ev in ownEvents where ev.kind == 30030 {
            ingestEmojiSet(ev)
        }
        if !ownEvents.isEmpty {
            await EventStore.shared.persist(ownEvents)
        }

        await fetchReferencedPacks()
        recomputeResolved()
    }

    /// Re-run the full refresh (network round-trip). Use after publishing a new kind-10030
    /// so observers see the updated state.
    func forceRefresh(for pubkey: String) async {
        loadedForPubkey = nil
        await refresh(for: pubkey)
    }

    /// Drop in-memory state on logout. Persisted UserDefaults stay so the next login restores them.
    func clear() {
        emoji = []
        quickReactions = []
        frequency = [:]
        directEmojis = []
        referencedPackAddrs = []
        resolvedPacks = [:]
        resolvedCustomMap = [:]
        userListCreatedAt = 0
        loadedForPubkey = nil
    }

    // MARK: - Quick-reactions mutators

    func addToQuickList(_ key: String) {
        guard !key.isEmpty, !quickReactions.contains(key) else { return }
        quickReactions.append(key)
        persist()
    }

    func removeFromQuickList(_ key: String) {
        let before = quickReactions.count
        quickReactions.removeAll { $0 == key }
        if quickReactions.count != before { persist() }
    }

    func setQuickList(_ keys: [String]) {
        quickReactions = keys
        persist()
    }

    /// Bump the usage counter for an emoji key (unicode char or `:shortcode:`). Persisted.
    func recordUse(_ key: String) {
        frequency[key, default: 0] += 1
        persist()
    }

    // MARK: - Direct-emoji mutators (publish kind 10030)

    func addDirectEmoji(shortcode: String, url: String, keypair: Keypair) async throws {
        let trimmed = shortcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !url.isEmpty else { return }
        if directEmojis.contains(where: { $0.shortcode == trimmed }) { return }
        var next = directEmojis
        next.append(CustomEmoji(shortcode: trimmed, url: url))
        try await publishKind10030(directEmojis: next, packAddrs: referencedPackAddrs, keypair: keypair)
    }

    func removeDirectEmoji(shortcode: String, keypair: Keypair) async throws {
        let next = directEmojis.filter { $0.shortcode != shortcode }
        guard next.count != directEmojis.count else { return }
        try await publishKind10030(directEmojis: next, packAddrs: referencedPackAddrs, keypair: keypair)
    }

    func addPackReference(_ addr: String, keypair: Keypair) async throws {
        guard isValidPackAddress(addr) else { return }
        if referencedPackAddrs.contains(addr) { return }
        let next = referencedPackAddrs + [addr]
        try await publishKind10030(directEmojis: directEmojis, packAddrs: next, keypair: keypair)
    }

    func removePackReference(_ addr: String, keypair: Keypair) async throws {
        let next = referencedPackAddrs.filter { $0 != addr }
        guard next.count != referencedPackAddrs.count else { return }
        try await publishKind10030(directEmojis: directEmojis, packAddrs: next, keypair: keypair)
    }

    // MARK: - Composer search (existing API — unchanged)

    func search(query: String, limit: Int = 8) -> [CustomEmoji] {
        let q = query.lowercased()
        if q.isEmpty {
            return Array(emoji.prefix(limit))
        }
        return emoji
            .filter { $0.shortcode.lowercased().hasPrefix(q) }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Parsing helpers

    private func ingestUserList(_ event: NostrEvent?) {
        guard let event else {
            directEmojis = []
            referencedPackAddrs = []
            userListCreatedAt = 0
            return
        }
        guard event.kind == 10030 else { return }
        if event.createdAt <= userListCreatedAt { return }

        var direct: [CustomEmoji] = []
        var refs: [String] = []
        var seen = Set<String>()
        for tag in event.tags {
            if tag.count >= 3, tag[0] == "emoji" {
                let sc = tag[1]
                let url = tag[2]
                guard !sc.isEmpty, !url.isEmpty, seen.insert(sc).inserted else { continue }
                direct.append(CustomEmoji(shortcode: sc, url: url))
            } else if tag.count >= 2, tag[0] == "a" {
                let value = tag[1]
                if isValidPackAddress(value), !refs.contains(value) {
                    refs.append(value)
                }
            }
        }
        directEmojis = direct
        referencedPackAddrs = refs
        userListCreatedAt = event.createdAt
    }

    private func ingestEmojiSet(_ event: NostrEvent) {
        guard event.kind == 30030 else { return }
        guard let dTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1] else { return }
        let title = event.tags.first(where: { $0.count >= 2 && $0[0] == "title" })?[1]
        var emojis: [CustomEmoji] = []
        var seen = Set<String>()
        for tag in event.tags where tag.count >= 3 && tag[0] == "emoji" {
            let sc = tag[1]
            let url = tag[2]
            guard !sc.isEmpty, !url.isEmpty, seen.insert(sc).inserted else { continue }
            emojis.append(CustomEmoji(shortcode: sc, url: url))
        }
        let addr = "30030:\(event.pubkey):\(dTag)"
        resolvedPacks[addr] = ResolvedEmojiPack(
            address: addr,
            pubkey: event.pubkey,
            dTag: dTag,
            title: title,
            emojis: emojis
        )
    }

    private func fetchReferencedPacks() async {
        // Group `a`-tag references by pack-author pubkey, then fetch their kind-30030 set
        // from the author's write relays (falling back to the user's read relays / a small
        // built-in indexer set if the author has no published relay list).
        struct PendingRef { let addr: String; let pubkey: String; let dTag: String }
        var byAuthor: [String: [PendingRef]] = [:]
        for addr in referencedPackAddrs {
            guard let parsed = parsePackAddress(addr), parsed.kind == 30030 else { continue }
            if resolvedPacks[addr] != nil { continue }
            byAuthor[parsed.pubkey, default: []].append(
                PendingRef(addr: addr, pubkey: parsed.pubkey, dTag: parsed.dTag)
            )
        }
        guard !byAuthor.isEmpty else { return }

        var fetched: [NostrEvent] = []
        await withTaskGroup(of: [NostrEvent].self) { group in
            for (author, refs) in byAuthor {
                group.addTask { [author, refs] in
                    let authorWrites = await RelayListRepository.shared.getWriteRelays(author)
                    let relays = authorWrites.isEmpty
                        ? ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
                        : Array(authorWrites.prefix(5))
                    return await RelayPool.query(
                        relays: relays,
                        filter: NostrFilter(
                            kinds: [30030],
                            authors: [author],
                            dTags: refs.map(\.dTag),
                            limit: refs.count
                        ),
                        timeout: 6
                    )
                }
            }
            for await events in group {
                for ev in events { ingestEmojiSet(ev) }
                fetched.append(contentsOf: events)
            }
        }
        if !fetched.isEmpty {
            await EventStore.shared.persist(fetched)
        }
    }

    private func recomputeResolved() {
        var map: [String: String] = [:]
        for ce in directEmojis {
            map[ce.shortcode] = ce.url
        }
        for addr in referencedPackAddrs {
            guard let pack = resolvedPacks[addr] else { continue }
            for ce in pack.emojis where map[ce.shortcode] == nil {
                map[ce.shortcode] = ce.url
            }
        }
        let changed = map != resolvedCustomMap
        resolvedCustomMap = map

        // Backward-compat flat list for composer autocomplete.
        var flat: [CustomEmoji] = []
        var seen = Set<String>()
        for ce in directEmojis where seen.insert(ce.shortcode).inserted {
            flat.append(ce)
        }
        for addr in referencedPackAddrs {
            guard let pack = resolvedPacks[addr] else { continue }
            for ce in pack.emojis where seen.insert(ce.shortcode).inserted {
                flat.append(ce)
            }
        }
        emoji = flat

        // Bump only on actual change so observers don't re-key their caches
        // for no-op refreshes (cache seed → relay refresh that returns the
        // same packs).
        if changed {
            generation &+= 1
        }
    }

    // MARK: - Persistence (UserDefaults)

    private func loadPersisted(pubkey: String) {
        let key = Self.defaultsKey(for: pubkey)
        if let data = UserDefaults.standard.data(forKey: key),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            quickReactions = state.quickReactions
            frequency = state.frequency
        } else {
            quickReactions = EmojiData.defaultQuickReactions
            frequency = [:]
            // Write defaults so future loads are stable.
            persist()
        }
    }

    private func persist() {
        guard let pubkey = loadedForPubkey else { return }
        let state = PersistedState(quickReactions: quickReactions, frequency: frequency)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey(for: pubkey))
        }
    }

    // MARK: - Pack address parsing

    func isValidPackAddress(_ addr: String) -> Bool {
        guard let parsed = parsePackAddress(addr) else { return false }
        return parsed.kind == 30030 && !parsed.pubkey.isEmpty && !parsed.dTag.isEmpty
    }

    /// Parse `kind:pubkey:d` into its three components. Returns nil if malformed.
    func parsePackAddress(_ addr: String) -> (kind: Int, pubkey: String, dTag: String)? {
        let parts = addr.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let kind = Int(parts[0]) else { return nil }
        let pubkey = parts[1]
        let dTag = parts[2]
        guard pubkey.count == 64, !dTag.isEmpty else { return nil }
        return (kind, pubkey, dTag)
    }

    // MARK: - Publish kind 10030

    enum PublishError: Error {
        case missingKey
        case noRelays
        case publishFailed
    }

    private func publishKind10030(directEmojis: [CustomEmoji], packAddrs: [String], keypair: Keypair) async throws {
        guard let privkey32 = Hex.decode(keypair.privkey) else {
            throw PublishError.missingKey
        }
        let createdAt = max(Int(Date().timeIntervalSince1970), userListCreatedAt + 1)
        var tags: [[String]] = []
        for ce in directEmojis {
            tags.append(["emoji", ce.shortcode, ce.url])
        }
        for addr in packAddrs {
            tags.append(["a", addr])
        }

        let event = try NostrEvent.sign(
            privkey32: privkey32,
            pubkey: keypair.pubkey,
            kind: 10030,
            createdAt: createdAt,
            tags: tags,
            content: ""
        )

        let relays = topWriteRelays(for: keypair.pubkey)
        guard !relays.isEmpty else { throw PublishError.noRelays }

        let succeeded = await RelayPool.publish(event: event, to: relays, timeout: 8)
        guard !succeeded.isEmpty else { throw PublishError.publishFailed }

        // Apply optimistically — these are the values we just signed.
        self.directEmojis = directEmojis
        self.referencedPackAddrs = packAddrs
        self.userListCreatedAt = createdAt
        // Persist our own kind-10030 so the next cold launch sees the update
        // even if the relay round-trip never returns it (e.g. user goes
        // offline immediately after toggling a pack).
        await EventStore.shared.persist([event])
        await fetchReferencedPacks()
        recomputeResolved()
    }

    private func topWriteRelays(for pubkey: String) -> [String] {
        if let board = RelayScoreBoard.load(pubkey: pubkey) {
            let top = board.scoredRelays.prefix(5).map { $0.url }
            if !top.isEmpty { return Array(top) }
        }
        return ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
    }
}
