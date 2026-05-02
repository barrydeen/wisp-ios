import Foundation
import Observation

/// View model for a feed of notes filtered by one or more hashtags.
///
/// Unlike the home feed, hashtag queries don't go through the user's outbox
/// (`RelayScoreBoard`) — that's optimized for the follow graph. Instead we hit
/// `wss://search.nostrarchives.com`, which indexes by `#t` tag.
@Observable
@MainActor
final class HashtagFeedViewModel {

    enum Source: Hashable {
        case single(String)
        case set(HashtagSet)
    }

    let keypair: Keypair
    let source: Source

    var events: [NostrEvent] = []
    var profiles: [String: ProfileData] = [:]
    var isLoading: Bool = false
    var lastError: String?

    @ObservationIgnored private var seenIds: Set<String> = []
    @ObservationIgnored private let eventStore = EventStore.shared
    @ObservationIgnored private let profileRepo = ProfileRepository.shared

    private static let searchRelays = [
        "wss://search.nostrarchives.com"
    ]

    private static let indexerRelays = RelayDefaults.indexers

    init(keypair: Keypair, source: Source) {
        self.keypair = keypair
        self.source = source
    }

    var displayTitle: String {
        switch source {
        case .single(let tag): return "#\(tag)"
        case .set(let set): return set.name
        }
    }

    var hashtags: [String] {
        switch source {
        case .single(let tag):
            return [tag]
        case .set(let set):
            return set.hashtags
        }
    }

    func start() async {
        guard !isLoading, events.isEmpty else { return }
        await load()
    }

    func refresh() async {
        await load()
    }

    private func load() async {
        let tags = hashtags.compactMap(Nip51Hashtags.normalize)
        guard !tags.isEmpty else {
            events = []
            isLoading = false
            return
        }

        isLoading = true
        defer { isLoading = false }

        let filter = NostrFilter(
            kinds: [1],
            tTags: tags,
            limit: 100
        )

        let results = await RelayPool.query(
            relays: Self.searchRelays,
            filter: filter,
            timeout: 10
        )

        var merged = events
        var seen = seenIds
        for event in results where event.kind == 1 {
            if seen.insert(event.id).inserted {
                merged.append(event)
            }
        }
        merged.sort { $0.createdAt > $1.createdAt }

        events = merged
        seenIds = seen

        // Persist (kind 1 is in EventStore.persistedKinds)
        if !results.isEmpty {
            let toPersist = results
            Task { await EventPersistQueue.shared.enqueue(toPersist) }
        }

        await loadMissingProfiles()
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
