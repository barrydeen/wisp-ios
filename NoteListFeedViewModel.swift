import Foundation
import Observation

/// View model for a feed of bookmarked notes (a `NoteList`'s contents).
/// Loads cached events from `EventStore` first, then queries indexer + top
/// write relays for any ids that aren't cached.
@Observable
@MainActor
final class NoteListFeedViewModel {

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
    @ObservationIgnored private let listRepo = NoteListRepository.shared

    private static let indexerRelays = RelayDefaults.indexers

    init(keypair: Keypair, dTag: String) {
        self.keypair = keypair
        self.dTag = dTag
        self.displayTitle = listRepo.list(dTag: dTag)?.name ?? "Bookmarks"
    }

    func start() async {
        guard !isLoading, events.isEmpty else { return }
        await load()
    }

    func refresh() async {
        await load()
    }

    private func load() async {
        guard let list = listRepo.list(dTag: dTag) else {
            events = []
            isLoading = false
            return
        }
        displayTitle = list.name

        let ids = list.allNotes
        guard !ids.isEmpty else {
            events = []
            isLoading = false
            return
        }

        isLoading = true
        defer { isLoading = false }

        // Seed from cache for instant display.
        let cached = await eventStore.eventsByIds(ids)
        for event in cached {
            if seenIds.insert(event.id).inserted {
                events.append(event)
            }
        }
        events.sort { $0.createdAt > $1.createdAt }

        let cachedSet = Set(cached.map(\.id))
        let missing = ids.filter { !cachedSet.contains($0) }

        let writeRelays = topWriteRelays(pubkey: keypair.pubkey)
        let queryRelays = Array(Set(writeRelays + Self.indexerRelays))

        // Query in batches — many relays cap `ids` filter sizes around 200-500.
        var fetched: [NostrEvent] = []
        for batch in missing.chunked(into: 200) {
            let results = await RelayPool.query(
                relays: queryRelays,
                filter: NostrFilter(ids: batch, limit: batch.count),
                timeout: 10
            )
            fetched.append(contentsOf: results)
        }

        var added: [NostrEvent] = []
        for event in fetched {
            if seenIds.insert(event.id).inserted {
                events.append(event)
                added.append(event)
            }
        }
        events.sort { $0.createdAt > $1.createdAt }

        if !added.isEmpty {
            Task { await EventPersistQueue.shared.enqueue(added) }
        }

        await loadMissingProfiles()
    }

    private func topWriteRelays(pubkey: String) -> [String] {
        if let board = RelayScoreBoard.load(pubkey: pubkey) {
            let top = board.scoredRelays.prefix(10).map(\.url)
            if !top.isEmpty { return top }
        }
        return ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
    }

    private func loadMissingProfiles() async {
        var needed = Set(events.map(\.pubkey)).filter { profiles[$0] == nil }
        guard !needed.isEmpty else { return }

        var stillMissing: [String] = []
        for pk in needed {
            if let cached = profileRepo.get(pk) {
                profiles[pk] = cached
            } else {
                stillMissing.append(pk)
            }
        }
        needed.removeAll()
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
