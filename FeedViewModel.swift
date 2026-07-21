import Foundation
import Observation
import os
import SwiftUI

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

/// Client-side content filter applied on top of the feed's `events`.
/// Cycles through ALL → notes → gallery → polls and back; mirrors Wisp
/// Android's `FeedContentFilter` (see commit a6a4a4a). The toggle
/// button in the feed top bar advances through these and the
/// rendered feed reads `filteredEvents` instead of `events` directly.
nonisolated enum FeedContentFilter: String, CaseIterable {
    /// No filter — every kind the feed surfaces is shown.
    case all
    /// Plain text notes, reposts, and long-form articles.
    case notes
    /// NIP-68 / NIP-71 gallery posts.
    case gallery
    /// NIP-88 polls.
    case polls

    /// SF Symbol shown on the toggle button when this filter is active.
    /// Default `.all` uses a neutral grid; the others use a glyph that
    /// hints at the content type they isolate.
    var iconName: String {
        switch self {
        case .all:     return "rectangle.grid.2x2"
        case .notes:   return "doc.text"
        case .gallery: return "photo"
        case .polls:   return "checklist"
        }
    }

    /// The next filter in the cycle. `polls` wraps back to `all`.
    var next: FeedContentFilter {
        switch self {
        case .all:     return .notes
        case .notes:   return .gallery
        case .gallery: return .polls
        case .polls:   return .all
        }
    }

    /// Empty-state copy shown when this filter yields zero events.
    var emptyStateCaption: String {
        switch self {
        case .all:     return "No posts in your feed yet"
        case .notes:   return "No notes in your feed yet"
        case .gallery: return "No gallery posts in your feed yet"
        case .polls:   return "No polls in your feed yet"
        }
    }

    /// True when an event of `kind` passes this filter. Matches Android's
    /// kind-set mapping: notes = kind-1 / repost / long-form;
    /// gallery = picture / video / audio (20 / 21 / 22);
    /// polls = NIP-88 poll. `all` accepts everything.
    func accepts(kind: Int) -> Bool {
        switch self {
        case .all:
            return true
        case .notes:
            return kind == 1 || kind == 6 || kind == 30023
        case .gallery:
            return kind == 20 || kind == 21 || kind == 22
        case .polls:
            return kind == Nip88.kindPoll
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
    /// Client-side content filter — see `FeedContentFilter`. Defaults to
    /// `.all` so the feed behaves identically to before until the user
    /// engages the toggle. Filtering happens in `filteredEvents`; the
    /// underlying `events` array still holds every ingested item so a
    /// switch back to `.all` (or to a different filter) is instant.
    var contentFilter: FeedContentFilter = .all

    /// View-facing list — `events` passed through the active
    /// `contentFilter`. Computed each access; cheap because `events` is
    /// windowed to `feedWindowCap` and the filter is a single kind
    /// comparison per event.
    var filteredEvents: [NostrEvent] {
        guard contentFilter != .all else { return events }
        return events.filter { contentFilter.accepts(kind: $0.kind) }
    }

    /// Advance to the next filter in the cycle. Called from the toggle
    /// button in the feed top bar.
    func cycleContentFilter() {
        contentFilter = contentFilter.next
    }
    var relayFeedStatus: RelayFeedStatus = .idle
    /// Live events buffered while the user is scrolled away from the top.
    /// Drives the "N new posts" pill — counted live so the pill grows as
    /// new events arrive. Stays at zero while the feed is parked at top
    /// (events flush straight into `events` so the user always sees them).
    private(set) var pendingNewCount: Int = 0

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
    /// Hard ceiling on the in-memory feed array. The feed is timestamp-desc,
    /// so the tail is the oldest; trimming it keeps the merge / consolidate /
    /// SwiftUI-diff cost flat with scroll depth instead of climbing for the
    /// whole session — the dominant cause of "smooth at first, janky after a
    /// deep scroll". Trimmed events stay in `EventStore` and are paged back in
    /// by `loadOlder()` when the user scrolls toward the bottom. 800 ≈ a deep
    /// viewport plus a generous buffer.
    @ObservationIgnored static let feedWindowCap = 800
    /// `createdAt` of the oldest event we've loaded this session, across seed /
    /// live / `loadMore` / disk-replay. Monotonic non-increasing. Relay-feed
    /// pagination and disk-replay use this — NOT `events.last`, which the
    /// window trim can move forward — as their cursor, so a post-trim page
    /// fetch can't re-request an already-seen window and silently stall.
    @ObservationIgnored private var oldestLoadedTimestamp: Int?
    /// Set once a Follows disk-replay query returns nothing older — we've shown
    /// everything persisted, so further scroll-to-bottom shouldn't keep
    /// hammering ObjectBox. Reset on refresh / feed switch.
    @ObservationIgnored private var followsDiskExhausted = false
    /// Profile resolutions buffered from `MissingProfileWatcher.updates` and
    /// flushed in one `profiles` reassignment per ~50 ms window, so a backfill
    /// burst re-diffs the feed once per frame instead of once per resolved
    /// profile.
    @ObservationIgnored private var pendingProfileUpdates: [String: ProfileData] = [:]
    @ObservationIgnored private var profileFlushScheduled = false
    /// When true, debounced flushes promote the buffer to `pendingNewCount`
    /// instead of merging into `events`, so the user's scroll position
    /// doesn't shift under them. Tapping the new-posts pill (or scrolling
    /// back to the top) clears the hold and applies the buffer in one merge.
    @ObservationIgnored private var holdNewPosts: Bool = false
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
    /// `includeReplies` admits kind-1 replies (the "Include replies in feeds"
    /// setting); when false only root kind-1s pass, the original behaviour.
    nonisolated static func isFeedRenderable(_ event: NostrEvent, includeReplies: Bool) -> Bool {
        if event.isRootNote { return true }
        if includeReplies && event.kind == 1 { return true }
        switch event.kind {
        case 6, 20, Nip88.kindPoll, Nip69.kindZapPoll: return true
        default: return false
        }
    }

    init(keypair: Keypair) {
        self.keypair = keypair
        observeBlocks()
        observeOwnPublishes()
    }

    /// Listen for `.nostrEventPublished` and insert the user's own renderable
    /// events into the in-memory feed immediately. The follows-feed live REQ
    /// filters by `authors ∈ follows`, so own events (notably polls — kind 1068
    /// / 6969) wouldn't otherwise round-trip back through the subscription.
    private func observeOwnPublishes() {
        NotificationCenter.default.addObserver(
            forName: .nostrEventPublished, object: nil, queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?["event"] as? NostrEvent else { return }
            // Synchronous main-actor call instead of `Task { @MainActor in }`
            // so this observer and `PendingPostStore`'s observer run in the
            // same runloop tick — SwiftUI batches both writes (events insert
            // + pending clear) into a single render pass. Without this, the
            // dimmed pending row could sit visible under the real card for a
            // beat before the deferred clear committed.
            MainActor.assumeIsolated {
                guard let self else { return }
                guard event.pubkey == self.keypair.pubkey else { return }
                guard self.currentKind == .follows else { return }
                guard Self.isFeedRenderable(event, includeReplies: AppSettings.shared.includeRepliesInFeed) else { return }
                guard self.seenIds.insert(event.id).inserted else { return }
                // Clear the optimistic placeholder atomically with the real
                // insert. PendingPostStore's own observer is also listening;
                // this just guarantees the swap regardless of observer order.
                PendingPostStore.shared.clearIfMatches(realEvent: event)
                self.events = self.windowTrimmed(Self.consolidateReposts(
                    Self.mergeSortedDesc(self.events, [event])
                ))
            }
        }
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

        // Snapshot installs (WoT toggle / graph recompute) re-filter the
        // in-memory window the same way — events ingested while WoT was off
        // (or under a larger network) would otherwise stay rendered until a
        // refresh. `isWotQualified` is a no-op-cheap true when WoT is off, so
        // the mute-edit installs that also land here cost one early-exit scan.
        NotificationCenter.default.addObserver(
            forName: .safetyFilterChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard SafetyFilter.shared.snapshot.wotEnabled else { return }
                self.events.removeAll {
                    !SafetyFilter.shared.isWotQualified($0.pubkey)
                    || ($0.repostInnerPubkey.map { !SafetyFilter.shared.isWotQualified($0) } ?? false)
                }
            }
        }

        // "Include replies in feeds" flips mid-session. Only the Follows feed
        // strips replies — relay / relay-set / extended-network feeds show them
        // unconditionally, so those must not be touched here.
        NotificationCenter.default.addObserver(
            forName: .feedRepliesSettingChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentKind == .follows else { return }
                if AppSettings.shared.includeRepliesInFeed {
                    // OFF→ON: replies are already on disk but absent from the
                    // in-memory window (and gated out of `seenIds` history) —
                    // full reseed, then `refresh()` restarts the live REQ.
                    self.reseedFollowsFeed()
                } else {
                    // ON→OFF: strip in place, including buffered live inserts
                    // so a pending flush can't reinsert a reply after the strip.
                    self.events.removeAll { !Self.isFeedRenderable($0, includeReplies: false) }
                    self.pendingInserts.removeAll { !Self.isFeedRenderable($0, includeReplies: false) }
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
        //    Private rumors (gift-wrapped kind-1 from PrivateInteractionStore) are
        //    excluded so they never surface in the public feed even though they
        //    live in the same EventStore as public kind-1s.
        let cached = await eventStore.seedCache(
            limit: 300,
            excludingEventIds: PrivateInteractionStore.shared.privateEventIds
        )
        if !cached.isEmpty {
            let myPubkey = keypair.pubkey
            let follows = followsCache
            let includeReplies = AppSettings.shared.includeRepliesInFeed
            let (filtered, ids) = await Task.detached(priority: .userInitiated) {
                var result: [NostrEvent] = []
                var seen: Set<String> = []
                for event in cached {
                    if SafetyFilter.shared.shouldDrop(event: event, context: .feed) { continue }
                    if FeedViewModel.isFeedRenderable(event, includeReplies: includeReplies) &&
                       (event.pubkey == myPubkey || follows.contains(event.pubkey)) {
                        if seen.insert(event.id).inserted { result.append(event) }
                    }
                }
                result.sort { $0.createdAt > $1.createdAt }
                return (result, seen)
            }.value

            for event in filtered { markActivityIfFollowed(event) }
            seenIds.formUnion(ids)
            updateOldestLoaded(filtered.last?.createdAt)
            events = windowTrimmed(Self.consolidateReposts(filtered))

            hydrateProfiles(for: events)
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
        // Pull-to-refresh is the completeness safety valve: re-pull engagement
        // without a `since` floor so a reaction that landed on a relay outside
        // the warm cursor's window (e.g. one made on another device) is found.
        EngagementRepository.shared.requestFullResync()
        // Newly-persisted older events (e.g. from the Extended Network
        // subscription, which shares EventStore) may now sit below the
        // viewport, so let disk-replay try again after a pull-to-refresh.
        followsDiskExhausted = false
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
                if let p = self.profileRepo.get(pk) {
                    self.pendingProfileUpdates[pk] = p
                    self.scheduleProfileFlush()
                }
            }
        }
    }

    /// Coalesce buffered profile resolutions into a single `profiles` mutation
    /// per ~50 ms window — one observable write (one feed re-diff) instead of
    /// one per resolved profile during a backfill burst.
    private func scheduleProfileFlush() {
        guard !profileFlushScheduled else { return }
        profileFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            self?.flushProfileUpdates()
        }
    }

    private func flushProfileUpdates() {
        profileFlushScheduled = false
        guard !pendingProfileUpdates.isEmpty else { return }
        let batch = pendingProfileUpdates
        pendingProfileUpdates.removeAll(keepingCapacity: true)
        var merged = profiles
        for (pk, p) in batch { merged[pk] = p }
        profiles = merged
    }

    /// Eagerly populate `self.profiles` from any code path that publishes events
    /// to the UI. Pulls cached profiles synchronously (in-memory + UserDefaults
    /// via `ProfileRepository.get`) and fires an immediate indexer fetch for
    /// the rest. Bypasses MissingProfileWatcher so visible feed rows don't wait
    /// on the watcher's debounce or get silenced by its exhausted set.
    private func hydrateProfiles(for events: [NostrEvent]) {
        // Collect synchronously-cached profiles into one reassignment instead
        // of mutating `profiles` per key (each write is its own feed re-diff).
        var merged = profiles
        var missing: Set<String> = []
        for event in events {
            for pk in event.referencedAuthorPubkeys {
                if merged[pk] != nil { continue }
                if let cached = profileRepo.get(pk) {
                    merged[pk] = cached
                } else {
                    missing.insert(pk)
                }
            }
        }
        if merged.count != profiles.count { profiles = merged }
        guard !missing.isEmpty else { return }
        let pks = Array(missing)
        Task { @MainActor [weak self] in
            let dict = await ProfileRepository.shared.ensure(pks)
            guard let self, !dict.isEmpty else { return }
            var merged = self.profiles
            for (pk, profile) in dict { merged[pk] = profile }
            self.profiles = merged
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
        currentKind = .follows
        reseedFollowsFeed()
    }

    /// Reset the Follows feed and rebuild it from the local cache, then
    /// `refresh()` to restart the live subscription. Shared by `selectFollows()`
    /// and the "include replies" toggle handler (which must reseed while
    /// `currentKind` is already `.follows`).
    private func reseedFollowsFeed() {
        cancelLiveSubscription()
        relayFeedStatus = .idle
        events = []
        seenIds = []
        oldestLoadedTimestamp = nil
        followsDiskExhausted = false
        reloadFollowsCache()
        Task {
            isLoading = true
            // Re-seed from local cache (filtered to follows — EventStore is shared with the
            // Extended Network subscription, which persists every event it sees).
            let cached = await eventStore.seedCache(
                limit: 300,
                excludingEventIds: PrivateInteractionStore.shared.privateEventIds
            )
            let myPubkey = keypair.pubkey
            let fc = followsCache
            let includeReplies = AppSettings.shared.includeRepliesInFeed
            let (reFiltered, reIds) = await Task.detached(priority: .userInitiated) {
                var result: [NostrEvent] = []
                var seen: Set<String> = []
                for event in cached {
                    if SafetyFilter.shared.shouldDrop(event: event, context: .feed) { continue }
                    guard FeedViewModel.isFeedRenderable(event, includeReplies: includeReplies),
                          event.pubkey == myPubkey || fc.contains(event.pubkey) else { continue }
                    if seen.insert(event.id).inserted { result.append(event) }
                }
                result.sort { $0.createdAt > $1.createdAt }
                return (result, seen)
            }.value
            seenIds.formUnion(reIds)
            updateOldestLoaded(reFiltered.last?.createdAt)
            events = windowTrimmed(Self.consolidateReposts(reFiltered))
            hydrateProfiles(for: events)
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
        oldestLoadedTimestamp = nil
        followsDiskExhausted = false
        relayFeedStatus = .connecting
        UserDefaults.standard.set(normalized, forKey: "last_relay_url_\(keypair.pubkey)")
        startSubscription(relays: [normalized])
    }

    func selectRelaySet(_ set: RelaySet) {
        cancelLiveSubscription()
        currentKind = .relaySet(set)
        events = []
        seenIds = []
        oldestLoadedTimestamp = nil
        followsDiskExhausted = false
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
        oldestLoadedTimestamp = nil
        followsDiskExhausted = false
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
    ///
    /// When `holdNewPosts` is set, the buffer is left intact and only the
    /// observable `pendingNewCount` is updated — the new-posts pill in the
    /// view layer reads this to decide whether to show. Persistence + profile
    /// hydration still run against the held batch so the events are warm in
    /// the cache and their authors resolve before the user opts to apply.
    private func flushPendingInserts() {
        isFlushScheduled = false
        guard !pendingInserts.isEmpty else { return }

        if holdNewPosts {
            pendingNewCount = pendingInserts.count
            // Side-effects we still want even while the buffer is held:
            // persisting the events and resolving any unknown profiles so
            // that when the user finally taps the pill, the merge into
            // `events` is fully populated.
            Task { await EventPersistQueue.shared.enqueue(pendingInserts) }
            MissingProfileWatcher.shared.observe(pendingInserts)
            if relayFeedStatus != .streaming { relayFeedStatus = .streaming }
            return
        }

        let batch = pendingInserts
        pendingInserts.removeAll(keepingCapacity: true)

        let sortedBatch = batch.sorted { $0.createdAt > $1.createdAt }
        updateOldestLoaded(sortedBatch.last?.createdAt)
        // Non-animating transaction so ambient animation modifiers in the
        // parent shell (audio player, new-posts-pill) can't catch the merge
        // and animate row repositioning when out-of-order events land mid-list.
        withTransaction(Transaction(animation: nil)) {
            events = windowTrimmed(Self.consolidateReposts(Self.mergeSortedDesc(events, sortedBatch)))
        }
        // R1 instrumentation: the in-memory feed size at flush time. Should
        // plateau at the window cap once Phase 1.1 lands instead of climbing
        // with every live event for the whole session.
        Signposts.feed.emitEvent("liveFlush", "events: \(self.events.count) batch: \(sortedBatch.count)")
        hydrateProfiles(for: batch)
        pendingNewCount = 0

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

    /// Toggle the hold-new-posts flag from the view layer. Set true while
    /// the user is scrolled away from the top so live events accumulate in
    /// the pill instead of shoving the visible rows downward; set false
    /// once the user is back at the top, which immediately drains anything
    /// the buffer accumulated.
    func setHoldNewPosts(_ hold: Bool) {
        guard hold != holdNewPosts else { return }
        holdNewPosts = hold
        if !hold {
            // Apply anything that accumulated while held. Re-uses the same
            // flush pathway so persistence / profile hydration paths stay
            // identical between the held-then-applied and at-top-merge
            // cases.
            flushPendingInserts()
        }
    }

    /// Apply the held buffer immediately. Called when the user taps the
    /// "N new posts" pill — pairs with a view-side scroll-to-top so the
    /// freshly merged rows land in view. Returning the count lets the
    /// caller decide whether to play the scroll animation.
    @discardableResult
    func applyPendingNewPosts() -> Int {
        let count = pendingInserts.count
        guard count > 0 else { return 0 }
        holdNewPosts = false
        flushPendingInserts()
        return count
    }

    /// Drain the held buffer without scrolling. The new posts merge silently
    /// into `events` — they'll be there next time the user scrolls up — and
    /// the pill goes away. Used for the pill's dismiss button.
    func dismissPendingNewPosts() {
        guard !pendingInserts.isEmpty else {
            pendingNewCount = 0
            return
        }
        let wasHolding = holdNewPosts
        holdNewPosts = false
        flushPendingInserts()
        // Restore the hold so any *future* live events stay buffered
        // (the user is presumably still scrolled away). The view will
        // clear the hold when they reach the top.
        holdNewPosts = wasHolding
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
        // R1 instrumentation: this runs on every flush over the whole array,
        // so its cost is the direct read-out of feed depth. The interval flat-
        // lining after the windowing cap (Phase 1.1) is the success signal.
        let signpostState = Signposts.feed.beginInterval("consolidateReposts")
        defer { Signposts.feed.endInterval("consolidateReposts", signpostState) }
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
    private final class RepostRefBox {
        let ref: (id: String, pubkey: String?)?
        init(_ ref: (id: String, pubkey: String?)?) { self.ref = ref }
    }
    /// Cache of parsed NIP-18 repost refs keyed by the kind-6 event id (its
    /// content is immutable per id). `consolidateReposts` runs over the whole
    /// window on every ~60 ms live flush; without this each kind-6's embedded
    /// JSON was re-decoded ~16×/sec. Bounded; old keys evict naturally.
    private static let repostRefCache: NSCache<NSString, RepostRefBox> = {
        let cache = NSCache<NSString, RepostRefBox>()
        cache.countLimit = 2_000
        return cache
    }()

    static func innerRepostRef(of event: NostrEvent) -> (id: String, pubkey: String?)? {
        guard event.kind == 6 else { return nil }
        let key = event.id as NSString
        if let box = repostRefCache.object(forKey: key) { return box.ref }
        let parsed: (id: String, pubkey: String?)?
        if !event.content.isEmpty,
           let data = event.content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["id"] as? String, !id.isEmpty {
            parsed = (id, json["pubkey"] as? String)
        } else if let id = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
            let pk = event.tags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1]
            parsed = (id, pk)
        } else {
            parsed = nil
        }
        repostRefCache.setObject(RepostRefBox(parsed), forKey: key)
        return parsed
    }

    private func startSubscription(relays: [String]) {
        connectedRelayCount = relays.count
        let filter = NostrFilter(kinds: Self.relayFeedKinds, limit: 100)
        let subId = "relay-feed-\(UUID().uuidString.prefix(8).lowercased())"
        // The active relay feed is the user's one explicit choice — bypass the
        // pool's connection cap so it connects 100% of the time even when the
        // always-on subs (follows/DM/notifications) have the pool at capacity.
        let sub = RelayPool.subscribe(relays: relays, filter: filter, id: subId,
                                      bypassConnectionCap: true)
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

    /// Trim a freshly-merged feed array to the window cap, keeping the newest.
    /// Only called from the top-growth paths (live flush, seed, own-publish),
    /// which run with the user parked at the top (`holdNewPosts == false`), so
    /// the trimmed tail is far below the viewport and its removal is invisible.
    /// `loadMore` / `loadOlder` grow the tail on purpose and must NOT trim here.
    private func windowTrimmed(_ merged: [NostrEvent]) -> [NostrEvent] {
        guard merged.count > Self.feedWindowCap else { return merged }
        return Array(merged.prefix(Self.feedWindowCap))
    }

    /// Lower the oldest-loaded watermark if `ts` is older. Fed the oldest event
    /// of every batch *before* windowing so the page cursor survives a trim.
    private func updateOldestLoaded(_ ts: Int?) {
        guard let ts else { return }
        oldestLoadedTimestamp = min(oldestLoadedTimestamp ?? ts, ts)
    }

    /// Scroll-to-bottom hook from the feed view. Extends the timeline downward
    /// (older). Follows pages from the on-disk `EventStore` with no relay
    /// round-trip; relay / relay-set / extended feeds page from their relays
    /// via `loadMore`. Disk-replay re-materialises any window-trimmed tail, so
    /// the user can scroll back through everything persisted.
    func loadOlder() {
        switch currentKind {
        case .follows:
            loadOlderFromDisk()
        case .relay, .relaySet, .extendedNetwork:
            loadMore()
        }
    }

    /// Page older Follows events in from disk. Filters cached feed-kind events
    /// to the user's follows (same rule as the seed path) and appends the next
    /// page below the current cursor. These are re-displays of already-
    /// persisted events, so they bypass the `seenIds` ingest gate and are not
    /// re-persisted — but they ARE added to `seenIds` so a later live copy
    /// doesn't double-insert. The disk cursor advances past every scanned
    /// candidate (not just the displayed ones) so a follows-sparse region of
    /// old history can't wedge paging on the same window.
    private func loadOlderFromDisk() {
        guard loadMoreTask == nil, !followsDiskExhausted else { return }
        guard let cursor = oldestLoadedTimestamp ?? events.last?.createdAt else { return }
        let myPubkey = keypair.pubkey
        let follows = followsCache
        let currentIds = Set(events.map(\.id))
        let includeReplies = AppSettings.shared.includeRepliesInFeed
        loadMoreTask = Task { [weak self] in
            defer { Task { @MainActor in self?.loadMoreTask = nil } }
            guard let self else { return }
            let candidates = await self.eventStore.loadOlder(
                before: cursor,
                limit: 400,
                excludingEventIds: PrivateInteractionStore.shared.privateEventIds
            )
            guard !candidates.isEmpty else {
                self.followsDiskExhausted = true
                return
            }
            // Advance the disk cursor past everything scanned.
            self.updateOldestLoaded(candidates.last?.createdAt)
            let page = await Task.detached(priority: .userInitiated) {
                candidates.filter { ev in
                    (ev.pubkey == myPubkey || follows.contains(ev.pubkey))
                        && FeedViewModel.isFeedRenderable(ev, includeReplies: includeReplies)
                        && !SafetyFilter.shared.shouldDrop(event: ev, context: .feed)
                        && !currentIds.contains(ev.id)
                }
                .sorted { $0.createdAt > $1.createdAt }
            }.value
            guard !page.isEmpty else { return }
            // Re-dedup against the *current* events: the `currentIds` snapshot
            // above can go stale if a live flush landed while the disk read was
            // in flight, and `mergeSortedDesc` doesn't dedup — so without this a
            // duplicate id could reach `ForEach(id: \.id)`.
            let freshIds = Set(self.events.map(\.id))
            let deduped = page.filter { !freshIds.contains($0.id) }
            guard !deduped.isEmpty else { return }
            for event in deduped { self.seenIds.insert(event.id) }
            self.events = Self.consolidateReposts(Self.mergeSortedDesc(self.events, deduped))
            self.hydrateProfiles(for: deduped)
        }
    }

    /// Pagination for relay / relay-set feeds. Issues a one-shot REQ with `until` set
    /// to the oldest loaded event's timestamp.
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
        guard let oldest = oldestLoadedTimestamp ?? events.last?.createdAt else { return }
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
                // Mirror the safety gate applied at initial load + live subscription
                // so paginated pages can't leak muted authors (e.g. a kind-6 repost
                // whose inner author is on the user's mute list).
                if SafetyFilter.shared.shouldDrop(event: event, context: .feed) { continue }
                if self.seenIds.insert(event.id).inserted {
                    added.append(event)
                }
            }
            guard !added.isEmpty else { return }
            let sortedAdded = added.sorted { $0.createdAt > $1.createdAt }
            self.updateOldestLoaded(sortedAdded.last?.createdAt)
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

        // Fetch from relays for freshness. `waitForAllRelays` so a fast empty
        // relay doesn't cancel a slower one holding the newest kind-0 — same
        // reason `ProfileRepository.runFetch` waits for all of them.
        let results = await RelayPool.query(
            relays: Self.indexerRelays,
            filter: NostrFilter(kinds: [0], authors: [pubkey], limit: 5),
            waitForAllRelays: true
        )
        if let best = results.filter({ $0.kind == 0 }).max(by: { $0.createdAt < $1.createdAt }),
           let updated = profileRepo.updateFromEvent(best) {
            userProfile = updated
            profiles[pubkey] = updated
        }

        // Reconcile the local follow set with the freshest kind-3 on relays.
        // `FollowsCache` is otherwise only written at onboarding and on in-app
        // follow/unfollow, so a follow list changed in another client (e.g.
        // trimmed via an external tool) never lands locally — and the next
        // in-app edit republishes the stale set, undoing the change.
        // `reconcile` adopts the relay copy only when its `created_at` is
        // newer than the set we already hold, so it can't clobber a fresher
        // local edit.
        let contactResults = await RelayPool.query(
            relays: Self.indexerRelays,
            filter: NostrFilter(kinds: [3], authors: [pubkey], limit: 1),
            waitForAllRelays: true
        )
        if let bestContacts = contactResults.filter({ $0.kind == 3 }).max(by: { $0.createdAt < $1.createdAt }) {
            let followPubkeys = bestContacts.tags.compactMap { tag -> String? in
                tag.count >= 2 && tag[0] == "p" ? tag[1] : nil
            }
            if FollowsCache.shared.reconcile(pubkey: pubkey, follows: followPubkeys, createdAt: bestContacts.createdAt) {
                reloadFollowsCache()
            }
        }
    }

    /// Number of (score-sorted) relays the live follows feed connects to. With
    /// `RelayConnectionPool` these are now *persistent, reused* sockets (one per
    /// relay, shared with engagement/profile/DM subs). The original scroll jank
    /// was caused by per-REQ ephemeral socket *churn*, not by the steady-state
    /// count — so a wider persistent set is cheap, while the long tail of relays
    /// it covers does carry real notes (capping at 40 dropped them and users
    /// missed posts). Restored to the pre-`b7ddc4a` value of 72; the global cap
    /// in `RelayConnectionPool` is raised in tandem to leave headroom for
    /// engagement/profile/DM/notification subs. (Android's persistent floor is
    /// 30, but its effective scroll reach is ~70-80 via its ephemeral pool.)
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
                // Same gate as every other feed write path (startSubscription,
                // seed, loadOlder, loadMore). A followed author is in the WoT
                // network by definition, but their kind-6 can wrap a stranger's
                // note — `shouldDrop` fail-closes on the inner author, and this
                // was the one live path that skipped it.
                if SafetyFilter.shared.shouldDrop(event: event, context: .feed) { continue }
                self.markActivityIfFollowed(event)
                guard Self.isFeedRenderable(event, includeReplies: AppSettings.shared.includeRepliesInFeed) else { continue }
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
        let updated = recentlySeenPubkeys
            .sorted { $0.value > $1.value }
            .map(\.key)
        // Publish only when the ordered list actually changes — during a
        // backfill burst many followed-author events leave the membership and
        // order unchanged, and a redundant write re-renders the online-now bar.
        if updated != onlineNetworkPubkeys {
            onlineNetworkPubkeys = updated
        }
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
