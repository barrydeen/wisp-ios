import Foundation
import Observation

/// View model for a feed of notes authored by the members of a `PeopleList`.
///
/// Routing follows the outbox model: members already in the user's `RelayScoreBoard`
/// reuse their scored relays; members not in the scoreboard (i.e. not followed)
/// have their NIP-65 relay lists prefetched on demand and merged in for this query.
@Observable
@MainActor
final class PeopleListFeedViewModel {

    let keypair: Keypair
    private(set) var dTag: String

    var events: [NostrEvent] = []
    var profiles: [String: ProfileData] = [:]
    var isLoading: Bool = false
    var lastError: String?
    var displayTitle: String = ""

    @ObservationIgnored private var seenIds: Set<String> = []
    @ObservationIgnored private let eventStore = EventStore.shared
    @ObservationIgnored private let profileRepo = ProfileRepository.shared
    @ObservationIgnored private let listRepo = PeopleListRepository.shared

    @ObservationIgnored private var loadMoreTask: Task<Void, Never>?

    private static let indexerRelays = RelayDefaults.indexers

    private static let feedKinds = [1, 6, 20]

    /// 7-day lookback for curated lists — Android Wisp uses the same window. Lists
    /// tend to be smaller / less-active than the home follow graph, so a longer
    /// window keeps the feed populated.
    private static let lookbackSeconds = 7 * 24 * 3600

    init(keypair: Keypair, dTag: String) {
        self.keypair = keypair
        self.dTag = dTag
        self.displayTitle = listRepo.list(dTag: dTag)?.name ?? "List"
    }

    func start() async {
        guard !isLoading, events.isEmpty else { return }
        await load(reset: true)
    }

    func refresh() async {
        await load(reset: false)
    }

    func loadMore() {
        guard loadMoreTask == nil else { return }
        guard let oldest = events.last?.createdAt else { return }
        guard let list = listRepo.list(dTag: dTag) else { return }
        let members = list.allMembers
        guard !members.isEmpty else { return }
        loadMoreTask = Task { [weak self] in
            defer { Task { @MainActor in self?.loadMoreTask = nil } }
            await self?.fetchAndMerge(authors: members, since: nil, until: oldest - 1)
        }
    }

    private func load(reset: Bool) async {
        guard let list = listRepo.list(dTag: dTag) else {
            events = []
            isLoading = false
            return
        }
        displayTitle = list.name

        let members = list.allMembers
        guard !members.isEmpty else {
            events = []
            isLoading = false
            return
        }

        isLoading = true
        defer { isLoading = false }

        if reset {
            seenIds = []
            events = []
        }

        let since: Int? = {
            if let newest = events.first?.createdAt { return newest - 60 }
            return Int(Date().timeIntervalSince1970) - Self.lookbackSeconds
        }()

        await fetchAndMerge(authors: members, since: since, until: nil)
        await loadMissingProfiles()
    }

    private func fetchAndMerge(authors: [String], since: Int?, until: Int?) async {
        let scoreBoard = RelayScoreBoard.load(pubkey: keypair.pubkey)
        let memberSet = Set(authors)
        var groups: [(url: String, authors: [String])] = []

        if let board = scoreBoard {
            for relay in board.scoredRelays.prefix(20) {
                let intersect = (board.relayAuthors[relay.url] ?? []).intersection(memberSet)
                guard !intersect.isEmpty else { continue }
                let chunks = Array(intersect).chunked(into: 200)
                for chunk in chunks {
                    groups.append((url: relay.url, authors: chunk))
                }
            }
        }

        // Members not covered by the scoreboard — fall back to indexer relays for them.
        let covered: Set<String> = Set(groups.flatMap(\.authors))
        let uncovered = authors.filter { !covered.contains($0) }
        if !uncovered.isEmpty {
            for chunk in uncovered.chunked(into: 200) {
                for relay in Self.indexerRelays {
                    groups.append((url: relay, authors: chunk))
                }
            }
        }

        let snapshot = groups
        let sinceVal = since
        let untilVal = until
        var collected: [NostrEvent] = []

        await withTaskGroup(of: [NostrEvent].self) { group in
            for entry in snapshot {
                let url = entry.url
                let chunkAuthors = entry.authors
                group.addTask {
                    await RelayPool.query(
                        relays: [url],
                        filter: NostrFilter(
                            kinds: Self.feedKinds,
                            authors: chunkAuthors,
                            limit: 100,
                            since: sinceVal,
                            until: untilVal
                        ),
                        timeout: 10
                    )
                }
            }
            for await batch in group {
                collected.append(contentsOf: batch)
            }
        }

        var added: [NostrEvent] = []
        for event in collected where Self.feedKinds.contains(event.kind) {
            if seenIds.insert(event.id).inserted {
                events.append(event)
                added.append(event)
            }
        }
        events.sort { $0.createdAt > $1.createdAt }

        if !added.isEmpty {
            Task { await EventPersistQueue.shared.enqueue(added) }
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

        var stillMissing: [String] = []
        for pk in needed {
            if let cached = profileRepo.get(pk) {
                profiles[pk] = cached
            } else {
                stillMissing.append(pk)
            }
        }
        guard !stillMissing.isEmpty else { return }

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
}
