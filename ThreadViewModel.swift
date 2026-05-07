import Foundation
import Observation

@Observable
@MainActor
final class ThreadViewModel {
    let keypair: Keypair
    let seedEventId: String
    let authorHint: String?
    /// The canonical id of the focal note for this screen.
    ///
    /// Defaults to `seedEventId`. When the seed turns out to be a kind-6
    /// repost — e.g. a notification or feed deep-link handed us the
    /// wrapper id — `seedFromCache` unwraps the inner kind-1 and re-
    /// anchors `focalEventId` to the inner id. All reply / ancestor /
    /// engagement filtering keys off this id, because real replies
    /// `e`-tag the inner kind-1, not the kind-6 wrapper. Without this,
    /// the focal card could show "15 replies" while `rebuildSlices`
    /// rendered an empty replies list (the count came from the
    /// engagement query targeting the inner; the filter compared
    /// reply targets against the wrapper id and excluded everything).
    @ObservationIgnored private(set) var focalEventId: String

    var rootId: String
    var rootEvent: NostrEvent?
    /// Chain from root → focal-1, in order. Empty when the focal is the root.
    var ancestors: [ThreadRow] = []
    /// The focal event for this screen — usually `events[focalEventId]`.
    var focal: ThreadRow?
    /// Direct replies to the focal, sorted oldest first.
    var replies: [ThreadRow] = []
    /// Full descendant tree of the focal in DFS preorder, each row tagged with
    /// its nesting depth. Drives the inline rendering so the user sees grand-
    /// children without having to drill into each reply.
    var nestedReplies: [NestedReplyRow] = []
    /// Count of direct replies excluding blocked-author rows. Used by the
    /// focal card's reply-count bubble — deliberately the *direct* count so
    /// it matches the kind:1 e-tag count returned by engagement queries.
    var visibleRepliesCount: Int { replies.lazy.filter { !$0.isBlocked }.count }
    /// Replies hidden by the on-device spam filter, surfaced behind a "X hidden" expander.
    var hiddenSpamReplies: [ThreadRow] = []
    /// Direct-child counts per event id, derived from the local `events` map.
    /// Drives the "View N replies" hint on rows that have descendants we know about.
    var childCounts: [String: Int] = [:]
    var profiles: [String: ProfileData] = [:]
    var engagement: [String: EngagementCounts] = [:]
    var isLoading = false
    var errorMessage: String?
    var isSending = false
    /// Active undo countdown for an unsent reply, mirroring `ComposeViewModel`.
    var replyCountdown: Int?
    /// Buffered text + parent for a reply that's mid-countdown, so `publishNow` /
    /// `cancelReply` know what to do.
    @ObservationIgnored private var pendingReply: (text: String, parentId: String?)?
    @ObservationIgnored private var replyCountdownTask: Task<Void, Never>?

    @ObservationIgnored private var events: [String: NostrEvent] = [:]
    @ObservationIgnored private var loadedOnce = false
    @ObservationIgnored private var streamTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var profileUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var sweepSourceId: UUID?
    @ObservationIgnored private var engagedIds = Set<String>()
    @ObservationIgnored private var pendingEngagementIds = Set<String>()
    @ObservationIgnored private var engagementBatcher: Task<Void, Never>?
    /// Event ids whose engagement contribution has already been applied
    /// (replayed from cache or delivered live). Prevents double-counting
    /// when a relay re-sends a kind-6/7/9735 we've already ingested.
    @ObservationIgnored private var seenEngagementIds = Set<String>()
    /// Latest createdAt across cache-replayed engagement events. Live
    /// engagement queries scope `since:` to one second past this so the
    /// relay subscription only delivers truly new events.
    @ObservationIgnored private var engagementSinceFloor: Int = 0
    @ObservationIgnored private var hiddenSpamPubkeys: Set<String> = []
    @ObservationIgnored private var blockedEventIds: Set<String> = []
    @ObservationIgnored private var spamScoringInflight: Set<String> = []

    @ObservationIgnored private let eventStore = EventStore.shared
    @ObservationIgnored private let profileRepo = ProfileRepository.shared
    @ObservationIgnored private let relayListRepo = RelayListRepository.shared
    @ObservationIgnored private var publishObserver: NSObjectProtocol?
    @ObservationIgnored private var blockObserver: NSObjectProtocol?

    private static let indexerRelays = RelayDefaults.indexers

    private static let fallbackRelays = RelayDefaults.fallbacks

