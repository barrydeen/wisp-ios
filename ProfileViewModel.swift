import Foundation
import Observation

@Observable
@MainActor
final class ProfileViewModel {
    let pubkey: String
    let activeUserPubkey: String

    // Header
    var profile: ProfileData?
    var followsYou: Bool = false
    var youFollow: Bool = false
    var followingCount: Int = 0
    var followersCount: Int = 0
    var followersCountIsApprox: Bool = true

    // Notes / Replies
    var rootNotes: [NostrEvent] = []
    var replies: [NostrEvent] = []
    var sortedNotes: [NostrEvent] = []
    var sortedReplies: [NostrEvent] = []
    var notesSortMode: ProfileSortMode = .recency
    var repliesSortMode: ProfileSortMode = .recency
    /// Init `true` so the Notes/Replies tabs render their loading placeholder
    /// from the moment the profile opens — without this the brief window
    /// between view appearance and `start()` kicking off the fetch flashed
    /// the "No notes yet" empty state at users with slow relays.
    var isLoadingNotes: Bool = true
    var isLoadingReplies: Bool = true
    var isLoadingSortedNotes: Bool = false
    var isLoadingSortedReplies: Bool = false
    var noNotesAvailable: Bool = false
    var noRepliesAvailable: Bool = false

    // Other tabs
    var galleryPosts: [NostrEvent] = []
    var isLoadingGallery: Bool = false
    var galleryLoaded: Bool = false

    var followingPubkeys: [String] = []
    var followingProfiles: [ProfileData] = []
    var isLoadingFollowing: Bool = false
    var followingLoaded: Bool = false

    var followerProfiles: [ProfileData] = []
    var isLoadingFollowers: Bool = false
    var isLoadingMoreFollowers: Bool = false
    var followersHasMore: Bool = false
    var followersLoaded: Bool = false

    var groups: [SimpleGroup] = []
    var isLoadingGroups: Bool = false
    var groupsLoaded: Bool = false

    var relayList: [RelayConfigEntry] = []
    var isLoadingRelays: Bool = false
    var relaysLoaded: Bool = false

    // Public conversation shared between the active user and this profile.
    var conversationNotes: [NostrEvent] = []
    var isLoadingConversation: Bool = false
    var conversationLoaded: Bool = false

    // Author profile cache for cards (mentions, repost authors, follower rows, etc.)
    var profiles: [String: ProfileData] = [:]

    @ObservationIgnored private var notesQueryGen = 0
    @ObservationIgnored private var repliesQueryGen = 0
    @ObservationIgnored private var oldestNoteTs: Int?
    @ObservationIgnored private var oldestReplyTs: Int?
    @ObservationIgnored private var targetWriteRelays: [String] = []
    @ObservationIgnored private var hasStarted = false

    // Streaming buffers — mirror FeedViewModel.enqueueLiveEvent /
    // flushPendingInserts. Per-tab buffers keep a mid-flight flush from
    // crossing tab boundaries.
    @ObservationIgnored private var notesPending: [NostrEvent] = []
    @ObservationIgnored private var notesFlushScheduled = false
    @ObservationIgnored private var notesStreamTask: Task<Void, Never>?

    @ObservationIgnored private var repliesPending: [NostrEvent] = []
    @ObservationIgnored private var repliesFlushScheduled = false
    @ObservationIgnored private var repliesStreamTask: Task<Void, Never>?

    @ObservationIgnored private var galleryPending: [NostrEvent] = []
    @ObservationIgnored private var galleryFlushScheduled = false
    @ObservationIgnored private var galleryStreamTask: Task<Void, Never>?

    @ObservationIgnored private var followersOffset = 0
    @ObservationIgnored private var sortedNotesStreamTask: Task<Void, Never>?
    @ObservationIgnored private var sortedRepliesStreamTask: Task<Void, Never>?

    private static let liveFlushDelayMs: UInt64 = 60

    @ObservationIgnored private let profileRepo = ProfileRepository.shared
    @ObservationIgnored private let eventStore = EventStore.shared
    @ObservationIgnored private var safetyObserver: NSObjectProtocol?
    @ObservationIgnored private var followsObserver: NSObjectProtocol?

    private static let indexerRelays = RelayDefaults.indexers

