import Foundation
import Observation

/// Per-poll tally counters. Updated by `PollTallyRepository`.
struct PollTally: Hashable {
    /// Distinct voters (kind 1068 polls).
    var totalVotes: Int = 0
    /// optionId -> count (kind 1068).
    var voteCounts: [String: Int] = [:]
    /// Option ids the active user has voted for (kind 1068).
    var userVotes: [String] = []
    /// optionIndex -> total sats (kind 6969).
    var satsCounts: [Int: Int64] = [:]
    /// Sum of all sats across options (kind 6969).
    var totalSats: Int64 = 0
    /// Option index the active user voted for (kind 6969). Latest-wins.
    var userOptionIndex: Int? = nil
}

/// In-memory store of poll tallies keyed by poll event id. Modeled on
/// `EngagementRepository`: viewport-driven REQ fan-out with 300 ms debounce, outbox routing,
/// per-(relay, kind) subscriptions with a 12 s watchdog. Latest-wins per voter on both
/// kind-1068 (normal) and kind-6969 (zap-poll) tallies.
@Observable
@MainActor
final class PollTallyRepository {
    static let shared = PollTallyRepository()

    private(set) var tallies: [String: PollTally] = [:]
    /// Bumped on every mutation so SwiftUI views observing `tallies[pollId]` re-render.
    private(set) var version: Int = 0

    @ObservationIgnored private var queriedPollIds: Set<String> = []
    @ObservationIgnored private var pending: [(pollId: String, kind: Int, author: String, advertisedRelays: [String])] = []
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var liveTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var liveSubs: [RelaySubscription] = []
    @ObservationIgnored private var seenEventIds: Set<String> = []

    /// pollId -> newest vote `createdAt` seen (live or disk-seeded). Lets the live
    /// sub scope `since:` to just the delta: a poll with cached votes only pulls
    /// newer ones, while a never-seen poll (cold cursor) full-fetches. In-memory,
    /// rebuilt from disk on each cold start by the disk-seed in `flushBatch`.
    @ObservationIgnored private var voteCursor: [String: Int] = [:]

    /// Per-poll vote-author state. Mirrors Android's `pollVoters`.
    /// pollId -> voterPubkey -> (createdAt, optionIds)
    @ObservationIgnored private var pollVoters: [String: [String: (ts: Int, options: [String])]] = [:]
    /// pollId -> zapperPubkey -> (createdAt, optionIndex, sats)
    @ObservationIgnored private var zapPollVoters: [String: [String: (ts: Int, optionIndex: Int, sats: Int64)]] = [:]

    /// Cached poll events keyed by id. Used to gate zap-receipt ingestion (only count zap
    /// receipts whose target is a kind-6969 we know about) and to honor `endsAt`/`closed_at`.
    @ObservationIgnored private var pollEventCache: [String: NostrEvent] = [:]

    private init() {}

    // MARK: - Public API

    /// Called from the feed row's `.onAppear`. Registers the poll for tally subscription.
    /// Idempotent per poll id within a session.
    func markVisible(pollEvent: NostrEvent) {
        guard pollEvent.kind == Nip88.kindPoll || pollEvent.kind == Nip69.kindZapPoll else { return }
        pollEventCache[pollEvent.id] = pollEvent
        guard !queriedPollIds.contains(pollEvent.id) else { return }
        if pending.contains(where: { $0.pollId == pollEvent.id }) { return }
        let advertised = pollEvent.kind == Nip88.kindPoll
            ? Nip88.parsePollRelays(pollEvent)
            : Nip69.parseZapPollRelays(pollEvent)
        pending.append((pollEvent.id, pollEvent.kind, pollEvent.pubkey, advertised))
        if debounceTask == nil { scheduleFlush() }
    }

    func clear() {
        debounceTask?.cancel()
        debounceTask = nil
        for sub in liveSubs { sub.cancel() }
        for task in liveTasks { task.cancel() }
        liveSubs.removeAll()
        liveTasks.removeAll()
        tallies = [:]
        queriedPollIds.removeAll()
        pending.removeAll()
        seenEventIds.removeAll()
        voteCursor.removeAll()
        pollVoters.removeAll()
        zapPollVoters.removeAll()
        pollEventCache.removeAll()
        version &+= 1
    }