    init(seedEventId: String, authorHint: String?, keypair: Keypair) {
        self.keypair = keypair
        self.seedEventId = seedEventId
        self.authorHint = authorHint
        self.rootId = seedEventId
        self.focalEventId = seedEventId
        // Catch the user's own freshly-published replies the moment ComposeViewModel
        // broadcasts them — the live relay subscription often doesn't reflect outbound
        // events back, so without this the new reply only shows after a manual refresh.
        publishObserver = NotificationCenter.default.addObserver(
            forName: .nostrEventPublished,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?["event"] as? NostrEvent else { return }
            Task { @MainActor [weak self] in
                self?.handleExternalPublish(event)
            }
        }
        // Drop any cached/loaded reply from a freshly-blocked author so the
        // thread updates without waiting for a manual refresh.
        blockObserver = NotificationCenter.default.addObserver(
            forName: .userBlocked,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let blocked = note.object as? String else { return }
            Task { @MainActor [weak self] in
                self?.purgeAuthor(blocked)
            }
        }
    }

    deinit {
        if let publishObserver { NotificationCenter.default.removeObserver(publishObserver) }
        if let blockObserver { NotificationCenter.default.removeObserver(blockObserver) }
    }

    @MainActor
    private func purgeAuthor(_ pubkey: String) {
        let affected = events.values.filter { $0.pubkey == pubkey }.map(\.id)
        guard !affected.isEmpty else { return }
        // Mark every event from this author as blocked rather than evicting
        // it from `events`. `rebuildSlices` reads `blockedEventIds` to render
        // a placeholder card in place — so the focal / ancestors / replies
        // keep their positions and the thread doesn't collapse just because
        // the user muted someone partway through reading (#69).
        for id in affected {
            blockedEventIds.insert(id)
        }
        rebuildSlices()
    }

    /// Ingest a kind-1 the user just published from outside this thread (typically the
    /// shared compose sheet) when it references something we already track. Reposts
    /// (kind-6) of the root or a known reply also count.
    private func handleExternalPublish(_ event: NostrEvent) {
        guard event.kind == 1 || event.kind == 6 else { return }
        let etags = event.tags.compactMap { tag -> String? in
            guard tag.count >= 2, tag[0] == "e" else { return nil }
            return tag[1]
        }
        let known = etags.contains(where: { events.keys.contains($0) || $0 == rootId })
        guard known else { return }
        if event.kind == 1 {
            ingestReply(event)
        }
    }

    // MARK: - Lifecycle

    func start() async {
        ensureProfileUpdatesSubscription()
        guard !loadedOnce else { return }
        loadedOnce = true
        isLoading = true
        errorMessage = nil

        // 1. Seed from cache: fast path so the screen isn't blank.
        await seedFromCache()

        // 2. Initial relay set (focal author + scored + indexer fallback when
        //    rootEvent isn't loaded). This is the widest set we'll have until
        //    the root resolves.
        let initialRelays = await resolveRelays()

        // 3. Open live subscriptions IMMEDIATELY so reply / ancestor events
        //    stream in concurrently with the explicit fetches below.
        //    Previously fetchRoot + fetchAncestorChain ran first sequentially,
        //    blocking the live stream by up to ~12s on a cold notification
        //    deep-link — long enough for the user to see "just the focal" and
        //    reach for pull-to-refresh.
        startReplyStream(relays: initialRelays)
        startEngagementBatcher(relays: initialRelays)
        var seedIds = Set(events.keys)
        seedIds.insert(rootId)
        queueEngagement(ids: seedIds)

        // 4. Fetch root + ancestor chain in parallel against the initial set.
        //    The ancestor walk depends on the seed but not on the root, so
        //    they don't have to serialize. Both feed events into the same
        //    `events` map; rebuildSlices fires per-ingest.
        let needRoot = rootEvent == nil
        let needAncestors = focalEventId != rootId
        if needRoot && needAncestors {
            async let rootFetch: Void = fetchRoot(from: initialRelays)
            async let ancestorFetch: Void = fetchAncestorChain(from: initialRelays)
            _ = await (rootFetch, ancestorFetch)
        } else if needRoot {
            await fetchRoot(from: initialRelays)
        } else if needAncestors {
            await fetchAncestorChain(from: initialRelays)
        }

        // 5. Once the root is loaded, re-resolve relays (now using the real
        //    root author's outbox) and re-stream so the broader set catches
        //    descendants the initial set may have missed. Saves the user
        //    from pull-to-refresh on cold notification loads.
        if rootEvent != nil {
            let widerRelays = await resolveRelays()
            if Set(widerRelays) != Set(initialRelays) {
                cancelStreams()
                startReplyStream(relays: widerRelays)
                startEngagementBatcher(relays: widerRelays)
                var ids2 = Set(events.keys)
                ids2.insert(rootId)
                queueEngagement(ids: ids2)
            }
        }

        // Hydrate every pubkey the root note references (author + repost inner + npub
        // mentions) — cold loads otherwise leave mentions as truncated hex.
        if let root = rootEvent {
            for pk in root.referencedAuthorPubkeys where profiles[pk] == nil {
                if let cached = profileRepo.get(pk) { profiles[pk] = cached }
            }
            MissingProfileWatcher.shared.observe(root)
        }
    }

