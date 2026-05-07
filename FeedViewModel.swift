import Foundation
import Observation

enum FeedKind: Equatable, Hashable {
    case follows
    case relay(url: String)
    case relaySet(RelaySet)
    case extendedNetwork

    var displayName: String {
        switch self {
        case .follows:
            return "Follows"
        case .relay(let url):
            return URL(string: url)?.host ?? url
        case .relaySet(let set):
            return set.name
        case .extendedNetwork:
            return "Extended Network"
        }
    }
}

@Observable
@MainActor
final class FeedViewModel {
    let keypair: Keypair

    var events: [NostrEvent] = []
    var profiles: [String: ProfileData] = [:]
    var isLoading = false
    var connectedRelayCount = 0
    var connectedRelays: [(url: String, authorCount: Int)] = []
    var globalOnlineCount: Int?
    var onlineNetworkPubkeys: [String] = []
    var userProfile: ProfileData?
    var currentKind: FeedKind = .follows
    var relayFeedStatus: RelayFeedStatus = .idle

    @ObservationIgnored private var seenIds = Set<String>()
    @ObservationIgnored private var metricsTask: Task<Void, Never>?
    @ObservationIgnored private var liveSubscription: RelaySubscription?
    @ObservationIgnored private var liveConsumer: Task<Void, Never>?
    @ObservationIgnored private var loadMoreTask: Task<Void, Never>?
    @ObservationIgnored private var firstEventDeadline: Task<Void, Never>?
    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    @ObservationIgnored private var profileUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var sweepSourceId: UUID?
    @ObservationIgnored private var recentlySeenPubkeys: [String: Int] = [:]
    /// Buffer for events arriving from the live subscription. Drained into
    /// `events` on a debounced flush so a backfill burst produces ~one
    /// observable mutation per frame instead of one per event.
    @ObservationIgnored private var pendingInserts: [NostrEvent] = []
    @ObservationIgnored private var isFlushScheduled = false
    @ObservationIgnored private static let liveFlushDelayMs: UInt64 = 60
    @ObservationIgnored private var followsCache: Set<String> = []
    @ObservationIgnored private let eventStore = EventStore.shared
    @ObservationIgnored private let profileRepo = ProfileRepository.shared

    private static let onlineActivityKinds: Set<Int> = [1, 6, 7, 30023, 20, 21, 22]
    private static let onlineWindowSeconds = 10 * 60

    private static let indexerRelays = RelayDefaults.indexers

    /// Kinds queried from a single relay or relay set, matching the Android client.
    /// 1068 = NIP-88 poll, 6969 = NIP-69 zap poll, 30023 = long-form. Polls render as
    /// `PollSection` in `PostCardView`; long-form falls through to the text path.
    static let relayFeedKinds = [1, 6, 1068, 6969, 30023, 20, 21, 22]

    /// True for events that should appear as top-level rows in the feed list.
    /// Kept consistent across cache seed, live ingest, and relay backfill paths.
    nonisolated static func isFeedRenderable(_ event: NostrEvent) -> Bool {
        if event.isRootNote { return true }
        switch event.kind {
        case 6, 20, Nip88.kindPoll, Nip69.kindZapPoll: return true
        default: return false
        }
    }

    init(keypair: Keypair) {
        self.keypair = keypair
        observeBlocks()
    }