    init(pubkey: String, activeUserPubkey: String) {
        self.pubkey = pubkey
        self.activeUserPubkey = activeUserPubkey
        if let cached = profileRepo.get(pubkey) {
            self.profile = cached
            self.profiles[pubkey] = cached
        }
        // Re-filter on safety-snapshot installs (WoT toggle / recompute) so an
        // open profile's already-loaded notes vanish the moment the filter
        // tightens — same contract as the feed and thread observers. The
        // ingest paths all gate on `shouldDrop(.feed)`, so this only has to
        // scrub what was loaded under looser rules.
        followsObserver = NotificationCenter.default.addObserver(
            forName: .followsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            youFollow = FollowsCache.shared.followsSet(for: activeUserPubkey).contains(pubkey)
        }
        safetyObserver = NotificationCenter.default.addObserver(
            forName: .safetyFilterChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard SafetyFilter.shared.snapshot.wotEnabled else { return }
                let drop: (NostrEvent) -> Bool = {
                    SafetyFilter.shared.shouldDrop(event: $0, context: .feed)
                }
                rootNotes.removeAll(where: drop)
                replies.removeAll(where: drop)
                sortedNotes.removeAll(where: drop)
                sortedReplies.removeAll(where: drop)
            }
        }
    }

    deinit {
        if let followsObserver { NotificationCenter.default.removeObserver(followsObserver) }
        if let safetyObserver { NotificationCenter.default.removeObserver(safetyObserver) }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        // Drop this pubkey from the watcher's exhausted set so explicit profile
        // navigation re-tries even after a prior batched fetch came up empty.
        // Result is fire-and-forget: `loadProfileHeader` below covers the UI
        // path; `forceFetch` only resets negative-cache state.
        let target = pubkey
        Task { _ = await MissingProfileWatcher.shared.forceFetch(target) }

        let myFollows = FollowsCache.shared.follows(for: activeUserPubkey)
        youFollow = myFollows.contains(pubkey)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in await self?.loadProfileHeader() }
            group.addTask { [weak self] in await self?.loadContacts() }
            group.addTask { [weak self] in await self?.loadTargetWriteRelays() }
            group.addTask { [weak self] in await self?.loadFollowerCount() }
        }

        // Now that we know the target's write relays, load notes/replies in parallel
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in await self?.loadInitialNotes() }
            group.addTask { [weak self] in await self?.loadInitialReplies() }
        }
    }

    func loadTab(_ tab: ProfileTab) async {
        switch tab {
        case .notes, .replies, .media:
            return  // Notes/replies always loaded; media derives from them.
        case .gallery:
            if !galleryLoaded { await loadGallery() }
        case .following:
            if !followingLoaded { await loadFollowingProfiles() }
        case .followers:
            if !followersLoaded { await loadFollowers() }
        case .groups:
            if !groupsLoaded { await loadGroups() }
        case .relays:
            if !relaysLoaded { await loadRelayList() }
        case .conversation:
            if !conversationLoaded { await loadConversation() }
        }
    }

    // MARK: - Header

    private func loadProfileHeader() async {
        let results = await RelayPool.query(
            relays: Self.indexerRelays,
            filter: NostrFilter(kinds: [0], authors: [pubkey], limit: 5),
            timeout: 8
        )
        if let best = results.filter({ $0.kind == 0 }).max(by: { $0.createdAt < $1.createdAt }),
           let updated = profileRepo.updateFromEvent(best) {
            profile = updated
            profiles[pubkey] = updated
            await loadAboutMentionProfiles(from: updated.about ?? "")
        }
    }

    private func loadAboutMentionProfiles(from about: String) async {
        let referenced = Self.extractProfilePubkeys(in: about)
        let missing = referenced.filter { profiles[$0] == nil }
        guard !missing.isEmpty else { return }
        let fetched = await fetchProfilesFromIndexers(missing)
        for (k, v) in fetched { profiles[k] = v }
    }

    private static func extractProfilePubkeys(in s: String) -> [String] {
        let pattern = "nostr:(npub1[a-z0-9]+|nprofile1[a-z0-9]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        var seen = Set<String>()
        var out: [String] = []
        regex.enumerateMatches(in: s, range: range) { match, _, _ in
            guard let m = match, let r = Range(m.range, in: s) else { return }
            let token = String(s[r])
            if case .profileRef(let pk, _)? = Nip19.decodeNostrUri(token), seen.insert(pk).inserted {
                out.append(pk)
            }
        }
        return out
    }

    private func loadContacts() async {
        let relays = queryRelays()
        let results = await RelayPool.query(
            relays: relays,
            filter: NostrFilter(kinds: [3], authors: [pubkey], limit: 1),
            timeout: 10
        )
        guard let best = results.filter({ $0.kind == 3 }).max(by: { $0.createdAt < $1.createdAt }) else { return }
        let pubkeys = best.tags.compactMap { tag -> String? in
            tag.count >= 2 && tag[0] == "p" ? tag[1] : nil
        }
        followingPubkeys = pubkeys
        followingCount = pubkeys.count
        // Their contact list p-tags the active user → they follow us.
        followsYou = pubkeys.contains(activeUserPubkey)
    }

    private func loadTargetWriteRelays() async {
        let results = await RelayPool.query(
            relays: Self.indexerRelays,
            filter: NostrFilter(kinds: [10002], authors: [pubkey], limit: 1),
            timeout: 8
        )
        guard let best = results.filter({ $0.kind == 10002 }).max(by: { $0.createdAt < $1.createdAt }) else { return }
        let writes = best.tags.compactMap { tag -> String? in
            guard tag.count >= 2, tag[0] == "r" else { return nil }
            if tag.count == 2 || tag[2] == "write" { return tag[1] }
            return nil
        }
        targetWriteRelays = writes
    }

    // MARK: - Notes (recency)

    private func loadInitialNotes() async {
        notesQueryGen += 1
        let gen = notesQueryGen
        isLoadingNotes = true
        notesStreamTask?.cancel()

        // Seed from local cache first so the user sees their notes without
        // waiting on the relay round-trip. The stream below merges in
        // anything newer as it arrives.
        let cached = await eventStore.loadRecentByAuthor(
            pubkey: pubkey,
            kinds: [1, 6, 30023, 20, 21, 22],
            limit: 100
        )
        if gen == notesQueryGen {
            let cachedNotes = cached
                .filter { isRootOrRepost($0) && !SafetyFilter.shared.shouldDrop(event: $0, context: .feed) }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(100)
            if !cachedNotes.isEmpty {
                rootNotes = Array(cachedNotes)
                oldestNoteTs = cachedNotes.last?.createdAt
            }
        }

        let relays = queryRelays()
        let filter = NostrFilter(kinds: [1, 6, 30023, 20, 21, 22], authors: [pubkey], limit: 100)
        let queries = relays.map { RelayQuery(relayUrl: $0, filter: filter) }
        let cancelGen = gen

        notesStreamTask = Task { [weak self] in
            guard let self else { return }
            var seen = Set(self.rootNotes.map(\.id))
            for await (event, _) in RelayPool.stream(queries: queries, timeout: 12) {
                if Task.isCancelled || cancelGen != self.notesQueryGen { return }
                if SafetyFilter.shared.shouldDrop(event: event, context: .feed) { continue }
                guard self.isRootOrRepost(event), seen.insert(event.id).inserted else { continue }
                self.enqueueNote(event)
            }
            guard cancelGen == self.notesQueryGen else { return }
            self.flushNotesPending()
            self.isLoadingNotes = false
            self.noNotesAvailable = self.rootNotes.isEmpty
        }
    }

    private func enqueueNote(_ event: NostrEvent) {
        notesPending.append(event)
        if isLoadingNotes { isLoadingNotes = false }
        guard !notesFlushScheduled else { return }
        notesFlushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.liveFlushDelayMs))
            await self?.flushNotesPending()
        }
    }

    private func flushNotesPending() {
        notesFlushScheduled = false
        let batch = notesPending
        notesPending.removeAll(keepingCapacity: true)
        guard !batch.isEmpty else { return }
        let sortedBatch = batch.sorted { $0.createdAt > $1.createdAt }
        rootNotes = Array(FeedViewModel.mergeSortedDesc(rootNotes, sortedBatch).prefix(100))
        oldestNoteTs = rootNotes.last?.createdAt
        Task { await EventPersistQueue.shared.enqueue(batch) }
    }

    private func loadInitialReplies() async {
        repliesQueryGen += 1
        let gen = repliesQueryGen
        isLoadingReplies = true
        repliesStreamTask?.cancel()

        // Cache-seed the same way as loadInitialNotes so replies tab fills
        // instantly when the user has prior history cached.
        let cached = await eventStore.loadRecentByAuthor(pubkey: pubkey, kinds: [1], limit: 100)
        if gen == repliesQueryGen {
            let cachedReplies = cached
                .filter { isReply($0) && !SafetyFilter.shared.shouldDrop(event: $0, context: .feed) }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(100)
            if !cachedReplies.isEmpty {
                replies = Array(cachedReplies)
                oldestReplyTs = cachedReplies.last?.createdAt
            }
        }

        let relays = queryRelays()
        let filter = NostrFilter(kinds: [1], authors: [pubkey], limit: 100)
        let queries = relays.map { RelayQuery(relayUrl: $0, filter: filter) }
        let cancelGen = gen

        repliesStreamTask = Task { [weak self] in
            guard let self else { return }
            var seen = Set(self.replies.map(\.id))
            for await (event, _) in RelayPool.stream(queries: queries, timeout: 12) {
                if Task.isCancelled || cancelGen != self.repliesQueryGen { return }
                if SafetyFilter.shared.shouldDrop(event: event, context: .feed) { continue }
                guard self.isReply(event), seen.insert(event.id).inserted else { continue }
                self.enqueueReply(event)
            }
            guard cancelGen == self.repliesQueryGen else { return }
            self.flushRepliesPending()
            self.isLoadingReplies = false
            self.noRepliesAvailable = self.replies.isEmpty
        }
    }

    private func enqueueReply(_ event: NostrEvent) {
        repliesPending.append(event)
        if isLoadingReplies { isLoadingReplies = false }
        guard !repliesFlushScheduled else { return }
        repliesFlushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.liveFlushDelayMs))
            await self?.flushRepliesPending()
        }
    }

    private func flushRepliesPending() {
        repliesFlushScheduled = false
        let batch = repliesPending
        repliesPending.removeAll(keepingCapacity: true)
        guard !batch.isEmpty else { return }
        let sortedBatch = batch.sorted { $0.createdAt > $1.createdAt }
        replies = Array(FeedViewModel.mergeSortedDesc(replies, sortedBatch).prefix(100))
        oldestReplyTs = replies.last?.createdAt
        Task { await EventPersistQueue.shared.enqueue(batch) }
    }

    func loadMoreNotes() async {
        guard notesSortMode == .recency, let until = oldestNoteTs else { return }
        let events = await fetchAuthorEvents(
            kinds: [1, 6, 30023, 20, 21, 22],
            limit: 100,
            until: until - 1
        )
        let knownIds = Set(rootNotes.map(\.id))
        let extra = events.filter {
            isRootOrRepost($0)
            && !knownIds.contains($0.id)
            && !SafetyFilter.shared.shouldDrop(event: $0, context: .feed)
        }
        let merged = (rootNotes + extra).sorted { $0.createdAt > $1.createdAt }
        rootNotes = merged
        oldestNoteTs = merged.last?.createdAt
        await persistKnownKinds(events)
    }

    func loadMoreReplies() async {
        guard repliesSortMode == .recency, let until = oldestReplyTs else { return }
        let events = await fetchAuthorEvents(kinds: [1], limit: 100, until: until - 1)
        let knownIds = Set(replies.map(\.id))
        let extra = events.filter {
            isReply($0)
            && !knownIds.contains($0.id)
            && !SafetyFilter.shared.shouldDrop(event: $0, context: .feed)
        }
        let merged = (replies + extra).sorted { $0.createdAt > $1.createdAt }
        replies = merged
        oldestReplyTs = merged.last?.createdAt
        await persistKnownKinds(events)
    }

    // MARK: - Sort modes

    func setNotesSortMode(_ mode: ProfileSortMode) async {
        notesSortMode = mode
        sortedNotesStreamTask?.cancel()
        if mode == .recency {
            sortedNotes = []
            return
        }
        notesQueryGen += 1
        let gen = notesQueryGen
        isLoadingSortedNotes = true
        sortedNotes = []
        let url = "wss://feeds.nostrarchives.com/profiles/root/\(mode.relaySlug)"
        let queries = [RelayQuery(
            relayUrl: url,
            filter: NostrFilter(kinds: [1], authors: [pubkey], limit: 100)
        )]

        // Curated relay returns events in sort order — preserve it by
        // appending per-event without the recency-tab debounce.
        sortedNotesStreamTask = Task { [weak self] in
            guard let self else { return }
            var seen = Set<String>()
            for await (event, _) in RelayPool.stream(queries: queries, timeout: 12) {
                guard gen == self.notesQueryGen else { return }
                if SafetyFilter.shared.shouldDrop(event: event, context: .feed) { continue }
                guard event.kind == 1 || event.kind == 6, seen.insert(event.id).inserted else { continue }
                self.sortedNotes.append(event)
                if self.isLoadingSortedNotes { self.isLoadingSortedNotes = false }
            }
            guard gen == self.notesQueryGen else { return }
            self.isLoadingSortedNotes = false
        }
    }

    func setRepliesSortMode(_ mode: ProfileSortMode) async {
        repliesSortMode = mode
        sortedRepliesStreamTask?.cancel()
        if mode == .recency {
            sortedReplies = []
            return
        }
        repliesQueryGen += 1
        let gen = repliesQueryGen
        isLoadingSortedReplies = true
        sortedReplies = []
        let url = "wss://feeds.nostrarchives.com/profiles/replies/\(mode.relaySlug)"
        let queries = [RelayQuery(
            relayUrl: url,
            filter: NostrFilter(kinds: [1], authors: [pubkey], limit: 100)
        )]

        sortedRepliesStreamTask = Task { [weak self] in
            guard let self else { return }
            var seen = Set<String>()
            for await (event, _) in RelayPool.stream(queries: queries, timeout: 12) {
                guard gen == self.repliesQueryGen else { return }
                if SafetyFilter.shared.shouldDrop(event: event, context: .feed) { continue }
                guard event.kind == 1, seen.insert(event.id).inserted else { continue }
                self.sortedReplies.append(event)
                if self.isLoadingSortedReplies { self.isLoadingSortedReplies = false }
            }
            guard gen == self.repliesQueryGen else { return }
            self.isLoadingSortedReplies = false
        }
    }

    // MARK: - Gallery

    private func loadGallery() async {
        galleryStreamTask?.cancel()
        isLoadingGallery = true

        let relays = queryRelays()
        let filter = NostrFilter(kinds: [20, 21, 22], authors: [pubkey], limit: 100)
        let queries = relays.map { RelayQuery(relayUrl: $0, filter: filter) }

        galleryStreamTask = Task { [weak self] in
            guard let self else { return }
            var seen = Set(self.galleryPosts.map(\.id))
            for await (event, _) in RelayPool.stream(queries: queries, timeout: 12) {
                if Task.isCancelled { return }
                if SafetyFilter.shared.shouldDrop(event: event, context: .feed) { continue }
                guard [20, 21, 22].contains(event.kind), seen.insert(event.id).inserted else { continue }
                self.enqueueGallery(event)
            }
            self.flushGalleryPending()
            self.isLoadingGallery = false
            self.galleryLoaded = true
        }
    }

    private func enqueueGallery(_ event: NostrEvent) {
        galleryPending.append(event)
        if isLoadingGallery { isLoadingGallery = false }
        guard !galleryFlushScheduled else { return }
        galleryFlushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.liveFlushDelayMs))
            await self?.flushGalleryPending()
        }
    }

    private func flushGalleryPending() {
        galleryFlushScheduled = false
        let batch = galleryPending
        galleryPending.removeAll(keepingCapacity: true)
        guard !batch.isEmpty else { return }
        let sortedBatch = batch.sorted { $0.createdAt > $1.createdAt }
        galleryPosts = FeedViewModel.mergeSortedDesc(galleryPosts, sortedBatch)
        Task { await EventPersistQueue.shared.enqueue(batch) }
    }

    // MARK: - Following

    private func loadFollowingProfiles() async {
        isLoadingFollowing = true
        defer { isLoadingFollowing = false }

        // Make sure contacts have been resolved at least once.
        if followingPubkeys.isEmpty { await loadContacts() }
        let pubkeys = followingPubkeys
        guard !pubkeys.isEmpty else {
            followingProfiles = []
            followingLoaded = true
            return
        }

        var local = profileRepo.getAll(pubkeys)
        let missing = pubkeys.filter { local[$0] == nil }

        if !missing.isEmpty {
            let fetched = await fetchProfilesFromIndexers(missing)
            for (k, v) in fetched { local[k] = v }
        }

        for (k, v) in local { profiles[k] = v }

        // Preserve original follow order.
        followingProfiles = pubkeys.compactMap { local[$0] ?? ProfileData(pubkey: $0) }
        followingLoaded = true
    }

    // MARK: - Followers

    /// Cheap count-only fetch run from `start()` so the header shows the real
    /// follower total the moment the profile opens — without it the bio sat at
    /// the `∞` placeholder until the Followers tab was opened.
    private func loadFollowerCount() async {
        guard let social = try? await NostrArchivesClient.social(
            pubkey: pubkey, followersLimit: 1
        ) else { return }
        followersCount = social.followers.count
        followersCountIsApprox = false
    }

    private func loadFollowers() async {
        isLoadingFollowers = true
        followerProfiles = []
        followersOffset = 0

        guard let social = try? await NostrArchivesClient.social(
            pubkey: pubkey, followersLimit: 100, followersOffset: 0
        ) else {
            isLoadingFollowers = false
            followersLoaded = true
            return
        }

        followersCount = social.followers.count
        followersCountIsApprox = false

        let pubkeys = social.followers.pubkeys
        followerProfiles = await resolveFollowerProfiles(pubkeys)
        followersOffset = pubkeys.count
        followersHasMore = followerProfiles.count < followersCount
        followersLoaded = true
        isLoadingFollowers = false
    }

    func loadMoreFollowers() async {
        guard followersHasMore, !isLoadingMoreFollowers else { return }
        isLoadingMoreFollowers = true
        defer { isLoadingMoreFollowers = false }

        guard let social = try? await NostrArchivesClient.social(
            pubkey: pubkey, followersLimit: 100, followersOffset: followersOffset
        ) else {
            followersHasMore = false
            return
        }

        let page = social.followers.pubkeys
        followersOffset += page.count

        let known = Set(followerProfiles.map(\.pubkey))
        let fresh = page.filter { !known.contains($0) }
        followerProfiles.append(contentsOf: await resolveFollowerProfiles(fresh))
        // Stop when the API stops handing back new rows, even if the reported
        // total hasn't been reached (deleted/duplicate pubkeys can leave a gap).
        followersHasMore = !page.isEmpty && followerProfiles.count < social.followers.count
    }

    /// Resolve follower hex pubkeys into profile rows, preserving the API's
    /// (relevance) order. Mirrors `loadFollowingProfiles`: local cache first,
    /// then a batched indexer fetch for the rest, with a bare-pubkey fallback
    /// row for anyone still unresolved. Also warms `self.profiles` for avatars.
    private func resolveFollowerProfiles(_ pubkeys: [String]) async -> [ProfileData] {
        guard !pubkeys.isEmpty else { return [] }
        var local = profileRepo.getAll(pubkeys)
        let missing = pubkeys.filter { local[$0] == nil }
        if !missing.isEmpty {
            let fetched = await fetchProfilesFromIndexers(missing)
            for (k, v) in fetched { local[k] = v }
        }
        for (k, v) in local { profiles[k] = v }
        return pubkeys.compactMap { local[$0] ?? ProfileData(pubkey: $0) }
    }

    // MARK: - Groups

    private func loadGroups() async {
        isLoadingGroups = true
        defer { isLoadingGroups = false }

        let relays = queryRelays()
        let results = await RelayPool.query(
            relays: relays,
            filter: NostrFilter(kinds: [10009], authors: [pubkey], limit: 1),
            timeout: 10
        )
        guard let best = results.filter({ $0.kind == 10009 }).max(by: { $0.createdAt < $1.createdAt }) else {
            groups = []
            groupsLoaded = true
            return
        }
        var out: [SimpleGroup] = []
        for tag in best.tags {
            guard tag.first == "group", tag.count >= 3 else { continue }
            let groupId = tag[1]
            let relayUrl = tag[2]
            let lower = relayUrl.lowercased()
            guard lower.hasPrefix("wss://") || lower.hasPrefix("ws://") else { continue }
            let name = tag.count >= 4 ? tag[3] : nil
            out.append(SimpleGroup(groupId: groupId, relayUrl: relayUrl, name: name))
        }
        groups = out
        groupsLoaded = true
    }

    // MARK: - Relay list

    private func loadRelayList() async {
        isLoadingRelays = true
        defer { isLoadingRelays = false }

        let relays = queryRelays()
        let results = await RelayPool.query(
            relays: relays,
            filter: NostrFilter(kinds: [10002], authors: [pubkey], limit: 1),
            timeout: 10
        )
        guard let best = results.filter({ $0.kind == 10002 }).max(by: { $0.createdAt < $1.createdAt }) else {
            relayList = []
            relaysLoaded = true
            return
        }
        var entries: [RelayConfigEntry] = []
        for tag in best.tags {
            guard tag.first == "r", tag.count >= 2 else { continue }
            let url = tag[1]
            let marker = tag.count >= 3 ? tag[2].lowercased() : ""
            let read: Bool
            let write: Bool
            switch marker {
            case "read": read = true; write = false
            case "write": read = false; write = true
            default: read = true; write = true
            }
            entries.append(RelayConfigEntry(url: url, read: read, write: write))
        }
        relayList = entries
        relaysLoaded = true
    }

    // MARK: - Shared conversation

    /// Public back-and-forth between the active user and this profile: kind-1
    /// notes authored by this profile that p-tag the active user, plus notes
    /// authored by the active user that p-tag this profile. Tapping a row
    /// opens the full thread, same as the Notes/Replies tabs.
    private func loadConversation() async {
        isLoadingConversation = true
        defer {
            isLoadingConversation = false
            conversationLoaded = true
        }

        // No conversation with yourself. The tab isn't shown on the own
        // profile, but guard anyway so a stray call returns cleanly.
        guard pubkey != activeUserPubkey else {
            conversationNotes = []
            return
        }

        let relays = queryRelays()
        let theirs = NostrFilter(kinds: [1], authors: [pubkey], pTags: [activeUserPubkey], limit: 100)
        let mine = NostrFilter(kinds: [1], authors: [activeUserPubkey], pTags: [pubkey], limit: 100)

        var collected: [NostrEvent] = []
        await withTaskGroup(of: [NostrEvent].self) { group in
            group.addTask { await RelayPool.query(relays: relays, filter: theirs, timeout: 12) }
            group.addTask { await RelayPool.query(relays: relays, filter: mine, timeout: 12) }
            for await batch in group {
                collected.append(contentsOf: batch)
            }
        }

        var byId: [String: NostrEvent] = [:]
        for event in collected where event.kind == 1 {
            byId[event.id] = event
        }
        conversationNotes = byId.values.sorted { $0.createdAt > $1.createdAt }

        // PostCardView needs both authors' profiles for the avatar/name. This
        // profile is already cached; backfill the active user's if missing.
        let missing = [pubkey, activeUserPubkey].filter { profiles[$0] == nil }
        for pk in missing {
            if let cached = profileRepo.get(pk) { profiles[pk] = cached }
        }
        let stillMissing = missing.filter { profiles[$0] == nil }
        if !stillMissing.isEmpty {
            let fetched = await fetchProfilesFromIndexers(stillMissing)
            for (k, v) in fetched { profiles[k] = v }
        }

        await persistKnownKinds(conversationNotes)
    }

    // MARK: - Media derivation

    /// Derived list of every image/video URL across notes + replies (recency lists),
    /// newest first. Used by the Media tab.
    func mediaItems() -> [MediaItem] {
        var seen = Set<String>()
        var items: [MediaItem] = []
        let combined = (rootNotes + replies).sorted { $0.createdAt > $1.createdAt }
        for event in combined {
            // Repost? Use inner event for media extraction.
            let target: NostrEvent
            if event.kind == 6, !event.content.isEmpty,
               let data = event.content.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let inner = NostrEvent(json: json) {
                target = inner
            } else {
                target = event
            }
            for seg in ContentParser.parse(content: target.content, tags: target.tags) {
                switch seg {
                case .image(let m), .unknownMedia(let m):
                    if seen.insert(m.url).inserted {
                        items.append(MediaItem(url: m.url, isVideo: false, sourceEventId: target.id))
                    }
                case .video(let m):
                    if seen.insert(m.url).inserted {
                        items.append(MediaItem(url: m.url, isVideo: true, sourceEventId: target.id))
                    }
                default: break
                }
            }
        }
        return items
    }

    // MARK: - Helpers

    private func fetchAuthorEvents(kinds: [Int], limit: Int, until: Int?) async -> [NostrEvent] {
        let relays = queryRelays()
        let filter = NostrFilter(kinds: kinds, authors: [pubkey], limit: limit, until: until)
        return await RelayPool.query(relays: relays, filter: filter, timeout: 12)
    }

    private func fetchProfilesFromIndexers(_ pubkeys: [String]) async -> [String: ProfileData] {
        var out: [String: ProfileData] = [:]
        for batch in pubkeys.chunked(into: 150) {
            let results = await RelayPool.query(
                relays: Self.indexerRelays,
                filter: NostrFilter(kinds: [0], authors: batch),
                timeout: 12
            )
            var bestByAuthor: [String: NostrEvent] = [:]
            for event in results where event.kind == 0 {
                if let existing = bestByAuthor[event.pubkey], event.createdAt <= existing.createdAt { continue }
                bestByAuthor[event.pubkey] = event
            }
            for (_, event) in bestByAuthor {
                if let profile = profileRepo.updateFromEvent(event) {
                    out[event.pubkey] = profile
                }
            }
        }
        return out
    }

    private func queryRelays() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        if let board = RelayScoreBoard.load(pubkey: activeUserPubkey) {
            for relay in board.scoredRelays.prefix(20) where seen.insert(relay.url).inserted {
                ordered.append(relay.url)
            }
        }
        for url in targetWriteRelays where seen.insert(url).inserted {
            ordered.append(url)
        }
        for url in Self.indexerRelays where seen.insert(url).inserted {
            ordered.append(url)
        }
        return ordered
    }

    private func isRootOrRepost(_ event: NostrEvent) -> Bool {
        guard event.pubkey == pubkey else { return false }
        if event.kind == 6 || [20, 21, 22, 30023].contains(event.kind) { return true }
        return event.kind == 1 && !event.tags.contains { $0.first == "e" }
    }

    private func isReply(_ event: NostrEvent) -> Bool {
        guard event.pubkey == pubkey, event.kind == 1 else { return false }
        return event.tags.contains { $0.first == "e" }
    }

    private func persistKnownKinds(_ events: [NostrEvent]) async {
        guard !events.isEmpty else { return }
        await eventStore.persist(events)
    }
}