    func tally(for pollId: String) -> PollTally {
        tallies[pollId] ?? PollTally()
    }

    // MARK: - Optimistic writes

    func applyOptimisticVote(pollEvent: NostrEvent, optionIds: [String], voterPubkey: String, ts: Int) {
        pollEventCache[pollEvent.id] = pollEvent
        applyPollVote(
            pollId: pollEvent.id,
            voterPubkey: voterPubkey,
            optionIds: optionIds,
            ts: ts,
            isCurrentUser: voterPubkey == NostrKey.load()?.pubkey
        )
    }

    func applyOptimisticZapVote(pollEvent: NostrEvent, optionIndex: Int, voterPubkey: String, sats: Int64, ts: Int) {
        pollEventCache[pollEvent.id] = pollEvent
        applyZapPollVote(
            pollId: pollEvent.id,
            zapperPubkey: voterPubkey,
            optionIndex: optionIndex,
            sats: sats,
            ts: ts,
            isCurrentUser: voterPubkey == NostrKey.load()?.pubkey
        )
    }

    /// Roll back an optimistic kind-1068 vote (e.g. when publish fails).
    func revertOptimisticVote(pollEvent: NostrEvent, optionIds: [String], voterPubkey: String) {
        guard var voters = pollVoters[pollEvent.id], voters[voterPubkey] != nil else { return }
        voters.removeValue(forKey: voterPubkey)
        pollVoters[pollEvent.id] = voters

        var current = tallies[pollEvent.id] ?? PollTally()
        for optionId in optionIds {
            if let count = current.voteCounts[optionId], count > 0 {
                current.voteCounts[optionId] = count - 1
            }
        }
        if current.totalVotes > 0 { current.totalVotes -= 1 }
        if voterPubkey == NostrKey.load()?.pubkey {
            current.userVotes = []
        }
        tallies[pollEvent.id] = current
        version &+= 1
    }

    // MARK: - Inbound

    /// Ingest a kind-1018 poll response.
    func ingestPollResponse(_ event: NostrEvent) {
        guard event.kind == Nip88.kindPollResponse else { return }
        guard seenEventIds.insert(event.id).inserted else { return }
        guard let pollId = Nip88.getPollEventId(event) else { return }
        // Advance the per-poll cursor for every newly-seen vote (even ones the
        // latest-wins / endsAt rules below drop) so `since:` doesn't re-fetch it.
        voteCursor[pollId] = max(voteCursor[pollId] ?? 0, event.createdAt)
        let optionIds = Nip88.getResponseOptionIds(event)
        guard !optionIds.isEmpty else { return }

        // Drop votes that arrived after the poll ended.
        if let pollEvent = pollEventCache[pollId], let endsAt = Nip88.parseEndsAt(pollEvent),
           event.createdAt > endsAt {
            return
        }

        applyPollVote(
            pollId: pollId,
            voterPubkey: event.pubkey,
            optionIds: optionIds,
            ts: event.createdAt,
            isCurrentUser: event.pubkey == NostrKey.load()?.pubkey
        )
    }

    /// Ingest a kind-9735 zap receipt. Only routes if the receipt targets a known kind-6969.
    func ingestZapReceipt(_ event: NostrEvent) {
        guard event.kind == 9735 else { return }
        guard seenEventIds.insert(event.id).inserted else { return }

        // Find the targeted event id (last `e` tag, ignoring `mention` markers).
        let targets = event.tags.compactMap { tag -> String? in
            guard tag.count >= 2, tag[0] == "e" else { return nil }
            if tag.count >= 4, tag[3] == "mention" { return nil }
            return tag[1]
        }
        guard let pollId = targets.last else { return }

        // Only proceed if we know the target is a zap poll. Cold-cache → ignore (the receipt
        // will arrive again via the live notification sub when we have the poll event).
        guard let pollEvent = pollEventCache[pollId], pollEvent.kind == Nip69.kindZapPoll else { return }
        voteCursor[pollId] = max(voteCursor[pollId] ?? 0, event.createdAt)

        if let closedAt = Nip69.parseClosedAt(pollEvent), event.createdAt > closedAt { return }
        guard let optionIndex = Nip69.getZapPollOptionFromZapReceipt(event) else { return }
        guard let zapperPubkey = Nip57.zapperPubkey(receipt: event) else { return }
        let sats = Nip57.zapAmountSats(receipt: event)
        guard sats > 0 else { return }

        applyZapPollVote(
            pollId: pollId,
            zapperPubkey: zapperPubkey,
            optionIndex: optionIndex,
            sats: sats,
            ts: event.createdAt,
            isCurrentUser: zapperPubkey == NostrKey.load()?.pubkey
        )
    }

