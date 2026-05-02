import Foundation
import Observation

@Observable
@MainActor
final class ThreadViewModel {
    let keypair: Keypair
    let seedEventId: String
    let authorHint: String?

    var rootId: String
    var rootEvent: NostrEvent?
    var flat: [ThreadRow] = []
    var hiddenSpamReplies: [ThreadRow] = []
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
    @ObservationIgnored private var profileFetchInflight = Set<String>()
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
    @ObservationIgnored private var spamScoringInflight: Set<String> = []
    @ObservationIgnored private var blockedEventIds: Set<String> = []

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
        let dropped = events.values.filter { $0.pubkey == pubkey }.map(\.id)
        guard !dropped.isEmpty else { return }
        for id in dropped {
            events.removeValue(forKey: id)
            blockedEventIds.remove(id)
        }
        rebuildTree()
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
        guard !loadedOnce else { return }
        loadedOnce = true
        isLoading = true
        errorMessage = nil

        // 1. Seed from cache: fast path so the screen isn't blank.
        await seedFromCache()

        // 2. Resolve the relay set we'll query for replies (root author inbox + top scored).
        var relays = await resolveRelays()

        // 3. If we still don't have the root, fetch it (one-shot — needs to complete before
        //    streaming so we can compute the correct rootId / author inbox).
        if rootEvent == nil {
            await fetchRoot(from: relays)
            relays = await resolveRelays()
        }

        // Hydrate every pubkey the root note references (author + repost inner + npub
        // mentions) — cold loads otherwise leave mentions as truncated hex.
        if let root = rootEvent {
            for pk in FeedViewModel.referencedAuthorPubkeys(in: root) where profiles[pk] == nil {
                if let cached = profileRepo.get(pk) { profiles[pk] = cached }
                else { queueProfileFetch(pk) }
            }
        }