// MARK: - Supporting types

enum ProfileSortMode: String, CaseIterable {
    case recency
    case likes
    case replies
    case zaps
    case reposts

    var label: String {
        switch self {
        case .recency: return "Recent"
        case .likes: return "Most liked"
        case .replies: return "Most replied"
        case .zaps: return "Most zapped"
        case .reposts: return "Most reposted"
        }
    }

    /// Slug used in the feeds.nostrarchives.com URL path.
    var relaySlug: String {
        switch self {
        case .recency: return ""
        case .likes: return "likes"
        case .replies: return "replies"
        case .zaps: return "zaps"
        case .reposts: return "reposts"
        }
    }
}

struct EngagementCounts: Equatable {
    var replies: Int = 0
    var reactions: Int = 0
    var reposts: Int = 0
    var zapSats: Int64 = 0
    var zapCount: Int = 0
    var reactors: [Reactor] = []
    var reposters: [String] = []
    /// Maps reposter pubkey → kind-6 event ID. Populated from both optimistic
    /// reposts and ingested kind-6 events. Used by undo (NIP-09 deletion).
    var reposterEventIds: [String: String] = [:]
    var zappers: [Zapper] = []
    /// Kind-1 events that reference this note via a NIP-18 `q` tag — i.e.
    /// posts that quoted it. Each row knows the quote event's id so the
    /// note-details drawer can navigate to the quote post itself, not just
    /// to the quoter's profile.
    var quoters: [Quoter] = []
    var seenRelays: Set<String> = []
}