    func refresh() async {
        cancelStreams()
        let relays = await resolveRelays()
        startReplyStream(relays: relays)
        startEngagementBatcher(relays: relays)
        var seedIds = Set(events.keys)
        seedIds.insert(rootId)
        queueEngagement(ids: seedIds)
    }

    func stop() {
        cancelStreams()
        profileUpdatesTask?.cancel()
        profileUpdatesTask = nil
        if let id = sweepSourceId {
            MissingProfileWatcher.shared.unregisterSource(id)
            sweepSourceId = nil
        }
    }

    private func ensureProfileUpdatesSubscription() {
        if profileUpdatesTask == nil {
            profileUpdatesTask = Task { @MainActor [weak self] in
                for await pk in MissingProfileWatcher.shared.updates {
                    guard let self else { return }
                    if let p = self.profileRepo.get(pk) { self.profiles[pk] = p }
                }
            }
        }
        if sweepSourceId == nil {
            sweepSourceId = MissingProfileWatcher.shared.registerSource { [weak self] in
                guard let self else { return [] }
                return Array(self.events.values)
            }
        }
    }

    private func cancelStreams() {
        for task in streamTasks { task.cancel() }
        streamTasks.removeAll()
        engagementBatcher?.cancel()
        engagementBatcher = nil
    }

    // MARK: - Reply

    /// Sends a kind:1 reply to `parentId` (defaults to the focal). Publishes to the user's
    /// own write relays plus the inbox relays of the root author, parent author, and every pubkey
    /// already participating in the chain.
    /// Begin an undo countdown before actually publishing the reply (length
    /// from `AppSettings.postUndoTimerSeconds`). Replies skip the countdown
    /// entirely when `postUndoTimerEnabled` is off OR when the user opted to
    /// keep the timer for top-level posts only (`postUndoTimerForReplies`
    /// false — the default).
    /// While the countdown is running, callers can `publishReplyNow()` to skip
    /// the timer or `cancelReply()` to drop the pending send.
    func publishReply(content: String, parentId: String? = nil) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard rootEvent != nil else {
            errorMessage = "Thread root unavailable"
            return
        }
        guard replyCountdown == nil, !isSending else { return }

        pendingReply = (trimmed, parentId)