        // 4. Open live subscriptions for replies + engagement and let the UI update as events
        //    arrive. The relay race is what makes the thread feel instant.
        startReplyStream(relays: relays)
        startEngagementBatcher(relays: relays)
        // Seed the engagement subscription with the root + everything we already have from cache.
        var seedIds = Set(events.keys)
        seedIds.insert(rootId)
        queueEngagement(ids: seedIds)
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
    }

    private func cancelStreams() {
        for task in streamTasks { task.cancel() }
        streamTasks.removeAll()
        engagementBatcher?.cancel()
        engagementBatcher = nil
    }

    // MARK: - Reply

    /// Sends a kind:1 reply to `parentId` (defaults to the current root). Publishes to the user's
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
        let parent: NostrEvent = pending.parentId.flatMap { events[$0] } ?? root

        isSending = true
        defer { isSending = false }

        let createdAt = Int(Date().timeIntervalSince1970)
        var tags = Nip10.buildReplyTags(replyTo: parent, relayHint: "")
        if let clientTag = NostrEvent.clientTagIfEnabled() { tags.append(clientTag) }

        guard let privkeyBytes = Hex.decode(keypair.privkey) else {
            errorMessage = "Invalid signing key"
            return
        }
        let signed: NostrEvent
        do {
            signed = try NostrEvent.sign(
                privkey32: privkeyBytes,
                pubkey: keypair.pubkey,
                kind: 1,
                createdAt: createdAt,
                tags: tags,
                content: trimmed
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
        rebuildTree()
    }

    // MARK: - Cache seed

    private func seedFromCache() async {
        // Try to find the seed event itself (it could be the root, or a reply that points to a root).
        let seedScan = await eventStore.loadThreadCache(rootId: seedEventId)
        if let seedEvent = seedScan.first(where: { $0.id == seedEventId }) {
            let resolvedRoot = Nip10.rootId(of: seedEvent) ?? seedEvent.id
            rootId = resolvedRoot
            events[seedEvent.id] = seedEvent
            if seedEvent.id == resolvedRoot {
                rootEvent = seedEvent
            }
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
            rebuildTree()
            var referenced = Set<String>()
            for event in events.values {
                for pk in FeedViewModel.referencedAuthorPubkeys(in: event) {
                    referenced.insert(pk)
                }
            }
            for pk in referenced {
                if let p = profileRepo.get(pk) {
                    profiles[pk] = p
                } else {
                    queueProfileFetch(pk)
                }
            }
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

        // Top scored relays (highest follow coverage) — mirrors the Android `take(5)` safety net.
        if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
            for relay in board.scoredRelays.prefix(5) where seen.insert(relay.url).inserted {
                ordered.append(relay.url)
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

    /// Open a live subscription for replies. Events are merged into the UI as each relay sends
    /// them — no waiting on EOSE. After `duration` seconds the subscription is cancelled.
    private func startReplyStream(relays: [String], duration: TimeInterval = 12) {
        guard !relays.isEmpty else { return }
        let filter = NostrFilter(kinds: [1], eTags: [rootId], limit: 500)
        let subId = "thread-replies-\(UUID().uuidString.prefix(6))"
        let sub = RelayPool.subscribe(relays: relays, filter: filter, id: subId)

        let consumer = Task { [weak self, rootId] in
            for await (event, _) in sub.events {
                guard let self else { break }
                guard event.kind == 1 else { continue }
                guard event.tags.contains(where: { $0.count >= 2 && $0[0] == "e" && $0[1] == rootId }) else { continue }
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
        // cache; queue an indexer fetch for any pubkey we've never seen.
        for pk in FeedViewModel.referencedAuthorPubkeys(in: event) where profiles[pk] == nil {
            if let cached = profileRepo.get(pk) {
                profiles[pk] = cached
            } else {
                queueProfileFetch(pk)
            }
        }

        queueEngagement(ids: [event.id])
        rebuildTree()
        if isLoading { isLoading = false }
    }

    private func markStreamingDone() {
        if isLoading { isLoading = false }
    }

    /// Debounced batch fetch for profiles of newly-seen authors. Runs in the background so the
    /// stream consumer stays responsive.
    private func queueProfileFetch(_ pubkey: String) {
        guard profileFetchInflight.insert(pubkey).inserted else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            await self?.flushProfileFetches()
        }
    }

    private func flushProfileFetches() async {
        let pubkeys = Array(profileFetchInflight)
        profileFetchInflight.removeAll()
        guard !pubkeys.isEmpty else { return }

        for batch in pubkeys.chunked(into: 150) {
            let results = await RelayPool.query(
                relays: Self.indexerRelays,
                filter: NostrFilter(kinds: [0], authors: batch),
                timeout: 6
            )
            var bestByAuthor: [String: NostrEvent] = [:]
            for event in results where event.kind == 0 {
                if let existing = bestByAuthor[event.pubkey], event.createdAt <= existing.createdAt { continue }
                bestByAuthor[event.pubkey] = event
            }
            for (_, event) in bestByAuthor {
                if let profile = profileRepo.updateFromEvent(event) {
                    profiles[event.pubkey] = profile
                }
            }
        }
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

    // MARK: - Tree

    private func rebuildTree() {
        var parentToChildren: [String: [NostrEvent]] = [:]
        for event in events.values where event.id != rootId {
            var parentId = Nip10.replyTarget(of: event) ?? rootId
            // If the named parent isn't in this thread, attach to root so the message is still visible.
            if parentId != rootId, events[parentId] == nil {
                parentId = rootId
            }
            parentToChildren[parentId, default: []].append(event)
        }
        for key in parentToChildren.keys {
            parentToChildren[key]?.sort { $0.createdAt < $1.createdAt }
        }

        var rows: [ThreadRow] = []
        var visited = Set<String>()
        dfs(parentId: rootId, depth: 0, parentToChildren: parentToChildren, visited: &visited, into: &rows)

        if hiddenSpamPubkeys.isEmpty {
            flat = rows
            hiddenSpamReplies = []
        } else {
            var visible: [ThreadRow] = []
            var hidden: [ThreadRow] = []
            for row in rows {
                // Blocked placeholder rows are never spam-hidden — they already
                // have no visible content, so burying them again adds no value.
                if !row.isBlocked, hiddenSpamPubkeys.contains(row.event.pubkey) {
                    hidden.append(row)
                } else {
                    visible.append(row)
                }
            }
            flat = visible
            hiddenSpamReplies = hidden
        }
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
                self.rebuildTree()
            }
        }
    }

    /// Surface a previously-hidden reply: drop the author from the local hidden set, add to the
    /// global safelist so they bypass scoring on every future reply, and rebuild the tree.
    func revealHiddenSpamAuthor(_ pubkey: String) {
        hiddenSpamPubkeys.remove(pubkey)
        SafetyPreferences.shared.addToSafelist(pubkey)
        Task { await SpamScorer.shared.invalidate(pubkey: pubkey) }
        rebuildTree()
    }

    private func dfs(
        parentId: String,
        depth: Int,
        parentToChildren: [String: [NostrEvent]],
        visited: inout Set<String>,
        into out: inout [ThreadRow]
    ) {
        guard let children = parentToChildren[parentId] else { return }
        for child in children {
            if !visited.insert(child.id).inserted { continue }
            out.append(ThreadRow(event: child, depth: depth, isBlocked: blockedEventIds.contains(child.id)))
            dfs(parentId: child.id, depth: depth + 1, parentToChildren: parentToChildren, visited: &visited, into: &out)
        }
    }
}

struct ThreadRow: Identifiable {
    let event: NostrEvent
    let depth: Int
    var isBlocked: Bool = false
    var id: String { event.id }
}

