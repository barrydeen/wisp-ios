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
    @ObservationIgnored private var recentlySeenPubkeys: [String: Int] = [:]
    @ObservationIgnored private var followsCache: Set<String> = []
    @ObservationIgnored private let eventStore = EventStore.shared
    @ObservationIgnored private let profileRepo = ProfileRepository.shared

    private static let onlineActivityKinds: Set<Int> = [1, 6, 7, 30023, 20, 21, 22]
    private static let onlineWindowSeconds = 10 * 60

    private static let indexerRelays = [
        "wss://indexer.nostrarchives.com",
        "wss://indexer.coracle.social",
        "wss://relay.damus.io",
        "wss://relay.primal.net"
    ]

    /// Kinds queried from a single relay or relay set, matching the Android client.
    /// 1068 = NIP-88 poll, 6969 = NIP-69 zap poll, 30023 = long-form. Polls render as
    /// `PollSection` in `PostCardView`; long-form falls through to the text path.
    static let relayFeedKinds = [1, 6, 1068, 6969, 30023, 20, 21, 22]

    /// True for events that should appear as top-level rows in the feed list.
    /// Kept consistent across cache seed, live ingest, and relay backfill paths.
    static func isFeedRenderable(_ event: NostrEvent) -> Bool {
        if event.isRootNote { return true }
        switch event.kind {
        case 6, 20, Nip88.kindPoll, Nip69.kindZapPoll: return true
        default: return false
        }
    }

    init(keypair: Keypair) {
        self.keypair = keypair
    }

    func start() async {
        guard !isLoading, events.isEmpty else { return }
        isLoading = true

        reloadFollowsCache()
        metricsTask = Task { await fetchOnlineCount() }
        startPruneTask()
        startLiveDiscovery()
        let kp = keypair
        Task { await RelaySetRepository.shared.bootstrap(keypair: kp) }

        // 1. Seed from local storage for instant display
        let cached = await eventStore.seedCache(limit: 2000)
        if !cached.isEmpty {
            for event in cached {
                markActivityIfFollowed(event)
                if Self.isFeedRenderable(event) && passesFollowsFilter(event) {
                    if seenIds.insert(event.id).inserted {
                        events.append(event)
                    }
                }
            }
            events.sort { $0.createdAt > $1.createdAt }

            // Pre-populate profiles from local cache for instant names/avatars
            let pubkeysInCache = Set(events.map(\.pubkey))
            profiles = profileRepo.getAll(Array(pubkeysInCache))

            // Show cached data immediately while relay fetch continues
            isLoading = false
        }

        // 2. Calculate since timestamp for incremental sync
        let follows = UserDefaults.standard.stringArray(forKey: "follow_pubkeys_\(keypair.pubkey)") ?? []
        let scoreBoard = RelayScoreBoard.load(pubkey: keypair.pubkey)
        let newestStored = await eventStore.newestTimestamp()
        let since = calculateSince(newestStored: newestStored, followCount: follows.count)

        // 3. Fetch user profile + new events from relays
        await loadUserProfile()
        await loadFeed(follows: follows, scoreBoard: scoreBoard, since: since)
        await loadMissingProfiles()

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
        let follows = UserDefaults.standard.stringArray(forKey: "follow_pubkeys_\(keypair.pubkey)") ?? []
        let scoreBoard = RelayScoreBoard.load(pubkey: keypair.pubkey)

        let since: Int?
        if let newest = events.first {
            since = newest.createdAt - 60
        } else {
            since = await eventStore.newestTimestamp()
        }

        await loadFeed(follows: follows, scoreBoard: scoreBoard, since: since)
        await loadMissingProfiles()

        if let newest = events.first {
            UserDefaults.standard.set(newest.createdAt, forKey: "latest_feed_ts_\(keypair.pubkey)")
        }
    }

    func stop() {
        metricsTask?.cancel()
        pruneTask?.cancel()
        pruneTask = nil
        cancelLiveSubscription()
        LiveStreamCoordinator.shared.stopDiscovery()
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
            let cached = await eventStore.seedCache(limit: 2000)
            for event in cached
                where Self.isFeedRenderable(event) && passesFollowsFilter(event) {
                if seenIds.insert(event.id).inserted { events.append(event) }
            }
            events.sort { $0.createdAt > $1.createdAt }
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
                if self.seenIds.insert(event.id).inserted {
                    // Insert in sorted (createdAt desc) position
                    let idx = self.events.firstIndex(where: { $0.createdAt < event.createdAt }) ?? self.events.count
                    self.events.insert(event, at: idx)
                    if self.relayFeedStatus != .streaming {
                        self.relayFeedStatus = .streaming
                    }
                    Task.detached { await EventStore.shared.persist([event]) }
                    Task { await self.requestProfileIfNeeded(event.pubkey) }
                }
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
                    self.events.append(event)
                    added.append(event)
                }
            }
            self.events.sort { $0.createdAt > $1.createdAt }
            if !added.isEmpty {
                Task.detached { await EventStore.shared.persist(added) }
            }
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
        let results = await RelayPool.query(
            relays: Self.indexerRelays,
            filter: NostrFilter(kinds: [0], authors: [pubkey], limit: 5),
            timeout: 6
        )
        if let best = results.filter({ $0.kind == 0 }).max(by: { $0.createdAt < $1.createdAt }),
           let updated = profileRepo.updateFromEvent(best) {
            profiles[pubkey] = updated
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

    /// Mirrors Android `RelayPool.MAX_PERSISTENT` — pool size cap.
    private static let maxPoolRelays = 30
    /// Mirrors Android `OutboxRouter.MAX_AUTHORS_PER_FILTER` — relays reject REQs with too-large filters.
    private static let maxAuthorsPerFilter = 200

    private func loadFeed(follows: [String], scoreBoard: RelayScoreBoard?, since: Int?) async {
        guard let board = scoreBoard, !follows.isEmpty else { return }

        // 1. Pool: top-N connectable scored relays. Filter drops .onion/localhost/IPs/etc.
        //    Cap matches Android's MAX_PERSISTENT — coverage past the top 30 is marginal
        //    and the indexer safety net catches anyone the pool misses.
        let pool = board.scoredRelays
            .filter { RelayUrlValidator.isConnectable($0.url) }
            .prefix(Self.maxPoolRelays)
            .map(\.url)
        let poolSet = Set(pool)

        // 2. Per-author routing: each author lands on the pool relays they write to.
        var relayToAuthors: [String: Set<String>] = [:]
        for author in follows {
            let authorWriteRelays = board.authorRelays[author] ?? []
            let eligible = authorWriteRelays.intersection(poolSet)
            for url in eligible {
                relayToAuthors[url, default: []].insert(author)
            }
        }

        // 3. Indexer safety net: each indexer relay receives the full follow list.
        //    Catches authors whose write relays all fell outside the pool.
        let allFollows = Set(follows)
        for url in Self.indexerRelays where RelayUrlValidator.isConnectable(url) {
            relayToAuthors[url] = allFollows
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

        // 5. Stream events into the feed as relays return them. Batched persist (200ms windows).
        var pendingPersist: [NostrEvent] = []
        var lastFlush = Date()
        let store = eventStore

        for await (event, _) in RelayPool.stream(queries: queries, timeout: 15) {
            markActivityIfFollowed(event)
            guard Self.isFeedRenderable(event) else { continue }
            guard seenIds.insert(event.id).inserted else { continue }

            let idx = events.firstIndex(where: { $0.createdAt < event.createdAt }) ?? events.count
            events.insert(event, at: idx)

            pendingPersist.append(event)
            if pendingPersist.count >= 50 || Date().timeIntervalSince(lastFlush) > 0.2 {
                let batch = pendingPersist
                pendingPersist.removeAll(keepingCapacity: true)
                lastFlush = Date()
                Task { await store.persist(batch) }
            }
        }

        if !pendingPersist.isEmpty {
            let batch = pendingPersist
            Task { await store.persist(batch) }
        }
    }

    private func loadMissingProfiles() async {
        var needed = Set(events.map(\.pubkey)).filter { profiles[$0] == nil }
        for event in events where event.kind == 6 {
            if let data = event.content.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let innerPubkey = json["pubkey"] as? String,
               profiles[innerPubkey] == nil {
                needed.insert(innerPubkey)
            }
        }
        guard !needed.isEmpty else { return }

        // Resolve from local cache first
        var stillMissing: [String] = []
        for pk in needed {
            if let cached = profileRepo.get(pk) {
                profiles[pk] = cached
            } else {
                stillMissing.append(pk)
            }
        }
        guard !stillMissing.isEmpty else { return }

        // Fetch remaining from relays
        for batch in stillMissing.chunked(into: 150) {
            let results = await RelayPool.query(
                relays: Self.indexerRelays,
                filter: NostrFilter(kinds: [0], authors: batch),
                timeout: 10
            )

            var bestByAuthor: [String: NostrEvent] = [:]
            for event in results where event.kind == 0 {
                if let existing = bestByAuthor[event.pubkey],
                   event.createdAt <= existing.createdAt { continue }
                bestByAuthor[event.pubkey] = event
            }

            for (_, event) in bestByAuthor {
                if let profile = profileRepo.updateFromEvent(event) {
                    profiles[event.pubkey] = profile
                }
            }
        }
    }

    // MARK: - Online presence (followed authors active in the last 10 minutes)

    private func reloadFollowsCache() {
        followsCache = Set(
            UserDefaults.standard.stringArray(forKey: "follow_pubkeys_\(keypair.pubkey)") ?? []
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

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