        let settings = AppSettings.shared
        let useTimer = settings.postUndoTimerEnabled && settings.postUndoTimerForReplies
        guard useTimer, settings.postUndoTimerSeconds > 0 else {
            // Flip `isSending` synchronously so the reply input shows the
            // spinner the moment the user taps Send. The pipeline sets the
            // same flag again, harmlessly, and resets via `defer`.
            isSending = true
            Task { @MainActor [weak self] in await self?.runReplyPublishPipeline() }
            return
        }
        let totalSeconds = settings.postUndoTimerSeconds
        // Surface the countdown UI synchronously. Without this the inline
        // reply button stays in its idle state until the countdown Task
        // first runs, which feels like a no-op on the user's tap.
        replyCountdown = totalSeconds
        replyCountdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for n in stride(from: totalSeconds - 1, through: 1, by: -1) {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                self.replyCountdown = n
            }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            self.replyCountdown = nil
            await self.runReplyPublishPipeline()
        }
    }

    /// Skip the remaining countdown and publish immediately.
    func publishReplyNow() {
        replyCountdownTask?.cancel()
        replyCountdownTask = nil
        replyCountdown = nil
        Task { await runReplyPublishPipeline() }
    }

    /// Discard the pending reply without publishing.
    func cancelReply() {
        replyCountdownTask?.cancel()
        replyCountdownTask = nil
        replyCountdown = nil
        pendingReply = nil
    }

    private func runReplyPublishPipeline() async {
        guard let pending = pendingReply else { return }
        pendingReply = nil
        let trimmed = pending.text
        guard let root = rootEvent else {
            errorMessage = "Thread root unavailable"
            return
        }
        // Default reply parent is the screen's focal, not the root. Each pushed
        // ThreadView replies to its own focal.
        let defaultParent: NostrEvent = events[focalEventId] ?? root
        let parent: NostrEvent = pending.parentId.flatMap { events[$0] } ?? defaultParent

        isSending = true
        defer { isSending = false }

        let createdAt = Int(Date().timeIntervalSince1970)
        var tags = Nip10.buildReplyTags(replyTo: parent, relayHint: "")
        if let clientTag = NostrEvent.clientTagIfEnabled() { tags.append(clientTag) }

        let signed: NostrEvent
        do {
            signed = try await Signer.sign(
                keypair: keypair,
                kind: 1,
                tags: tags,
                content: trimmed,
                createdAt: createdAt
            )
        } catch {
            errorMessage = "Failed to sign event: \(error.localizedDescription)"
            return
        }

        // Build target relay set: own write + inboxes of every pubkey in the chain.
        var targets = Set<String>()

        let ownWrite = await relayListRepo.getWriteRelays(keypair.pubkey)
        if ownWrite.isEmpty {
            // Fall back to the user's outbox score board so the event lands somewhere.
            if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
                for relay in board.scoredRelays.prefix(5) { targets.insert(relay.url) }
            }
            for url in Self.fallbackRelays { targets.insert(url) }
        } else {
            for url in ownWrite { targets.insert(url) }
        }

        var inboxPubkeys = Set<String>()
        inboxPubkeys.insert(root.pubkey)
        inboxPubkeys.insert(parent.pubkey)
        for tag in tags where tag.count >= 2 && tag[0] == "p" {
            inboxPubkeys.insert(tag[1])
        }
        inboxPubkeys.remove(keypair.pubkey)

        for pubkey in inboxPubkeys {
            for url in await relayListRepo.getReadRelays(pubkey) {
                targets.insert(url)
            }
        }

        let accepted = await RelayPool.publish(event: signed, to: Array(targets), timeout: 6)
        if accepted.isEmpty {
            errorMessage = "No relays accepted the reply"
            return
        }

        // Optimistic insert.
        events[signed.id] = signed
        await eventStore.persist([signed])
        if profiles[keypair.pubkey] == nil, let me = profileRepo.get(keypair.pubkey) {
            profiles[keypair.pubkey] = me
        }
        rebuildSlices()
    }

    // MARK: - Cache seed

    /// If `event` is a kind-6 repost whose JSON payload parses into an
    /// inner kind-1, return that inner event; otherwise return `event`
    /// unchanged. Used by the cache seed so a thread opened directly on a
    /// repost's id still focuses on the original note rather than
    /// rendering the kind-6 with its banner alongside the same inner
    /// content as an ancestor.
    private nonisolated func unwrapRepostForFocal(_ event: NostrEvent) -> NostrEvent {
        guard event.kind == 6, !event.content.isEmpty,
              let data = event.content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = NostrEvent(json: json), inner.kind == 1 else {
            return event
        }
        return inner
    }

    private func seedFromCache() async {
        // Fast path: direct id lookup for the seed so we can paint the root note
        // immediately. The thread-cache substring scan below is O(all kind-1 events)
        // and is what made tapping a feed note feel laggy — flipping `rootEvent`
        // synchronously here lets the UI render before we walk the replies.
        if let seedEvent = await eventStore.eventsByIds([seedEventId]).first {
            // If a notification deep-link or a caller that didn't resolve
            // through `displayEventId` handed us a kind-6 repost as the
            // seed, the focal would render the kind-6 (inner content +
            // "X reposted" banner) AND `Nip10.replyTarget` would walk the
            // inner kind-1 in as an ancestor on top — the same content
            // appearing twice in the thread. Substitute the parsed inner
            // kind-1 in for the focal slot so the chain walk operates
            // against the original note. Re-anchor `focalEventId` to the
            // inner id so reply filtering and ancestor lookups use the
            // id that real replies actually `e`-tag.
            let focalEvent = unwrapRepostForFocal(seedEvent)
            focalEventId = focalEvent.id
            let resolvedRoot = Nip10.rootId(of: focalEvent) ?? focalEvent.id
            rootId = resolvedRoot
            events[focalEventId] = focalEvent
            if focalEvent.id == resolvedRoot {
                rootEvent = focalEvent
                isLoading = false
            }
        }

        // If the seed was a reply, pull its true root by id too so the header
        // renders without waiting on the network.
        if rootEvent == nil, rootId != focalEventId,
           let cachedRoot = await eventStore.eventsByIds([rootId]).first {
            events[cachedRoot.id] = cachedRoot
            rootEvent = cachedRoot
            isLoading = false
        }

        // Now load the full thread cache anchored at the resolved root.
        let cached = await eventStore.loadThreadCache(rootId: rootId)
        let blockedPubkeys = SafetyFilter.shared.snapshot.blockedPubkeys
        for event in cached where event.kind == 1 {
            if event.id != rootId {
                // Blocked-author events are kept as placeholders so the thread
                // depth and the user's own replies to them remain coherent.
                // Other safety drops (WoT, word filter) fully exclude the event.
                if blockedPubkeys.contains(event.pubkey) {
                    events[event.id] = event
                    blockedEventIds.insert(event.id)
                    continue
                }
                if SafetyFilter.shared.shouldDrop(event: event, context: .thread(rootId: rootId)) {
                    continue
                }
            }
            events[event.id] = event
            if event.id == rootId { rootEvent = event }
        }

        if !events.isEmpty {
            rebuildSlices()
            var referenced = Set<String>()
            for event in events.values {
                for pk in event.referencedAuthorPubkeys {
                    referenced.insert(pk)
                }
            }
            for pk in referenced {
                if let p = profileRepo.get(pk) {
                    profiles[pk] = p
                }
            }
            MissingProfileWatcher.shared.observePubkeys(referenced)
            if rootEvent != nil { isLoading = false }
        }

        // Replay any cached engagement events (kind 6/7/9735) for the tree so
        // the UI shows last-known counts immediately. The matching dedup sets
        // get primed by `ingestEngagement`, so when the live subscription
        // re-delivers these events they're skipped instead of double-counted.
        let trackedIds = Set(events.keys).union([rootId])
        let cachedEngagement = await eventStore.loadEngagement(forTargetIds: trackedIds)
        if !cachedEngagement.isEmpty {
            ingestEngagement(cachedEngagement)
            // Track the latest createdAt so the live query can ask for events
            // strictly newer than what we've already replayed.
            engagementSinceFloor = cachedEngagement.map(\.createdAt).max() ?? engagementSinceFloor
        }
    }

    // MARK: - Network fetch

    private func resolveRelays() async -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        // Root author inbox (read) relays.
        let rootAuthor = rootEvent?.pubkey ?? authorHint
        if let pk = rootAuthor {
            for url in await relayListRepo.getReadRelays(pk) where seen.insert(url).inserted {
                ordered.append(url)
            }
        }

        // Focal author inbox — replies to the focal are sent to its
        // author's read relays (NIP-65 outbox model). When the focal
        // isn't the root, the root author's inbox alone misses every
        // reply that came in via the focal author's relay set, which
        // is what made deep-thread navigation render "no replies".
        let focalAuthor = events[focalEventId]?.pubkey ?? authorHint
        if let pk = focalAuthor, pk != rootAuthor {
            for url in await relayListRepo.getReadRelays(pk) where seen.insert(url).inserted {
                ordered.append(url)
            }
        }

        // Top scored relays (highest follow coverage) — mirrors the Android `take(5)` safety net.
        if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
            for relay in board.scoredRelays.prefix(5) where seen.insert(relay.url).inserted {
                ordered.append(relay.url)
            }
        }

        // Cold-load safety net: when we don't yet have the root, the
        // outbox set built above is just `authorHint`'s read relays —
        // for a notification deep-link that's the user's own inbox,
        // which usually doesn't carry the thread root or its ancestors.
        // Indexer relays catch most events and let fetchRoot resolve so
        // the second resolveRelays() pass can use the real root author's
        // outbox set.
        if rootEvent == nil {
            for url in Self.indexerRelays where seen.insert(url).inserted {
                ordered.append(url)
            }
        }

        // If we found nothing (e.g. brand-new account), fall back to a known set.
        if ordered.isEmpty {
            for url in Self.fallbackRelays where seen.insert(url).inserted {
                ordered.append(url)
            }
        }

        return ordered
    }

    private func fetchRoot(from relays: [String]) async {
        var filter = NostrFilter()
        filter.ids = [rootId]
        filter.limit = 1
        let results = await RelayPool.query(relays: relays, filter: filter, timeout: 6)
        if let event = results.first(where: { $0.id == rootId }) {
            events[event.id] = event
            rootEvent = event
            // The root we just fetched may itself be a reply; re-resolve and re-fetch.
            if let trueRoot = Nip10.rootId(of: event), trueRoot != rootId {
                rootId = trueRoot
                rootEvent = events[trueRoot]
                if rootEvent == nil {
                    var rootFilter = NostrFilter()
                    rootFilter.ids = [trueRoot]
                    rootFilter.limit = 1
                    let upstream = await RelayPool.query(relays: relays, filter: rootFilter, timeout: 6)
                    if let upstreamRoot = upstream.first(where: { $0.id == trueRoot }) {
                        events[upstreamRoot.id] = upstreamRoot
                        rootEvent = upstreamRoot
                    }
                }
            }
            await eventStore.persist([event])
        }
    }

    /// Walk `Nip10.replyTarget` upward from the focal, fetching any missing intermediate
    /// ancestors one event at a time so the chain renders without waiting for the broad
    /// `e: [rootId]` replies stream. Bounded at 30 hops as a safety stop.
    private func fetchAncestorChain(from relays: [String]) async {
        guard var current = events[focalEventId] else { return }
        for _ in 0..<30 {
            guard let parentId = Nip10.replyTarget(of: current) else { break }
            if let parent = events[parentId] {
                current = parent
                continue
            }
            var filter = NostrFilter()
            filter.ids = [parentId]
            filter.limit = 1
            let results = await RelayPool.query(relays: relays, filter: filter, timeout: 6)
            guard let parent = results.first(where: { $0.id == parentId }) else { break }
            events[parent.id] = parent
            await eventStore.persist([parent])
            if parent.id == rootId { rootEvent = parent }
            current = parent
        }
        rebuildSlices()
    }

    /// Open a live subscription for replies. Events are merged into the UI as each relay sends
    /// them — no waiting on EOSE. After `duration` seconds the subscription is cancelled.
    private func startReplyStream(relays: [String], duration: TimeInterval = 12) {
        guard !relays.isEmpty else { return }
        // Query for events tagging the root OR the focal — root catches the
        // whole tree, focal catches direct children that some relays may
        // store without the root e-tag.
        var eTagTargets = [rootId]
        if focalEventId != rootId { eTagTargets.append(focalEventId) }
        let filter = NostrFilter(kinds: [1], eTags: eTagTargets, limit: 500)
        let subId = "thread-replies-\(UUID().uuidString.prefix(6))"
        let sub = RelayPool.subscribe(relays: relays, filter: filter, id: subId)

        let consumer = Task { [weak self, rootId, focalEventId] in
            for await (event, _) in sub.events {
                guard let self else { break }
                guard event.kind == 1 else { continue }
                // Accept any event tagging the root or the focal — both
                // are valid for the current screen.
                guard event.tags.contains(where: { tag in
                    guard tag.count >= 2, tag[0] == "e" else { return false }
                    return tag[1] == rootId || tag[1] == focalEventId
                }) else { continue }
                let snap = SafetyFilter.shared.snapshot
                if snap.blockedPubkeys.contains(event.pubkey) {
                    // Keep as a placeholder; do not score for spam.
                    self.ingestReply(event, blocked: true)
                    continue
                }
                if SafetyFilter.shared.shouldDrop(event: event, context: .thread(rootId: rootId)) { continue }
                self.ingestReply(event)
                self.maybeScoreReplyForSpam(event)
            }
        }

        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            sub.cancel()
            consumer.cancel()
            await self?.markStreamingDone()
        }

        streamTasks.append(consumer)
        streamTasks.append(watchdog)
    }

    private func ingestReply(_ event: NostrEvent, blocked: Bool = false) {
        guard events[event.id] == nil else { return }
        events[event.id] = event
        if blocked { blockedEventIds.insert(event.id) }
        Task { await eventStore.persist([event]) }

        // Hydrate every referenced author (note author + repost inner + npub mentions) from
        // cache; the watcher takes care of fetching anything we haven't seen.
        for pk in event.referencedAuthorPubkeys where profiles[pk] == nil {
            if let cached = profileRepo.get(pk) {
                profiles[pk] = cached
            }
        }
        MissingProfileWatcher.shared.observe(event)

        queueEngagement(ids: [event.id])
        rebuildSlices()
        if isLoading { isLoading = false }
    }

    private func markStreamingDone() {
        if isLoading { isLoading = false }
    }

    /// Coalesce engagement subscriptions: as new event ids arrive, batch them every 400ms and open
    /// a fresh per-batch subscription that streams reactions / reposts / zaps live.
    private func startEngagementBatcher(relays: [String]) {
        engagementBatcher?.cancel()
        engagementBatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self else { return }
                let pending = await self.takePendingEngagementIds()
                guard !pending.isEmpty else { continue }
                await self.openEngagementSub(ids: pending, relays: relays)
            }
        }
    }

    private func queueEngagement<S: Sequence>(ids: S) where S.Element == String {
        for id in ids {
            if !engagedIds.contains(id) {
                pendingEngagementIds.insert(id)
            }
        }
    }

    private func takePendingEngagementIds() -> [String] {
        let ids = Array(pendingEngagementIds)
        pendingEngagementIds.removeAll()
        for id in ids { engagedIds.insert(id) }
        return ids
    }

    private func openEngagementSub(ids: [String], relays: [String]) async {
        guard !ids.isEmpty, !relays.isEmpty else { return }
        let rootIdLocal = rootId
        // Only fetch events strictly newer than what cache replay already
        // covered. `engagementSinceFloor` is the latest `createdAt` we've
        // ingested locally; +1 keeps the boundary exclusive.
        let since: Int? = engagementSinceFloor > 0 ? engagementSinceFloor + 1 : nil
        for chunk in ids.chunked(into: 50) {
            let subId = "thread-engagement-\(UUID().uuidString.prefix(6))"
            let filter = NostrFilter(kinds: [1, 6, 7, 9735], eTags: chunk, limit: 500, since: since)
            let sub = RelayPool.subscribe(relays: relays, filter: filter, id: subId)
            let consumer = Task { [weak self] in
                for await (event, _) in sub.events {
                    if SafetyFilter.shared.shouldDrop(event: event, context: .thread(rootId: rootIdLocal)) { continue }
                    self?.ingestEngagement([event])
                }
            }
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(12))
                sub.cancel()
                consumer.cancel()
            }
            streamTasks.append(consumer)
            streamTasks.append(watchdog)
        }
    }

    private func ingestEngagement(_ events: [NostrEvent]) {
        for event in events {
            // Skip events we've already counted (cache replay + live delivery
            // can otherwise double-count the same id). `seenEngagementIds`
            // is shared across both pathways.
            guard seenEngagementIds.insert(event.id).inserted else { continue }
            // Aggregate against every e-tag the engagement event references so the count attaches to
            // both the direct parent and (where applicable) the root.
            let targets = event.tags.compactMap { tag -> String? in
                guard tag.count >= 2, tag[0] == "e" else { return nil }
                if tag.count >= 4, tag[3] == "mention" { return nil }
                return tag[1]
            }
            guard let primary = targets.last else { continue }
            var current = engagement[primary] ?? EngagementCounts()
            switch event.kind {
            case 1:
                current.replies += 1
            case 6:
                current.reposts += 1
            case 7:
                current.reactions += 1
                let reactor = Reactor(
                    pubkey: event.pubkey,
                    emoji: event.content,
                    customEmojiUrl: EngagementRepository.customEmojiUrl(for: event.content, in: event.tags)
                )
                if !current.reactors.contains(where: { $0.pubkey == reactor.pubkey && $0.emoji == reactor.emoji }) {
                    current.reactors.append(reactor)
                }
            case 9735:
                if let bolt = event.tags.first(where: { $0.first == "bolt11" && $0.count >= 2 })?[1],
                   let decoded = Bolt11.decode(bolt),
                   let sats = decoded.amountSats {
                    current.zapSats += sats
                    current.zapCount += 1
                } else {
                    current.zapCount += 1
                }
            default: break
            }
            engagement[primary] = current
        }
    }

    // MARK: - Slices

    /// Recompute `ancestors`, `focal`, `replies`, `childCounts`, and `hiddenSpamReplies`
    /// from the current `events` map. Called whenever events change.
    private func rebuildSlices() {
        focal = events[focalEventId].map { ThreadRow(event: $0, isBlocked: blockedEventIds.contains($0.id)) }
        ancestors = computeAncestors()

        // Tally direct children per parent so reply rows can show a
        // "View N replies" hint as soon as any descendants are loaded.
        var counts: [String: Int] = [:]
        for event in events.values {
            guard let parentId = Nip10.replyTarget(of: event) else { continue }
            counts[parentId, default: 0] += 1
        }
        childCounts = counts

        let directReplies = events.values
            .filter { event in
                guard event.id != focalEventId else { return false }
                // Replies are kind-1 only. A kind-6 repost references this note
                // via its `e` tag too, but it isn't a reply — without this
                // guard it'd surface as a duplicate card under the focal.
                guard event.kind == 1 else { return false }
                return Nip10.replyTarget(of: event) == focalEventId
            }
            .sorted { $0.createdAt < $1.createdAt }

        if hiddenSpamPubkeys.isEmpty {
            replies = directReplies.map { ThreadRow(event: $0, isBlocked: blockedEventIds.contains($0.id)) }
            hiddenSpamReplies = []
        } else {
            var visible: [ThreadRow] = []
            var hidden: [ThreadRow] = []
            for event in directReplies {
                let row = ThreadRow(event: event, isBlocked: blockedEventIds.contains(event.id))
                if row.isBlocked { visible.append(row); continue }
                if hiddenSpamPubkeys.contains(event.pubkey) { hidden.append(row) }
                else { visible.append(row) }
            }
            replies = visible
            hiddenSpamReplies = hidden
        }

        nestedReplies = buildNestedReplies()
    }

    /// DFS preorder walk from the focal through every known descendant.
    /// Children of a parent are sorted oldest-first to match the direct-
    /// reply ordering. Blocked rows and hidden-spam authors drop with their
    /// entire subtree — same rule we apply to the direct list — so a muted
    /// branch doesn't leave orphaned grandchildren stranded at depth 0.
    private func buildNestedReplies() -> [NestedReplyRow] {
        var childrenByParent: [String: [NostrEvent]] = [:]
        for event in events.values where event.kind == 1 && event.id != focalEventId {
            guard let parentId = Nip10.replyTarget(of: event) else { continue }
            childrenByParent[parentId, default: []].append(event)
        }
        for key in childrenByParent.keys {
            childrenByParent[key]?.sort { $0.createdAt < $1.createdAt }
        }

        var result: [NestedReplyRow] = []
        var visited: Set<String> = [focalEventId]

        func walk(parentId: String, depth: Int) {
            guard let kids = childrenByParent[parentId] else { return }
            for kid in kids {
                guard visited.insert(kid.id).inserted else { continue }
                if blockedEventIds.contains(kid.id) { continue }
                if hiddenSpamPubkeys.contains(kid.pubkey) { continue }
                result.append(NestedReplyRow(
                    row: ThreadRow(event: kid, isBlocked: false),
                    depth: depth
                ))
                walk(parentId: kid.id, depth: depth + 1)
            }
        }
        walk(parentId: focalEventId, depth: 0)
        return result
    }

    /// Walk parent-of-parent from focal up to root, returning the chain in root → focal-1 order.
    /// Stops at the first missing event (the live stream / `fetchAncestorChain` will fill in
    /// gaps and this gets called again).
    private func computeAncestors() -> [ThreadRow] {
        guard let focal = events[focalEventId] else { return [] }
        var chain: [NostrEvent] = []
        var current = focal
        var seen: Set<String> = [focal.id]
        for _ in 0..<30 {
            guard let parentId = Nip10.replyTarget(of: current),
                  seen.insert(parentId).inserted,
                  let parent = events[parentId] else { break }
            chain.append(parent)
            current = parent
        }
        return chain.reversed().map { ThreadRow(event: $0, isBlocked: blockedEventIds.contains($0.id)) }
    }

    // MARK: - NSpam

    fileprivate func maybeScoreReplyForSpam(_ event: NostrEvent) {
        guard SafetyPreferences.shared.spamFilterEnabled else { return }
        guard event.kind == 1, event.pubkey != keypair.pubkey else { return }
        let author = event.pubkey
        if SafetyPreferences.shared.isSafelisted(author) { return }
        if hiddenSpamPubkeys.contains(author) { return }
        if spamScoringInflight.contains(author) { return }
        let follows = FollowsCache.shared.follows(for: keypair.pubkey)
        if follows.contains(author) { return }

        spamScoringInflight.insert(author)
        Task { [weak self, author] in
            guard let self else { return }
            let recent = await EventStore.shared.loadRecentByAuthor(pubkey: author, limit: 5)
            var pool = recent
            if !pool.contains(where: { $0.id == event.id }) { pool.insert(event, at: 0) }
            let score = await SpamScorer.shared.score(pubkey: author, recentEvents: pool)
            await MainActor.run {
                self.spamScoringInflight.remove(author)
                guard let s = score, s >= SpamScorer.spamThreshold else { return }
                self.hiddenSpamPubkeys.insert(author)
                self.rebuildSlices()
            }
        }
    }

    func revealHiddenSpamAuthor(_ pubkey: String) {
        hiddenSpamPubkeys.remove(pubkey)
        SafetyPreferences.shared.addToSafelist(pubkey)
        Task { await SpamScorer.shared.invalidate(pubkey: pubkey) }
        rebuildSlices()
    }
}

struct ThreadRow: Identifiable {
    let event: NostrEvent
    var isBlocked: Bool = false
    var id: String { event.id }
}

struct NestedReplyRow: Identifiable {
    let row: ThreadRow
    let depth: Int
    var id: String { row.id }
}