    // MARK: - Tally mutation (latest-wins)

    private func applyPollVote(pollId: String, voterPubkey: String, optionIds: [String], ts: Int, isCurrentUser: Bool) {
        var voters = pollVoters[pollId] ?? [:]
        let prev = voters[voterPubkey]
        if let prev, ts <= prev.ts { return }   // older or equal — ignore

        var current = tallies[pollId] ?? PollTally()

        if let prev {
            // Re-vote: decrement old option counts.
            for old in prev.options {
                if let c = current.voteCounts[old], c > 0 {
                    current.voteCounts[old] = c - 1
                }
            }
        } else {
            current.totalVotes += 1
        }

        for new in optionIds {
            current.voteCounts[new, default: 0] += 1
        }
        voters[voterPubkey] = (ts, optionIds)
        pollVoters[pollId] = voters

        if isCurrentUser { current.userVotes = optionIds }
        tallies[pollId] = current
        version &+= 1
    }

    private func applyZapPollVote(pollId: String, zapperPubkey: String, optionIndex: Int, sats: Int64, ts: Int, isCurrentUser: Bool) {
        var voters = zapPollVoters[pollId] ?? [:]
        let prev = voters[zapperPubkey]
        if let prev, ts <= prev.ts { return }

        var current = tallies[pollId] ?? PollTally()

        if let prev {
            // Re-vote: subtract the prior contribution from the old option's bucket and total.
            if let cur = current.satsCounts[prev.optionIndex] {
                current.satsCounts[prev.optionIndex] = max(0, cur - prev.sats)
            }
            current.totalSats = max(0, current.totalSats - prev.sats)
        }

        current.satsCounts[optionIndex, default: 0] += sats
        current.totalSats += sats
        voters[zapperPubkey] = (ts, optionIndex, sats)
        zapPollVoters[pollId] = voters

        if isCurrentUser { current.userOptionIndex = optionIndex }
        tallies[pollId] = current
        version &+= 1
    }

    // MARK: - Debounce + flush