struct Reactor: Equatable, Hashable {
    let pubkey: String
    /// Reaction content. Either a Unicode emoji like "🔥", the legacy NIP-25
    /// `+`/`-`, or a NIP-30 `:shortcode:` reference resolved against
    /// `customEmojiUrl`.
    let emoji: String
    /// URL of the custom emoji image when `emoji` is a `:shortcode:` reference,
    /// extracted from the kind-7 reaction event's NIP-30 `emoji` tag. Nil for
    /// plain Unicode reactions.
    let customEmojiUrl: String?
    /// The event ID of the kind-7 reaction, populated once the event is signed
    /// (for optimistic reactions) or ingested from a relay. Used for undo (NIP-09
    /// deletion).
    let reactionEventId: String?

    init(pubkey: String, emoji: String, customEmojiUrl: String? = nil, reactionEventId: String? = nil) {
        self.pubkey = pubkey
        self.emoji = emoji
        self.customEmojiUrl = customEmojiUrl
        self.reactionEventId = reactionEventId
    }
}

struct Zapper: Equatable, Hashable {
    let pubkey: String
    let sats: Int64
    let message: String
}

struct Quoter: Equatable, Hashable {
    /// The quote post's own event id — used to navigate to it on tap.
    let eventId: String
    /// Author of the quote post (avatar in the details drawer).
    let pubkey: String
    let createdAt: Int
}

struct MediaItem: Hashable {
    let url: String
    let isVideo: Bool
    let sourceEventId: String
}

struct SimpleGroup: Hashable {
    let groupId: String
    let relayUrl: String
    let name: String?
}

struct RelayConfigEntry: Hashable {
    let url: String
    let read: Bool
    let write: Bool
}