    /// Listen for `userBlocked` and drop matching in-memory events. Without
    /// this, blocking someone in-session leaves their already-rendered feed
    /// cards visible until the user pulls-to-refresh or relaunches.
    private func observeBlocks() {
        NotificationCenter.default.addObserver(
            forName: .userBlocked, object: nil, queue: .main
        ) { [weak self] note in
            // The observer block is `@Sendable`. Hop to MainActor to mutate
            // `events` and call the MainActor-isolated `repostInnerPubkey`.
            guard let blocked = note.object as? String else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.events.removeAll {
                    $0.pubkey == blocked
                    || ($0.repostInnerPubkey == blocked)
                }
            }
        }
    }

    func start() async {
        guard !isLoading, events.isEmpty else { return }
        isLoading = true

        reloadFollowsCache()
        metricsTask = Task { await fetchOnlineCount() }
        startPruneTask()
        startLiveDiscovery()
        subscribeToProfileUpdates()
        registerSweepSource()
        let kp = keypair
        Task { await RelaySetRepository.shared.bootstrap(keypair: kp) }

        // 1. Seed from local storage for instant display.
        //    Filter + sort run off the MainActor so the first frame isn't blocked.
        let cached = await eventStore.seedCache(limit: 300)
        if !cached.isEmpty {
            let myPubkey = keypair.pubkey
            let follows = followsCache
            let (filtered, ids) = await Task.detached(priority: .userInitiated) {
                var result: [NostrEvent] = []
                var seen: Set<String> = []
                for event in cached {
                    if SafetyFilter.shared.shouldDrop(event: event, context: .feed) { continue }
                    if FeedViewModel.isFeedRenderable(event) &&
                       (event.pubkey == myPubkey || follows.contains(event.pubkey)) {
                        if seen.insert(event.id).inserted { result.append(event) }
                    }
                }
                result.sort { $0.createdAt > $1.createdAt }
                return (result, seen)
            }.value

            for event in filtered { markActivityIfFollowed(event) }
            seenIds.formUnion(ids)
            events = Self.consolidateReposts(filtered)

            let pubkeysInCache = Set(filtered.map(\.pubkey))
            profiles = profileRepo.getAll(Array(pubkeysInCache))
            isLoading = false
        }

        // 2. Calculate since timestamp for incremental sync
        let follows = FollowsCache.shared.follows(for: keypair.pubkey)
        let scoreBoard = RelayScoreBoard.load(pubkey: keypair.pubkey)
        // Exclude our own pubkey: if the only stored kind-1 is the user's
        // freshly-published intro note, `since` would clamp to "intro_ts - 5m"
        // and hide every older note from follows on the first feed load.
        let newestStored = await eventStore.newestTimestamp(excludingPubkey: keypair.pubkey)
        let since = calculateSince(newestStored: newestStored, followCount: follows.count)

        // 3. Open relay sockets immediately, then fetch profiles concurrently.
        //    loadFeed fires tasks and returns — no need to gate it on profile fetch.
        loadFeed(follows: follows, scoreBoard: scoreBoard, since: since)
        await loadUserProfile()
        MissingProfileWatcher.shared.observe(events)

        isLoading = false

        // 4. Save latest timestamp for next session
        if let newest = events.first {
            UserDefaults.standard.set(newest.createdAt, forKey: "latest_feed_ts_\(keypair.pubkey)")
        }

        // 5. Prune old data periodically
        let pubkey = keypair.pubkey
        Task { await eventStore.prune(protectedPubkey: pubkey) }
    }

    func refresh() async {
        reloadFollowsCache()
        let follows = FollowsCache.shared.follows(for: keypair.pubkey)
        let scoreBoard = RelayScoreBoard.load(pubkey: keypair.pubkey)

        let since: Int?
        if let newest = events.first {
            since = newest.createdAt - 60
        } else {
            since = await eventStore.newestTimestamp(excludingPubkey: keypair.pubkey)
        }

        loadFeed(follows: follows, scoreBoard: scoreBoard, since: since)
        MissingProfileWatcher.shared.observe(events)

        if let newest = events.first {
            UserDefaults.standard.set(newest.createdAt, forKey: "latest_feed_ts_\(keypair.pubkey)")
        }
    }

    func stop() {
        metricsTask?.cancel()
        pruneTask?.cancel()
        pruneTask = nil
        profileUpdatesTask?.cancel()
        profileUpdatesTask = nil
        if let id = sweepSourceId {
            MissingProfileWatcher.shared.unregisterSource(id)
            sweepSourceId = nil
        }
        cancelLiveSubscription()
        LiveStreamCoordinator.shared.stopDiscovery()
    }

    /// Bridge `MissingProfileWatcher.updates` into our local `profiles` dict so
    /// rows refresh as freshly-fetched profiles land. Each VM owns its own
    /// stream subscription; cancelling the task in `stop()` removes us from
    /// the watcher's continuation list.
    private func subscribeToProfileUpdates() {
        profileUpdatesTask?.cancel()
        profileUpdatesTask = Task { @MainActor [weak self] in
            for await pk in MissingProfileWatcher.shared.updates {
                guard let self else { return }
                if let p = self.profileRepo.get(pk) { self.profiles[pk] = p }
            }
        }
    }

    /// Register `events` as a periodic-sweep source so the watcher can revisit
    /// what's currently rendered (catches ObjectBox-seeded events that landed
    /// before the watcher started, plus nostr:npub mentions resolved at render
    /// time rather than ingest).
    private func registerSweepSource() {
        if sweepSourceId != nil { return }
        sweepSourceId = MissingProfileWatcher.shared.registerSource { [weak self] in
            self?.events ?? []
        }
    }

    // MARK: - Feed kind selection

    func selectFollows() {
        guard currentKind != .follows else { return }
        cancelLiveSubscription()
        currentKind = .follows
        relayFeedStatus = .idle
        events = []
        seenIds = []
        reloadFollowsCache()
        Task {
            isLoading = true
            // Re-seed from local cache (filtered to follows — EventStore is shared with the
            // Extended Network subscription, which persists every event it sees).
            let cached = await eventStore.seedCache(limit: 300)
            let myPubkey = keypair.pubkey
            let fc = followsCache
            let (reFiltered, reIds) = await Task.detached(priority: .userInitiated) {
                var result: [NostrEvent] = []
                var seen: Set<String> = []
                for event in cached
                    where FeedViewModel.isFeedRenderable(event) &&
                          (event.pubkey == myPubkey || fc.contains(event.pubkey)) {
                    if seen.insert(event.id).inserted { result.append(event) }
                }
                result.sort { $0.createdAt > $1.createdAt }
                return (result, seen)
            }.value
            seenIds.formUnion(reIds)
            events = Self.consolidateReposts(reFiltered)
            await refresh()
            isLoading = false
        }
    }

    func selectRelay(url: String) {
        guard let normalized = Nip51Lists.normalize(url) else { return }
        cancelLiveSubscription()
        currentKind = .relay(url: normalized)
        events = []
        seenIds = []
        relayFeedStatus = .connecting
        UserDefaults.standard.set(normalized, forKey: "last_relay_url_\(keypair.pubkey)")
        startSubscription(relays: [normalized])
    }

    func selectRelaySet(_ set: RelaySet) {
        cancelLiveSubscription()
        currentKind = .relaySet(set)
        events = []
        seenIds = []
        guard !set.relays.isEmpty else {
            relayFeedStatus = .noEvents
            return
        }
        relayFeedStatus = .connecting
        UserDefaults.standard.set(set.dTag, forKey: "last_relay_set_\(keypair.pubkey)")
        startSubscription(relays: set.relays)
    }

    /// Subscribes the feed to the cached extended-network relay set produced by
    /// `SocialGraphRepository`. No author filter is applied — the relay set is itself
    /// the filter (set-cover-tuned to the qualified extended pubkeys' write relays).
    /// If no cache exists, the empty-state CTA in `MainView` invites the user to compute.
    func selectExtendedNetwork() {
        cancelLiveSubscription()
        currentKind = .extendedNetwork
        events = []
        seenIds = []
        guard let cache = SocialGraphCache.load(pubkey: keypair.pubkey),
              !cache.relayUrls.isEmpty else {
            relayFeedStatus = .noEvents
            return
        }
        relayFeedStatus = .connecting
        let relays = Array(cache.relayUrls.prefix(SocialGraphRepository.Constants.extendedFeedRelayCap))
        startSubscription(relays: relays)
    }

    private func cancelLiveSubscription() {
        liveSubscription?.cancel()
        liveSubscription = nil
        liveConsumer?.cancel()
        liveConsumer = nil
        firstEventDeadline?.cancel()
        firstEventDeadline = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil
        pendingInserts.removeAll(keepingCapacity: true)
        isFlushScheduled = false
    }

    /// Buffer a live event for the next debounced flush. SwiftUI sees one
    /// `events` mutation per ~60 ms window instead of one per arriving event,
    /// which on a populated follows feed is the difference between LazyVStack
    /// recomputing visibility ~event-rate vs. ~16 Hz.
    private func enqueueLiveEvent(_ event: NostrEvent) {
        pendingInserts.append(event)
        if !isFlushScheduled {
            isFlushScheduled = true
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.liveFlushDelayMs))
                await self?.flushPendingInserts()
            }
        }
    }

    /// Drain the live-event buffer in a single sorted-merge pass and republish
    /// `events` once. Persistence + referenced-profile fetches run as
    /// fire-and-forget tasks against the merged batch.
    private func flushPendingInserts() {
        isFlushScheduled = false
        let batch = pendingInserts
        pendingInserts.removeAll(keepingCapacity: true)
        guard !batch.isEmpty else { return }

        let sortedBatch = batch.sorted { $0.createdAt > $1.createdAt }
        events = Self.consolidateReposts(Self.mergeSortedDesc(events, sortedBatch))

        if relayFeedStatus != .streaming {
            relayFeedStatus = .streaming
        }

        Task { await EventPersistQueue.shared.enqueue(batch) }

        // Hand the batch to the watcher: it dedupes against its own pending /
        // inflight / exhausted sets, batches into one kind-0 fan-out per 150
        // pubkeys, and yields back through `updates` so our `profiles` dict
        // hydrates as profiles land. Replaces the per-VM batched fetcher.
        MissingProfileWatcher.shared.observe(batch)
    }

    /// Merge two arrays already sorted by `createdAt` desc into a single
    /// desc-sorted array. O(n+k) — replaces the per-event `firstIndex` linear
    /// search + insert that ran on every arrival.
    static func mergeSortedDesc(_ a: [NostrEvent], _ b: [NostrEvent]) -> [NostrEvent] {
        var merged: [NostrEvent] = []
        merged.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i].createdAt >= b[j].createdAt {
                merged.append(a[i]); i += 1
            } else {
                merged.append(b[j]); j += 1
            }
        }
        while i < a.count { merged.append(a[i]); i += 1 }
        while j < b.count { merged.append(b[j]); j += 1 }
        return merged
    }

    /// Drop original kind-1 notes that have a kind-6 repost in the feed,
    /// and keep only the most-recent kind-6 per inner-event-id. Reposts
    /// then appear in the feed at their own `createdAt` (when the
    /// repost happened) rather than back-to-back with the original
    /// note's older timestamp, and multiple reposts of the same note
    /// collapse into a single timeline event ordered by the latest
    /// repost. Preserves the input order for non-repost events.
    static func consolidateReposts(_ events: [NostrEvent]) -> [NostrEvent] {
        // Pass 1: per inner-event-id, find the kind-6 with the highest
        // `createdAt` and remember its event id.
        var keepRepostIdByInner: [String: String] = [:]
        var keepRepostTsByInner: [String: Int] = [:]
        for event in events where event.kind == 6 {
            guard let innerId = innerRepostId(of: event) else { continue }
            if let prevTs = keepRepostTsByInner[innerId], prevTs >= event.createdAt {
                continue
            }
            keepRepostIdByInner[innerId] = event.id
            keepRepostTsByInner[innerId] = event.createdAt
        }

        let repostedInnerIds = Set(keepRepostIdByInner.keys)
        let keptRepostIds = Set(keepRepostIdByInner.values)

        // Pass 2: drop superseded kind-6 reposts and any kind-1 originals
        // that one of the kept reposts already covers.
        return events.filter { event in
            switch event.kind {
            case 6: return keptRepostIds.contains(event.id)
            case 1: return !repostedInnerIds.contains(event.id)
            default: return true
            }
        }
    }

    /// The id of the inner kind-1 inside a kind-6 repost — the JSON
    /// payload in `content` per NIP-18, with the first `e` tag as a
    /// fallback for older clients that omit the embedded event.
    static func innerRepostId(of event: NostrEvent) -> String? {
        innerRepostRef(of: event)?.id
    }

    /// The id and original-author pubkey of the inner kind-1 inside a
    /// kind-6 repost. The pubkey is needed by callers that route by
    /// NIP-65 (engagement queries follow the *original* author's read
    /// relays, not the reposter's). Falls back to the first `e` / `p`
    /// tag pair when older clients omit the embedded event JSON.
    static func innerRepostRef(of event: NostrEvent) -> (id: String, pubkey: String?)? {
        guard event.kind == 6 else { return nil }
        if !event.content.isEmpty,
           let data = event.content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["id"] as? String, !id.isEmpty {
            return (id, json["pubkey"] as? String)
        }
        if let id = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
            let pk = event.tags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1]
            return (id, pk)
        }
        return nil
    }

    private func startSubscription(relays: [String]) {
        connectedRelayCount = relays.count
        let filter = NostrFilter(kinds: Self.relayFeedKinds, limit: 100)
        let subId = "relay-feed-\(UUID().uuidString.prefix(8).lowercased())"
        let sub = RelayPool.subscribe(relays: relays, filter: filter, id: subId)
        liveSubscription = sub

        // 15s "first event" watchdog — flips to noEvents if nothing arrives.
        firstEventDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self else { return }
            if self.events.isEmpty, self.relayFeedStatus == .connecting {
                self.relayFeedStatus = .noEvents
            }
        }

        liveConsumer = Task { [weak self] in
            for await (event, _) in sub.events {
                guard let self else { return }
                if Task.isCancelled { return }
                if SafetyFilter.shared.shouldDrop(event: event, context: .feed) { continue }
                self.markActivityIfFollowed(event)
                guard Self.relayFeedKinds.contains(event.kind) else { continue }
                guard self.seenIds.insert(event.id).inserted else { continue }
                self.enqueueLiveEvent(event)
            }
        }
    }

    /// Pagination for relay / relay-set feeds. Issues a one-shot REQ with `until` set
    /// to the oldest visible event's timestamp.
    func loadMore() {
        guard loadMoreTask == nil else { return }
        let relays: [String]
        switch currentKind {
        case .follows: return
        case .relay(let url): relays = [url]
        case .relaySet(let set): relays = set.relays
        case .extendedNetwork:
            guard let cache = SocialGraphCache.load(pubkey: keypair.pubkey) else { return }
            relays = Array(cache.relayUrls.prefix(SocialGraphRepository.Constants.extendedFeedRelayCap))
            guard !relays.isEmpty else { return }
        }
        guard let oldest = events.last?.createdAt else { return }
        let filter = NostrFilter(
            kinds: Self.relayFeedKinds,
            limit: 50,
            until: oldest - 1
        )
        loadMoreTask = Task { [weak self] in
            defer { Task { @MainActor in self?.loadMoreTask = nil } }
            let results = await RelayPool.query(relays: relays, filter: filter, timeout: 8)
            guard let self else { return }
            var added: [NostrEvent] = []
            for event in results where Self.relayFeedKinds.contains(event.kind) {
                if self.seenIds.insert(event.id).inserted {
                    added.append(event)
                }
            }
            guard !added.isEmpty else { return }
            let sortedAdded = added.sorted { $0.createdAt > $1.createdAt }
            self.events = Self.consolidateReposts(Self.mergeSortedDesc(self.events, sortedAdded))
            Task { await EventPersistQueue.shared.enqueue(added) }
        }
    }

    /// Kick off NIP-53 live activity + chat discovery. Uses the user's NIP-65 read relays
    /// when available, falling back to the top relays from the score board for new users.
    private func startLiveDiscovery() {
        let pubkey = keypair.pubkey
        Task {
            var relays = await RelayListRepository.shared.getReadRelays(pubkey)
            if relays.isEmpty,
               let board = RelayScoreBoard.load(pubkey: pubkey) {
                relays = board.scoredRelays.prefix(10).map(\.url)
            }
            LiveStreamCoordinator.shared.startDiscovery(myPubkey: pubkey, readRelays: relays)
        }
    }

    func requestProfileIfNeeded(_ pubkey: String) async {
        if profiles[pubkey] != nil { return }
        if let cached = profileRepo.get(pubkey) {
            profiles[pubkey] = cached
            return
        }
        // Route through the watcher so we share the inflight coalescing and
        // the negative-cache state. `forceFetch` bypasses the exhausted set
        // so an explicit "I want this profile" call (mention tap, etc.) still
        // tries even if a prior batched fetch came up empty.
        if let resolved = await MissingProfileWatcher.shared.forceFetch(pubkey) {
            profiles[pubkey] = resolved
        }
    }

    // MARK: - Since Calculation

    private func calculateSince(newestStored: Int?, followCount: Int) -> Int? {
        let now = Int(Date().timeIntervalSince1970)

        let defaultWindow: Int
        switch followCount {
        case ...10:  defaultWindow = 7 * 24 * 3600
        case ...30:  defaultWindow = 5 * 24 * 3600
        case ...75:  defaultWindow = 3 * 24 * 3600
        case ...150: defaultWindow = 2 * 24 * 3600
        case ...300: defaultWindow = 36 * 3600
        default:     defaultWindow = 24 * 3600
        }

        let defaultSince = now - defaultWindow

        if let stored = newestStored, stored > 0 {
            return max(stored - 5 * 60, defaultSince)
        }

        return defaultSince
    }

    // MARK: - Private

    private func loadUserProfile() async {
        let pubkey = keypair.pubkey

        // Show local profile immediately
        if let local = profileRepo.get(pubkey) {
            userProfile = local
            profiles[pubkey] = local
        }

        // Fetch from relays for freshness
        let results = await RelayPool.query(
            relays: Self.indexerRelays,
            filter: NostrFilter(kinds: [0], authors: [pubkey], limit: 5)
        )
        if let best = results.filter({ $0.kind == 0 }).max(by: { $0.createdAt < $1.createdAt }),
           let updated = profileRepo.updateFromEvent(best) {
            userProfile = updated
            profiles[pubkey] = updated
        }
    }

    /// Pool cap. Android observes ~72 connections for a similar follow base; the
    /// underlying `MAX_PERSISTENT = 30` constant is a soft floor — once you add
    /// pinned + extended-network + indexer ephemerals the live count lands here.
    private static let maxPoolRelays = 72
    /// Mirrors Android `OutboxRouter.MAX_AUTHORS_PER_FILTER` — relays reject REQs with too-large filters.
    private static let maxAuthorsPerFilter = 200

    private func loadFeed(follows: [String], scoreBoard: RelayScoreBoard?, since: Int?) {
        guard let board = scoreBoard, !follows.isEmpty else { return }

        // 1. Pool: top-N connectable scored relays. URL filter drops .onion/localhost/IPs.
        //    Scoreboard is already canonicalized, so no per-call dedup needed.
        let pool = board.scoredRelays
            .filter { RelayUrlValidator.isConnectable($0.url) }
            .prefix(Self.maxPoolRelays)
            .map(\.url)
        let poolSet = Set(pool)

        // 2. Per-author routing: each author lands on the pool relays they write to.
        var relayToAuthors: [String: Set<String>] = [:]
        var fallbackAuthors: [String] = []
        for author in follows {
            let writeRelays = board.authorRelays[author] ?? []
            let eligible = writeRelays.intersection(poolSet)
            if eligible.isEmpty {
                fallbackAuthors.append(author)
            } else {
                for url in eligible {
                    relayToAuthors[url, default: []].insert(author)
                }
            }
        }

        // 3. Distribute fallback authors round-robin across indexer relays. Each
        //    indexer ends up with ~fallback/4 authors instead of every indexer
        //    receiving the entire follow list.
        let indexers = Self.indexerRelays.compactMap { RelayUrlValidator.canonicalize($0) }
                                          .filter { RelayUrlValidator.isConnectable($0) }
        if !fallbackAuthors.isEmpty && !indexers.isEmpty {
            for (i, author) in fallbackAuthors.enumerated() {
                let url = indexers[i % indexers.count]
                relayToAuthors[url, default: []].insert(author)
            }
        }

        // 4. Build one REQ per relay (multi-filter when authors > 200) — at most one socket per host.
        let kinds = [1, 6, 20, Nip88.kindPoll, Nip69.kindZapPoll]
        var queries: [RelayQuery] = []
        for (relayUrl, authors) in relayToAuthors {
            let chunks = Array(authors).chunked(into: Self.maxAuthorsPerFilter)
            let filters = chunks.map { chunk in
                NostrFilter(kinds: kinds, authors: chunk, limit: 100, since: since)
            }
            queries.append(RelayQuery(relayUrl: relayUrl, filters: filters))
        }

        connectedRelayCount = queries.count
        connectedRelays = queries.map { q in
            (url: q.relayUrl, authorCount: relayToAuthors[q.relayUrl]?.count ?? 0)
        }

        // 5. Persistent subscription: backlog streams from the per-relay REQs (since=…)
        //    and the same sockets keep delivering live events. No re-subscribe needed
        //    after EOSE — matches Android's SharedFlow behavior.
        cancelLiveSubscription()
        let subId = "follows-feed-\(UUID().uuidString.prefix(8).lowercased())"
        let sub = RelayPool.subscribe(queries: queries, id: subId)
        liveSubscription = sub

        liveConsumer = Task { [weak self] in
            for await (event, _) in sub.events {
                guard let self else { return }
                if Task.isCancelled { return }
                self.markActivityIfFollowed(event)
                guard Self.isFeedRenderable(event) else { continue }
                guard self.seenIds.insert(event.id).inserted else { continue }
                self.enqueueLiveEvent(event)
            }
        }
    }

    // MARK: - Online presence (followed authors active in the last 10 minutes)

    private func reloadFollowsCache() {
        followsCache = Set(
            FollowsCache.shared.follows(for: keypair.pubkey)
        )
    }

    /// EventStore caches events from every feed kind (notably the Extended Network
    /// subscription persists everything it sees), so cache reseed paths must filter to
    /// follows + self before showing them under the Follows feed.
    private func passesFollowsFilter(_ event: NostrEvent) -> Bool {
        if event.pubkey == keypair.pubkey { return true }
        return followsCache.contains(event.pubkey)
    }

    private func markActivityIfFollowed(_ event: NostrEvent) {
        guard Self.onlineActivityKinds.contains(event.kind),
              followsCache.contains(event.pubkey) else { return }
        let cutoff = Int(Date().timeIntervalSince1970) - Self.onlineWindowSeconds
        guard event.createdAt >= cutoff else { return }
        let prev = recentlySeenPubkeys[event.pubkey] ?? 0
        if event.createdAt > prev {
            recentlySeenPubkeys[event.pubkey] = event.createdAt
            rebuildOnlineList()
        }
    }

    private func rebuildOnlineList() {
        let cutoff = Int(Date().timeIntervalSince1970) - Self.onlineWindowSeconds
        recentlySeenPubkeys = recentlySeenPubkeys.filter { $0.value >= cutoff }
        onlineNetworkPubkeys = recentlySeenPubkeys
            .sorted { $0.value > $1.value }
            .map(\.key)
    }

    private func startPruneTask() {
        pruneTask?.cancel()
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.rebuildOnlineList()
            }
        }
    }

    /// Refresh the relay-pill list from the latest scoreboard. Call after onboarding finishes.
    func refreshScoreBoard() {
        guard let board = RelayScoreBoard.load(pubkey: keypair.pubkey) else { return }
        let top = Array(board.scoredRelays.prefix(20))
        connectedRelays = top.map { (url: $0.url, authorCount: $0.count) }
        connectedRelayCount = top.count
    }

    private func fetchOnlineCount() async {
        guard let url = URL(string: "wss://api.nostrarchives.com/v1/ws/live-metrics") else { return }
        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: url)
        ws.resume()

        while !Task.isCancelled {
            do {
                let msg = try await ws.receive()
                if case .string(let text) = msg,
                   let data = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let count = obj["online"] as? Int {
                    self.globalOnlineCount = count
                }
            } catch {
                break
            }
        }

        ws.cancel(with: .normalClosure, reason: nil)
    }
}

nonisolated extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
