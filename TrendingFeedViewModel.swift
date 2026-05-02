import Foundation
import Observation

/// View model for the Trending screen. Wraps `feeds.nostrarchives.com`'s pre-ranked
/// relay feeds: in `.notes` mode each (metric, timeframe) combo maps to a distinct
/// relay URL that returns a finite ranked snapshot; in `.users` mode the upandcoming
/// relay returns kind-0 events for the trending profile list.
///
/// We use one-shot `RelayPool.query` rather than a persistent subscription — the
/// upstream relay sends a snapshot then EOSEs, so polling on user input matches the
/// Android client's "resubscribe on metric change" behaviour.
@Observable
@MainActor
final class TrendingFeedViewModel {
    let keypair: Keypair

    var mode: TrendingMode = .notes
    var metric: TrendingMetric = .reactions
    var timeframe: TrendingTimeframe = .today

    var events: [NostrEvent] = []
    var users: [ProfileData] = []
    var profiles: [String: ProfileData] = [:]
    var isLoading: Bool = false
    var lastError: String?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let profileRepo = ProfileRepository.shared

    private static let indexerRelays = RelayDefaults.indexers

    init(keypair: Keypair) {
        self.keypair = keypair
    }

    var displayTitle: String {
        switch mode {
        case .notes:
            return "Trending \(metric.label) · \(timeframe.label)"
        case .users:
            return "Up & Coming"
        }
    }

    func start() async {
        guard events.isEmpty && users.isEmpty else { return }
        await load()
    }

    func refresh() async {
        await load()
    }

    func setMode(_ newMode: TrendingMode) {
        guard mode != newMode else { return }
        mode = newMode
        events = []
        users = []
        Task { await load() }
    }

    func setMetric(_ newMetric: TrendingMetric) {
        let modeChanged = mode != .notes
        if modeChanged { mode = .notes }
        if !modeChanged && metric == newMetric { return }
        metric = newMetric
        events = []
        users = []
        Task { await load() }
    }

    func setTimeframe(_ newTimeframe: TrendingTimeframe) {
        guard timeframe != newTimeframe else { return }
        timeframe = newTimeframe
        if mode == .notes {
            events = []
            Task { await load() }
        }
    }

    // MARK: - Loading

    private func load() async {
        loadTask?.cancel()
        let task = Task { [mode, metric, timeframe] in
            await performLoad(mode: mode, metric: metric, timeframe: timeframe)
        }
        loadTask = task
        await task.value
    }

    private func performLoad(
        mode: TrendingMode,
        metric: TrendingMetric,
        timeframe: TrendingTimeframe
    ) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        switch mode {
        case .notes:
            await loadNotes(metric: metric, timeframe: timeframe)
        case .users:
            await loadUsers()
        }
    }

    private func loadNotes(metric: TrendingMetric, timeframe: TrendingTimeframe) async {
        let url = TrendingRelay.notesURL(metric: metric, timeframe: timeframe)
        let filter = NostrFilter(
            kinds: FeedViewModel.relayFeedKinds,
            limit: 100
        )

        let results = await RelayPool.query(
            relays: [url],
            filter: filter,
            timeout: 12
        )
        guard !Task.isCancelled else { return }
        // Bail out if the user changed mode/metric/timeframe while the query was in flight.
        guard self.mode == .notes, self.metric == metric, self.timeframe == timeframe else { return }

        // Preserve the relay's delivery order (which encodes the ranking) — do not
        // re-sort by createdAt the way the follow feed does.
        var seen = Set<String>()
        let ordered = results.filter { seen.insert($0.id).inserted }
        events = ordered

        if results.isEmpty {
            lastError = "No results from \(URL(string: url)?.host ?? url)"
        }

        // Persist anything ObjectBox cares about (kinds 1/6/20 etc — see EventStore.persistedKinds).
        if !results.isEmpty {
            let toPersist = results
            Task { await EventPersistQueue.shared.enqueue(toPersist) }
        }

        await loadMissingProfiles()
    }

    private func loadUsers() async {
        let url = TrendingRelay.usersURL
        let filter = NostrFilter(kinds: [0], limit: 100)

        let results = await RelayPool.query(
            relays: [url],
            filter: filter,
            timeout: 12
        )
        guard !Task.isCancelled else { return }
        guard self.mode == .users else { return }

        var seenPubkeys = Set<String>()
        var collected: [ProfileData] = []
        for event in results where event.kind == 0 {
            if !seenPubkeys.insert(event.pubkey).inserted { continue }
            if let profile = profileRepo.updateFromEvent(event) {
                collected.append(profile)
                profiles[profile.pubkey] = profile
            }
        }
        users = collected

        if collected.isEmpty {
            lastError = "No trending users right now"
        }
    }

    private func loadMissingProfiles() async {
        let needed = Set(events.map(\.pubkey)).filter { profiles[$0] == nil }
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
            guard !Task.isCancelled else { return }

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
