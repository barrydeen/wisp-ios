import Foundation

/// State of the WoT recompute job. Surfaced by `SafetySettingsView`'s "Recompute network"
/// button. Each step roughly mirrors the Android `DiscoveryState`.
enum WotDiscoveryState: Sendable, Equatable {
    case idle
    case fetchingFollowLists(fetched: Int, total: Int)
    case buildingGraph(processed: Int, total: Int)
    case complete(qualifiedCount: Int)
    case failed(reason: String)
}

/// Web-of-Trust qualified-set builder. Walks the user's first-degree follows, fetches each
/// follow's kind:3, counts second-degree references, and keeps anyone who appears >=10
/// times. The resulting `qualifiedNetwork` set is consumed by `SafetyFilter` when WoT is on.
actor ExtendedNetworkRepository {
    static let shared = ExtendedNetworkRepository()

    private static let qualificationThreshold = 10
    private static let staleHours = 24
    private static let staleDriftRatio = 0.10
    private static let followsBatchSize = 200
    private static let followsTimeout: TimeInterval = 8

    private var pubkey: String?
    private var qualified: Set<String> = []
    private var firstDegreeCount: Int = 0
    private var computedAt: Int = 0
    private var inProgress = false
    private var stateContinuation: AsyncStream<WotDiscoveryState>.Continuation?
    nonisolated let stateStream: AsyncStream<WotDiscoveryState>

    private init() {
        var cont: AsyncStream<WotDiscoveryState>.Continuation!
        self.stateStream = AsyncStream { c in cont = c }
        self.stateContinuation = cont
    }

    // MARK: - Lifecycle

    func bind(activePubkey pk: String) {
        self.pubkey = pk
        loadFromDefaults(pk)
        emitState(.idle)
    }

    func unbind() {
        pubkey = nil
        qualified = []
        firstDegreeCount = 0
        computedAt = 0
        inProgress = false
        emitState(.idle)
    }

    // MARK: - Public read

    func qualifiedSet() -> Set<String> { qualified }

    func isStale() -> Bool {
        guard let pk = pubkey else { return true }
        if computedAt == 0 { return true }
        let now = Int(Date().timeIntervalSince1970)
        if now - computedAt > Self.staleHours * 3600 { return true }
        let currentFollows = FollowsCache.shared.follows(for: pk)
        guard firstDegreeCount > 0 else { return false }
        let drift = abs(currentFollows.count - firstDegreeCount)
        return Double(drift) / Double(firstDegreeCount) > Self.staleDriftRatio
    }

    func summary() -> (qualifiedCount: Int, computedAt: Int) {
        (qualified.count, computedAt)
    }

    // MARK: - Recompute

    func recompute() async {
        guard !inProgress else { return }
        guard let pk = pubkey else {
            emitState(.failed(reason: "No active account"))
            return
        }
        let firstDegree = FollowsCache.shared.follows(for: pk)
        guard !firstDegree.isEmpty else {
            emitState(.failed(reason: "Follow list is empty"))
            return
        }

        inProgress = true
        defer { inProgress = false }

        let firstDegreeSet = Set(firstDegree)
        emitState(.fetchingFollowLists(fetched: 0, total: firstDegree.count))

        // Pick top relays from the user's score board, falling back to the user's read relays
        // and finally to a small default set if both are empty.
        var relays = await pickRelays(forUser: pk)
        if relays.isEmpty { relays = Self.fallbackRelays }

        // Chunk follows into batches and parallel-fetch their kind:3.
        let chunks = firstDegree.chunked(into: Self.followsBatchSize)
        var followEvents: [String: NostrEvent] = [:]

        await withTaskGroup(of: [NostrEvent].self) { group in
            for chunk in chunks {
                let relaysCopy = relays
                group.addTask {
                    let filter = NostrFilter(kinds: [3], authors: chunk, limit: chunk.count * 2)
                    return await RelayPool.query(
                        relays: relaysCopy, filter: filter, timeout: Self.followsTimeout
                    )
                }
            }
            for await batch in group {
                for event in batch {
                    guard event.kind == 3 else { continue }
                    if let existing = followEvents[event.pubkey], existing.createdAt >= event.createdAt {
                        continue
                    }
                    followEvents[event.pubkey] = event
                }
                emitState(.fetchingFollowLists(fetched: followEvents.count, total: firstDegree.count))
            }
        }

        emitState(.buildingGraph(processed: 0, total: followEvents.count))

        // Count second-degree references: how many of our first-degree follows follow each
        // second-degree pubkey.
        var counts: [String: Int] = [:]
        var processed = 0
        for (_, event) in followEvents {
            for tag in event.tags where tag.count >= 2 && tag[0] == "p" {
                let pk2 = tag[1]
                if pk2 == pk { continue }
                counts[pk2, default: 0] += 1
            }
            processed += 1
            if processed % 25 == 0 {
                emitState(.buildingGraph(processed: processed, total: followEvents.count))
            }
        }

        // Build qualified set: first-degree (always trusted) plus any second-degree pubkey at or
        // above the threshold (typically 10 in-network references).
        var qual = Set(firstDegree)
        for (pk2, count) in counts where count >= Self.qualificationThreshold {
            if firstDegreeSet.contains(pk2) { continue }
            qual.insert(pk2)
        }

        qualified = qual
        firstDegreeCount = firstDegree.count
        computedAt = Int(Date().timeIntervalSince1970)
        saveToDefaults(pk)

        emitState(.complete(qualifiedCount: qual.count))
        await SafetyFilter.shared.rebuildSnapshot()
    }

    // MARK: - Persistence

    private func loadFromDefaults(_ pk: String) {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey(pk)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            qualified = []
            firstDegreeCount = 0
            computedAt = 0
            return
        }
        if let arr = json["qualified"] as? [String] {
            qualified = Set(arr)
        }
        firstDegreeCount = (json["firstDegreeCount"] as? Int) ?? 0
        computedAt = (json["computedAt"] as? Int) ?? 0
    }

    private func saveToDefaults(_ pk: String) {
        let json: [String: Any] = [
            "qualified": Array(qualified),
            "firstDegreeCount": firstDegreeCount,
            "computedAt": computedAt
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey(pk))
    }

    static func cacheKey(_ pubkey: String) -> String { "wot_qualified_\(pubkey)" }

    // MARK: - Internals

    private static let fallbackRelays = RelayDefaults.fallbacks

    private func pickRelays(forUser pk: String) async -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        if let board = RelayScoreBoard.load(pubkey: pk) {
            for relay in board.scoredRelays.prefix(20) where seen.insert(relay.url).inserted {
                ordered.append(relay.url)
            }
        }
        let userReads = await RelayListRepository.shared.getReadRelays(pk)
        for url in userReads where seen.insert(url).inserted {
            ordered.append(url)
        }
        return ordered
    }

    private func emitState(_ state: WotDiscoveryState) {
        stateContinuation?.yield(state)
    }
}
