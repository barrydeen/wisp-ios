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
    var followersLoaded: Bool = false

    var groups: [SimpleGroup] = []
    var isLoadingGroups: Bool = false
    var groupsLoaded: Bool = false

    var relayList: [RelayConfigEntry] = []
    var isLoadingRelays: Bool = false
    var relaysLoaded: Bool = false

    // Author profile cache for cards (mentions, repost authors, follower rows, etc.)
    var profiles: [String: ProfileData] = [:]

    // Engagement counts keyed by event id
    var engagement: [String: EngagementCounts] = [:]

    @ObservationIgnored private var notesQueryGen = 0
    @ObservationIgnored private var repliesQueryGen = 0
    @ObservationIgnored private var oldestNoteTs: Int?
    @ObservationIgnored private var oldestReplyTs: Int?
    @ObservationIgnored private var targetWriteRelays: [String] = []
    @ObservationIgnored private var hasStarted = false

    @ObservationIgnored private let profileRepo = ProfileRepository.shared
    @ObservationIgnored private let eventStore = EventStore.shared

    private static let indexerRelays = RelayDefaults.indexers

    private static let followersRelay = "wss://feeds.nostrarchives.com/profiles/followers"

    init(pubkey: String, activeUserPubkey: String) {
        self.pubkey = pubkey
        self.activeUserPubkey = activeUserPubkey
        if let cached = profileRepo.get(pubkey) {
            self.profile = cached
            self.profiles[pubkey] = cached
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        let myFollows = FollowsCache.shared.follows(for: activeUserPubkey)
        youFollow = myFollows.contains(pubkey)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in await self?.loadProfileHeader() }
            group.addTask { [weak self] in await self?.loadContacts() }
            group.addTask { [weak self] in await self?.loadTargetWriteRelays() }
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
        defer { if gen == notesQueryGen { isLoadingNotes = false } }

        // Seed from local cache first so the user sees their notes without
        // waiting on the relay round-trip. The relay fetch below merges in
        // anything newer.
        let cached = await eventStore.loadRecentByAuthor(
            pubkey: pubkey,
            kinds: [1, 6, 30023, 20, 21, 22],
            limit: 100
        )
        if gen == notesQueryGen {
            let cachedNotes = cached
                .filter { isRootOrRepost($0) }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(100)
            if !cachedNotes.isEmpty {
                rootNotes = Array(cachedNotes)
                oldestNoteTs = cachedNotes.last?.createdAt
            }
        }

        let events = await fetchAuthorEvents(
            kinds: [1, 6, 30023, 20, 21, 22],
            limit: 100,
            until: nil
        )
        guard gen == notesQueryGen else { return }

        // Merge cached + freshly-fetched, dedupe by id. Relay fetch is the
        // source of truth for ordering once it returns.
        let knownIds = Set(rootNotes.map(\.id))
        let combined = rootNotes + events.filter { !knownIds.contains($0.id) }
        let notes = combined
            .filter { isRootOrRepost($0) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(100)
        rootNotes = Array(notes)
        oldestNoteTs = notes.last?.createdAt
        noNotesAvailable = rootNotes.isEmpty
        await persistKnownKinds(events)
        await subscribeEngagement(for: rootNotes.map(\.id))
    }

    private func loadInitialReplies() async {
        repliesQueryGen += 1
        let gen = repliesQueryGen
        isLoadingReplies = true
        defer { if gen == repliesQueryGen { isLoadingReplies = false } }

        // Cache-seed the same way as loadInitialNotes so replies tab fills
        // instantly when the user has prior history cached.
        let cached = await eventStore.loadRecentByAuthor(pubkey: pubkey, kinds: [1], limit: 100)
        if gen == repliesQueryGen {
            let cachedReplies = cached
                .filter { isReply($0) }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(100)
            if !cachedReplies.isEmpty {
                replies = Array(cachedReplies)
                oldestReplyTs = cachedReplies.last?.createdAt
            }
        }

        let events = await fetchAuthorEvents(kinds: [1], limit: 100, until: nil)
        guard gen == repliesQueryGen else { return }

        let knownIds = Set(replies.map(\.id))
        let combined = replies + events.filter { !knownIds.contains($0.id) }
        let onlyReplies = combined
            .filter { isReply($0) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(100)
        replies = Array(onlyReplies)
        oldestReplyTs = onlyReplies.last?.createdAt
        noRepliesAvailable = replies.isEmpty
        await persistKnownKinds(events)
        await subscribeEngagement(for: replies.map(\.id))
    }

    func loadMoreNotes() async {
        guard notesSortMode == .recency, let until = oldestNoteTs else { return }
        let events = await fetchAuthorEvents(
            kinds: [1, 6, 30023, 20, 21, 22],
            limit: 100,
            until: until - 1
        )
        let knownIds = Set(rootNotes.map(\.id))
        let extra = events.filter { isRootOrRepost($0) && !knownIds.contains($0.id) }
        let merged = (rootNotes + extra).sorted { $0.createdAt > $1.createdAt }
        rootNotes = merged
        oldestNoteTs = merged.last?.createdAt
        await persistKnownKinds(events)
        if !extra.isEmpty { await subscribeEngagement(for: extra.map(\.id)) }
    }

    func loadMoreReplies() async {
        guard repliesSortMode == .recency, let until = oldestReplyTs else { return }
        let events = await fetchAuthorEvents(kinds: [1], limit: 100, until: until - 1)
        let knownIds = Set(replies.map(\.id))
        let extra = events.filter { isReply($0) && !knownIds.contains($0.id) }
        let merged = (replies + extra).sorted { $0.createdAt > $1.createdAt }
        replies = merged
        oldestReplyTs = merged.last?.createdAt
        await persistKnownKinds(events)
        let newIds = extra.map(\.id)
        if !newIds.isEmpty { await subscribeEngagement(for: newIds) }
    }

    // MARK: - Sort modes

    func setNotesSortMode(_ mode: ProfileSortMode) async {
        notesSortMode = mode
        if mode == .recency {
            sortedNotes = []
            return
        }
        notesQueryGen += 1
        let gen = notesQueryGen
        isLoadingSortedNotes = true
        defer { if gen == notesQueryGen { isLoadingSortedNotes = false } }
        sortedNotes = []
        let url = "wss://feeds.nostrarchives.com/profiles/root/\(mode.relaySlug)"
        let events = await RelayPool.query(
            relays: [url],
            filter: NostrFilter(kinds: [1], authors: [pubkey], limit: 100),
            timeout: 12
        )
        guard gen == notesQueryGen else { return }
        sortedNotes = events.filter { $0.kind == 1 || $0.kind == 6 }
        await subscribeEngagement(for: sortedNotes.map(\.id))
    }

    func setRepliesSortMode(_ mode: ProfileSortMode) async {
        repliesSortMode = mode
        if mode == .recency {
            sortedReplies = []
            return
        }
        repliesQueryGen += 1
        let gen = repliesQueryGen
        isLoadingSortedReplies = true
        defer { if gen == repliesQueryGen { isLoadingSortedReplies = false } }
        sortedReplies = []
        let url = "wss://feeds.nostrarchives.com/profiles/replies/\(mode.relaySlug)"
        let events = await RelayPool.query(
            relays: [url],
            filter: NostrFilter(kinds: [1], authors: [pubkey], limit: 100),
            timeout: 12
        )
        guard gen == repliesQueryGen else { return }
        sortedReplies = events.filter { $0.kind == 1 }
        await subscribeEngagement(for: sortedReplies.map(\.id))
    }

    // MARK: - Gallery

    private func loadGallery() async {
        isLoadingGallery = true
        defer { isLoadingGallery = false }
        let events = await fetchAuthorEvents(kinds: [20, 21, 22], limit: 100, until: nil)
        galleryPosts = events
            .filter { [20, 21, 22].contains($0.kind) }
            .sorted { $0.createdAt > $1.createdAt }
        galleryLoaded = true
        await persistKnownKinds(events)
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

    private func loadFollowers() async {
        isLoadingFollowers = true
        defer { isLoadingFollowers = false }

        let events = await RelayPool.query(
            relays: [Self.followersRelay],
            filter: NostrFilter(kinds: [0], pTags: [pubkey], limit: 500),
            timeout: 15
        )

        var seen = Set<String>()
        var profilesOut: [ProfileData] = []
        for e in events where e.kind == 0 && seen.insert(e.pubkey).inserted {
            if let updated = profileRepo.updateFromEvent(e) {
                profiles[e.pubkey] = updated
                profilesOut.append(updated)
            }
        }
        followerProfiles = profilesOut
        followersCount = profilesOut.count
        followersCountIsApprox = false
        followersLoaded = true
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

    // MARK: - Engagement

    private func subscribeEngagement(for ids: [String]) async {
        guard !ids.isEmpty else { return }
        let relays = queryRelays()
        let chunks = ids.chunked(into: 200)
        let kinds = [1, 6, 7, 9735]

        await withTaskGroup(of: [NostrEvent].self) { group in
            for chunk in chunks {
                group.addTask {
                    await RelayPool.query(
                        relays: relays,
                        filter: NostrFilter(kinds: kinds, eTags: chunk, limit: 500),
                        timeout: 10
                    )
                }
            }
            for await batch in group {
                ingestEngagement(batch)
            }
        }
    }

    private func ingestEngagement(_ events: [NostrEvent]) {
        for event in events {
            // First valid `e` tag is the referenced root.
            guard let target = event.tags.first(where: { $0.first == "e" && $0.count >= 2 })?[1] else { continue }
            var current = engagement[target] ?? EngagementCounts()
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
            engagement[target] = current
        }
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
    var zappers: [Zapper] = []
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

    init(pubkey: String, emoji: String, customEmojiUrl: String? = nil) {
        self.pubkey = pubkey
        self.emoji = emoji
        self.customEmojiUrl = customEmojiUrl
    }
}

struct Zapper: Equatable, Hashable {
    let pubkey: String
    let sats: Int64
    let message: String
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
