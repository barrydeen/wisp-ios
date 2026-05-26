import Foundation
import Observation

/// View model for the "My Polls" screen. Surfaces polls the user authored
/// (kind 1068 / 6969) plus polls they've voted in (followed by kind-1018
/// poll-response back to the poll event). Hydrates tally state via
/// `PollTallyRepository.markVisible` so the screen renders live counts.
@Observable
@MainActor
final class PollsViewModel {

    enum Tab: Hashable { case mine, voted }

    let keypair: Keypair

    /// Polls authored by the current user (kind 1068 / 6969), newest first.
    var minePolls: [NostrEvent] = []
    /// Polls the user has voted in (kind 1068 only — zap polls are tracked
    /// through receipts and don't share the same vote primitive).
    var votedPolls: [NostrEvent] = []

    var isLoadingMine: Bool = false
    var isLoadingVoted: Bool = false
    var selectedTab: Tab = .mine
    var errorMessage: String?

    @ObservationIgnored private let tallyRepo = PollTallyRepository.shared

    init(keypair: Keypair) {
        self.keypair = keypair
    }

    // MARK: - Mine

    func loadMine() async {
        isLoadingMine = true
        errorMessage = nil
        defer { isLoadingMine = false }

        let cached = await EventStore.shared.loadRecentByAuthor(
            pubkey: keypair.pubkey,
            kinds: [Nip88.kindPoll, Nip69.kindZapPoll],
            limit: 200
        )
        ingestMine(cached)

        let relays = queryRelays()
        let filter = NostrFilter(
            kinds: [Nip88.kindPoll, Nip69.kindZapPoll],
            authors: [keypair.pubkey],
            limit: 200
        )
        let fetched = await RelayPool.query(relays: relays, filter: filter, timeout: 8)
        ingestMine(fetched)
        Task { await EventPersistQueue.shared.enqueue(fetched) }
    }

    // MARK: - Voted

    func loadVoted() async {
        isLoadingVoted = true
        errorMessage = nil
        defer { isLoadingVoted = false }

        let relays = queryRelays()
        // 1. Find my poll responses (kind 1018 authored by me).
        let voteFilter = NostrFilter(
            kinds: [Nip88.kindPollResponse],
            authors: [keypair.pubkey],
            limit: 300
        )
        let votes = await RelayPool.query(relays: relays, filter: voteFilter, timeout: 8)
        let pollIds = Array(Set(votes.compactMap { Nip88.getPollEventId($0) }))
        guard !pollIds.isEmpty else { return }

        // 2. Hydrate the referenced polls — cache first, then fill gaps from relays.
        let cached = await EventStore.shared.eventsByIds(pollIds)
        ingestVoted(cached)
        let missing = Set(pollIds).subtracting(cached.map(\.id))
        if !missing.isEmpty {
            let pollsFilter = NostrFilter(
                kinds: [Nip88.kindPoll],
                ids: Array(missing),
                limit: missing.count
            )
            let fetched = await RelayPool.query(relays: relays, filter: pollsFilter, timeout: 8)
            ingestVoted(fetched)
            Task { await EventPersistQueue.shared.enqueue(fetched) }
        }

        // 3. Feed our own kind-1018 responses straight into the tally repo
        //    so the row's "N votes" total + the selected-option indicator
        //    render immediately. Without this the row sits at "0 votes"
        //    until the per-poll subscription `markVisible` fires returns
        //    everyone's responses — easily several seconds — and the
        //    user's own vote is the most surprising omission given they
        //    just opened the *Voted* tab. `ingestPollResponse` is
        //    idempotent (dedup via `seenEventIds`), so re-ingest when
        //    the per-poll REQ lands is a no-op.
        for vote in votes {
            tallyRepo.ingestPollResponse(vote)
        }
    }

    // MARK: - Helpers

    private func ingestMine(_ events: [NostrEvent]) {
        var byId: [String: NostrEvent] = Dictionary(uniqueKeysWithValues: minePolls.map { ($0.id, $0) })
        for e in events where e.kind == Nip88.kindPoll || e.kind == Nip69.kindZapPoll {
            guard e.pubkey == keypair.pubkey else { continue }
            byId[e.id] = e
        }
        minePolls = byId.values.sorted { $0.createdAt > $1.createdAt }
        for poll in minePolls { tallyRepo.markVisible(pollEvent: poll) }
    }

    private func ingestVoted(_ events: [NostrEvent]) {
        var byId: [String: NostrEvent] = Dictionary(uniqueKeysWithValues: votedPolls.map { ($0.id, $0) })
        for e in events where e.kind == Nip88.kindPoll {
            byId[e.id] = e
        }
        votedPolls = byId.values.sorted { $0.createdAt > $1.createdAt }
        for poll in votedPolls { tallyRepo.markVisible(pollEvent: poll) }
    }

    private func queryRelays() -> [String] {
        if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
            let top = board.scoredRelays.prefix(8).map(\.url)
            if !top.isEmpty { return top }
        }
        return [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
            "wss://relay.nostr.band"
        ]
    }
}
