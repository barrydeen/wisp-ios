import Foundation

/// Discovers the user's extended social network: who-is-followed-by-multiple-of-my-follows.
/// Mirrors the Android `ExtendedNetworkRepository` 5-phase pipeline. The output is twofold:
/// (1) a qualified list of 2nd-degree pubkeys (≥10 of the user's follows follow them) which
/// drives the visualization, and (2) a greedy set-cover relay list which the Extended Feed
/// queries with no author filter — the relay set *is* the filter.
actor SocialGraphRepository {
    static let shared = SocialGraphRepository()

    private init() {}

    enum Constants {
        static let followListChunkSize       = 200
        static let followListRelayCount      = 15
        static let followListTimeout: TimeInterval = 5
        static let followListCoverageTarget  = 0.70
        static let qualifiedThreshold        = 10
        static let relayListChunkSize        = 500
        static let relayListRelayCount       = 10
        static let relayListTimeout: TimeInterval = 8
        static let maxRelays                 = 100
        static let maxAuthorsPerRelay        = 300
        static let maxWriteRelaysPerAuthor   = 3
        static let dbBatchSize               = 5000
        // Visualization caps — used by SocialGraphView to slice top-N nodes from the cache.
        static let topFirstDegreeForViz      = 15
        static let topSecondDegreeForViz     = 64
        static let topRankedListSize         = 30
        // Extended Feed
        static let extendedFeedRelayCap      = 60
    }

    /// Indexer relays used as fallback when the score board hasn't been built yet.
    /// Same set as `FeedViewModel.indexerRelays` but duplicated here to keep the repository
    /// free of FeedViewModel coupling.
    private static let indexerRelays = RelayDefaults.indexers

    /// Kicks off a fresh compute and returns a stream of `DiscoveryState` updates.
    /// Cancelling the consuming task (or finishing the stream) propagates cancellation
    /// into the work — phase loops check `Task.isCancelled` between chunks.
    nonisolated func compute(pubkey: String) -> AsyncStream<DiscoveryState> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    try await self.runCompute(pubkey: pubkey, yield: { continuation.yield($0) })
                } catch is CancellationError {
                    continuation.yield(.failed(.cancelled))
                } catch let reason as DiscoveryFailure {
                    continuation.yield(.failed(reason.reason))
                } catch {
                    continuation.yield(.failed(.unknown(error.localizedDescription)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Pipeline

    private func runCompute(pubkey: String, yield: @Sendable @escaping (DiscoveryState) -> Void) async throws {
        let start = Date()

        // ---- Setup ----------------------------------------------------------
        let follows = await loadFollows(pubkey: pubkey)
        guard !follows.isEmpty else { throw DiscoveryFailure(.emptyFollowList) }

        let relays = await loadFanoutRelays(pubkey: pubkey)
        guard !relays.isEmpty else { throw DiscoveryFailure(.unknown("no relays available")) }

        let db: SocialGraphDb
        do {
            db = try SocialGraphDb(pubkey: pubkey)
            try db.clear()
        } catch {
            throw DiscoveryFailure(.unknown("db: \(error.localizedDescription)"))
        }

        // ---- Phase 1: Fetch kind-3 contact lists ----------------------------
        yield(.fetchingFollowLists(fetched: 0, total: follows.count))
        let topFanout = Array(relays.prefix(Constants.followListRelayCount))
        var latestKind3ByAuthor: [String: NostrEvent] = [:]
        let coverageGoal = Int(Double(follows.count) * Constants.followListCoverageTarget)

        for chunk in follows.chunked(into: Constants.followListChunkSize) {
            try Task.checkCancellation()
            let events = await RelayPool.query(
                relays: topFanout,
                filter: NostrFilter(kinds: [3], authors: chunk, limit: chunk.count),
                timeout: Constants.followListTimeout
            )
            for event in events where event.kind == 3 {
                if let existing = latestKind3ByAuthor[event.pubkey], event.createdAt <= existing.createdAt { continue }
                latestKind3ByAuthor[event.pubkey] = event
            }
            yield(.fetchingFollowLists(fetched: latestKind3ByAuthor.count, total: follows.count))
            if latestKind3ByAuthor.count >= coverageGoal { break }
        }

        // ---- Phase 2: Build adjacency + 2nd-degree counts ------------------
        try Task.checkCancellation()
        let total = latestKind3ByAuthor.count
        yield(.buildingGraph(processed: 0, total: total))
        let followsSet = Set(follows)
        var secondDegreeCount: [String: Int] = [:]
        var firstDegreeFollowerCount: [String: Int] = [:]
        var rowBatch: [(String, String)] = []
        rowBatch.reserveCapacity(Constants.dbBatchSize + 1024)
        var processed = 0
        let entries = Array(latestKind3ByAuthor)
        for (firstDegree, event) in entries {
            for tag in event.tags where tag.count >= 2 && tag[0] == "p" {
                let secondDegree = tag[1]
                if secondDegree == pubkey { continue }
                secondDegreeCount[secondDegree, default: 0] += 1
                rowBatch.append((secondDegree, firstDegree))
                if followsSet.contains(secondDegree) {
                    firstDegreeFollowerCount[secondDegree, default: 0] += 1
                }
            }
            if rowBatch.count >= Constants.dbBatchSize {
                try? db.insertBatch(rowBatch)
                rowBatch.removeAll(keepingCapacity: true)
            }
            processed += 1
            if processed % 50 == 0 {
                try Task.checkCancellation()
                yield(.buildingGraph(processed: processed, total: total))
            }
        }
        if !rowBatch.isEmpty { try? db.insertBatch(rowBatch); rowBatch.removeAll(keepingCapacity: true) }
        yield(.buildingGraph(processed: total, total: total))

        // ---- Phase 3 + 4: Compute + filter ---------------------------------
        try Task.checkCancellation()
        yield(.computingNetwork(uniqueUsers: secondDegreeCount.count))
        let qualified: Set<String> = Set(secondDegreeCount.compactMap { $0.value >= Constants.qualifiedThreshold ? $0.key : nil })
        yield(.filtering(qualified: qualified.count))

        // ---- Phase 5: Fetch missing kind-10002 relay lists -----------------
        let missing: [String] = await MainActor.run {
            qualified.filter { RelayListRepository.shared.cachedReadRelays($0) == nil }
        }
        if !missing.isEmpty {
            yield(.fetchingRelayLists(fetched: 0, total: missing.count))
            let relayListFanout = Array(relays.prefix(Constants.relayListRelayCount))
            var fetched = 0
            for chunk in missing.chunked(into: Constants.relayListChunkSize) {
                try Task.checkCancellation()
                let events = await RelayPool.query(
                    relays: relayListFanout,
                    filter: NostrFilter(kinds: [10002], authors: chunk, limit: chunk.count),
                    timeout: Constants.relayListTimeout
                )
                var bestById: [String: NostrEvent] = [:]
                for event in events where event.kind == 10002 {
                    if let existing = bestById[event.pubkey], event.createdAt <= existing.createdAt { continue }
                    bestById[event.pubkey] = event
                }
                let toIngest = Array(bestById.values)
                await MainActor.run {
                    for event in toIngest { RelayListRepository.shared.ingest(event) }
                }
                fetched += chunk.count
                yield(.fetchingRelayLists(fetched: fetched, total: missing.count))
            }
        }

        // ---- Phase 6: Greedy set-cover -------------------------------------
        try Task.checkCancellation()
        var writes: [String: Set<String>] = [:]
        for author in qualified {
            let writeRelays = await MainActor.run { RelayListRepository.shared.cachedReadRelays(author) ?? [] }
            // cachedReadRelays returns the read entry (or write fallback). For set-cover we actually want
            // *write* relays — but to avoid awaiting `getWriteRelays(_:)` on every single author (which
            // could trigger a network fetch), we accept whatever's already cached as a proxy. This is the
            // exact behavior Android's `RelayListRepository.getWriteRelays` provides for already-cached
            // entries.
            for url in writeRelays.prefix(Constants.maxWriteRelaysPerAuthor) {
                writes[url, default: []].insert(author)
            }
        }
        var uncovered = qualified
        var picked: [String] = []
        while !uncovered.isEmpty && picked.count < Constants.maxRelays {
            try Task.checkCancellation()
            var bestUrl: String?
            var bestCovered: Set<String> = []
            for (url, authors) in writes {
                let covered = authors.intersection(uncovered)
                let capped = covered.count <= Constants.maxAuthorsPerRelay ? covered : Set(covered.prefix(Constants.maxAuthorsPerRelay))
                if capped.count > bestCovered.count {
                    bestUrl = url
                    bestCovered = capped
                }
            }
            guard let url = bestUrl, !bestCovered.isEmpty else { break }
            picked.append(url)
            uncovered.subtract(bestCovered)
            writes.removeValue(forKey: url)
        }

        // ---- Persist + complete --------------------------------------------
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        let stats = ComputeStats(
            followListsFetched: latestKind3ByAuthor.count,
            totalFollows: follows.count,
            secondDegreeUnique: secondDegreeCount.count,
            qualifiedCount: qualified.count,
            relayCount: picked.count,
            durationMs: durationMs
        )
        let cache = SocialGraphCache(
            computedAt: Int(Date().timeIntervalSince1970),
            firstDegreePubkeys: follows,
            qualifiedPubkeys: Array(qualified),
            relayUrls: picked,
            stats: stats,
            secondDegreeFollowerCount: secondDegreeCount.filter { $0.value >= Constants.qualifiedThreshold },
            firstDegreeFollowerCount: firstDegreeFollowerCount
        )
        cache.save(pubkey: pubkey)
        yield(.complete(stats))
    }

    // MARK: - Helpers

    private func loadFollows(pubkey: String) async -> [String] {
        await MainActor.run {
            FollowsCache.shared.follows(for: pubkey)
        }
    }

    private func loadFanoutRelays(pubkey: String) async -> [String] {
        let urls = await MainActor.run { () -> [String] in
            guard let board = RelayScoreBoard.load(pubkey: pubkey) else { return [] }
            return board.scoredRelays.map(\.url)
        }
        if !urls.isEmpty { return urls }
        return Self.indexerRelays
    }
}

// MARK: - State machine

enum DiscoveryState: Equatable, Sendable {
    case idle
    case fetchingFollowLists(fetched: Int, total: Int)
    case buildingGraph(processed: Int, total: Int)
    case computingNetwork(uniqueUsers: Int)
    case filtering(qualified: Int)
    case fetchingRelayLists(fetched: Int, total: Int)
    case complete(ComputeStats)
    case failed(Reason)

    enum Reason: Equatable, Sendable {
        case emptyFollowList
        case cancelled
        case unknown(String)
    }
}

private struct DiscoveryFailure: Error {
    let reason: DiscoveryState.Reason
    init(_ reason: DiscoveryState.Reason) { self.reason = reason }
}