    private func scheduleFlush() {
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.flushBatch()
        }
    }

    private func flushBatch() {
        debounceTask = nil
        let batch = pending
        pending.removeAll()
        guard !batch.isEmpty else { return }
        // Mark queried synchronously so a re-entrant `markVisible` during the
        // async relay resolution below can't enqueue the same poll twice.
        for entry in batch { queriedPollIds.insert(entry.pollId) }

        let pollIds = Set(batch.map(\.pollId))
        Task { @MainActor [weak self] in
            guard let self else { return }

            // 1. Replay the on-disk vote cache first: the tally (and the user's
            //    own-vote flag, which gates re-voting) paints instantly, and the
            //    live subs only have to deliver deltas. `markVisible` cached every
            //    poll event synchronously, so zap-receipt gating + `endsAt` checks
            //    resolve on the seeded path. `ingest*` dedupe via `seenEventIds`.
            let cached = await EventStore.shared.loadPollVotes(forPollIds: pollIds)
            for ev in cached {
                if ev.kind == Nip88.kindPollResponse {
                    self.ingestPollResponse(ev)
                } else {
                    self.ingestZapReceipt(ev)
                }
            }

            // 2. Resolve relays. A vote is addressed to the POLL AUTHOR, so per
            //    the NIP-65 inbox model the authoritative place to find every
            //    vote is the author's READ (inbox) relays — plus the relays the
            //    poll advertised for responses. `getReadRelays` fetches the
            //    author's kind-10002 from indexers on a cache miss (the common
            //    case for someone else's poll), which the old cache-only lookup
            //    silently skipped — that's why dozens of votes never showed.
            let board = NostrKey.load().flatMap { RelayScoreBoard.load(pubkey: $0.pubkey) }
            let userReads = NostrKey.load().flatMap { RelayListRepository.shared.cachedReadRelays($0.pubkey) } ?? []
            // Where the user's OWN vote lands — catches a vote cast on another device.
            let userWrites = NostrKey.load().map { RelayRouting.topWriteRelays(for: $0.pubkey) } ?? []
            let topScored = board?.scoredRelays.prefix(5).map(\.url) ?? []

            // Author inbox relays, fetched once per distinct author.
            var authorInbox: [String: [String]] = [:]
            for author in Set(batch.map(\.author)) {
                authorInbox[author] = await RelayListRepository.shared.getReadRelays(author)
            }

            // Bucket by (relay, vote-kind): kind-1068 → kind 1018, kind-6969 →
            // kind 9735. Each bucket = one REQ with #e = pollIds. Key by
            // "relay::kind" but keep the relay verbatim in the value — relay URLs
            // contain ':' (wss://…), so the key must NOT be re-parsed.
            var subKey: [String: (relay: String, kind: Int, ids: Set<String>)] = [:]
            func add(relay: String, voteKind: Int, pollId: String) {
                let key = "\(relay)::\(voteKind)"
                if var bucket = subKey[key] {
                    bucket.ids.insert(pollId)
                    subKey[key] = bucket
                } else {
                    subKey[key] = (relay, voteKind, [pollId])
                }
            }

            for entry in batch {
                let voteKind = entry.kind == Nip88.kindPoll ? Nip88.kindPollResponse : 9735
                // Primary: the poll author's inbox relays.
                for relay in (authorInbox[entry.author] ?? []).prefix(4) { add(relay: relay, voteKind: voteKind, pollId: entry.pollId) }
                // The relays the poll advertised for responses.
                for relay in entry.advertisedRelays.prefix(3) { add(relay: relay, voteKind: voteKind, pollId: entry.pollId) }
                // Backstops: the user's own reads/writes (own vote) + top-scored.
                for relay in userReads.prefix(2) { add(relay: relay, voteKind: voteKind, pollId: entry.pollId) }
                for relay in userWrites.prefix(2) { add(relay: relay, voteKind: voteKind, pollId: entry.pollId) }
                for relay in topScored.prefix(3) { add(relay: relay, voteKind: voteKind, pollId: entry.pollId) }
            }

            // 3. Open the live subs.
            for (_, bucket) in subKey {
                for chunk in Array(bucket.ids).chunked(into: 150) {
                    self.openSubscription(relay: bucket.relay, voteKind: bucket.kind, pollIds: chunk)
                }
            }
        }
    }

    private func openSubscription(relay: String, voteKind: Int, pollIds: [String]) {
        let subId = "feed-polltally-\(voteKind)-\(UUID().uuidString.prefix(6))"
        // Only pull NEW votes: the disk-seed in `flushBatch` already replayed every
        // cached vote and advanced `voteCursor`, so scope to the delta. A poll with
        // no cached votes has a cold cursor → `since` is nil → full back-fetch.
        // (Reuses the engagement `since` policy: MIN-overlap when warm, nil if any
        // poll in the batch is cold.) Overlap + `seenEventIds` absorb the boundary.
        let since = EngagementRepository.sinceFloor(forTargets: pollIds, cursor: voteCursor, forceFull: false)
        let filter = NostrFilter(kinds: [voteKind], eTags: pollIds, limit: 500, since: since)
        let sub = RelayPool.subscribe(relays: [relay], filter: filter, id: subId)
        liveSubs.append(sub)

        let consumer = Task { [weak self] in
            for await (event, _) in sub.events {
                if Task.isCancelled { return }
                // Persist so disk becomes the cross-session vote cache — the next
                // cold start can disk-seed the full tally + own-vote flag before
                // this sub re-fetches. Block/dedup is applied at the persist layer.
                Task { await EventPersistQueue.shared.enqueue(event) }
                if voteKind == Nip88.kindPollResponse {
                    self?.ingestPollResponse(event)
                } else {
                    self?.ingestZapReceipt(event)
                }
            }
        }
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            sub.cancel()
            consumer.cancel()
            self?.prune(sub: sub)
        }
        liveTasks.append(consumer)
        liveTasks.append(watchdog)
    }

    private func prune(sub: RelaySubscription) {
        liveSubs.removeAll { $0 === sub }
    }
}
