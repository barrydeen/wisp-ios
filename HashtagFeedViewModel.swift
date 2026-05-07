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
    @ObservationIgnored private var profileUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var sweepSourceId: UUID?
    @ObservationIgnored private let eventStore = EventStore.shared
    @ObservationIgnored private let profileRepo = ProfileRepository.shared

    private static let searchRelays = [
        "wss://search.nostrarchives.com"
    ]

    init(keypair: Keypair, source: Source) {
        self.keypair = keypair
        self.source = source
    }

    deinit {
        profileUpdatesTask?.cancel()
        if let id = sweepSourceId {
            Task { @MainActor in MissingProfileWatcher.shared.unregisterSource(id) }
        }
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
        ensureProfileUpdatesSubscription()
        guard !isLoading, events.isEmpty else { return }
        await load()
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
                self?.events ?? []
            }
        }
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

        // Seed local cache hits before queueing missing pubkeys with the watcher.
        let pubkeys = Set(events.map(\.pubkey))
        for pk in pubkeys where profiles[pk] == nil {
            if let cached = profileRepo.get(pk) { profiles[pk] = cached }
        }
        MissingProfileWatcher.shared.observe(events)
    }
}
