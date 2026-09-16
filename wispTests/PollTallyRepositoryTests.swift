import Foundation
import Testing
@testable import wisp

/// Locks the poll-tally invariants behind the "complete results + can't vote
/// twice" work. `PollTallyRepository` is the disk-backed tally store (the poll
/// analogue of `EngagementRepository`); these tests pin the ingest math that the
/// disk-seed + live-sub paths both funnel through:
///   • dedup — the same vote arriving via optimistic apply, the publish
///     re-ingest, the disk replay, and the live-sub echo must count exactly once.
///   • latest-wins — a voter changing their vote moves the count, never inflates,
///     and is order-independent (an out-of-order older revote is ignored).
///   • multi-select — every chosen option is counted for one voter.
///   • endsAt — votes after a poll closes don't count.
///
/// Tests are identity-free (no `NostrKey` active keypair): `totalVotes` /
/// `voteCounts` are independent of who the current user is. The `userVotes`
/// own-vote flag (which drives the results-vs-voting UI flip) depends on the
/// keychain-backed active identity and is covered by manual verification.
@Suite struct PollTallyRepositoryTests {

    // MARK: - Builders

    private func pollEvent(
        id: String,
        author: String = "author",
        options: [(String, String)],
        pollType: String = "singlechoice",
        endsAt: Int? = nil
    ) -> NostrEvent {
        var tags: [[String]] = options.map { ["option", $0.0, $0.1] }
        tags.append(["polltype", pollType])
        if let endsAt { tags.append(["endsAt", String(endsAt)]) }
        return NostrEvent(id: id, pubkey: author, kind: Nip88.kindPoll, createdAt: 1, tags: tags, content: "", sig: "")
    }

    private func vote(id: String, voter: String, poll: String, options: [String], at: Int) -> NostrEvent {
        var tags: [[String]] = [["e", poll]]
        for o in options { tags.append(["response", o]) }
        return NostrEvent(id: id, pubkey: voter, kind: Nip88.kindPollResponse, createdAt: at, tags: tags, content: "", sig: "")
    }

    // MARK: - Dedup (no double count)

    @Test @MainActor func ownVoteCountedOnceAcrossOptimisticReingestAndReplay() {
        let repo = PollTallyRepository.shared
        repo.clear()
        let poll = pollEvent(id: "p1", options: [("o1", "A"), ("o2", "B")])
        let signed = vote(id: "v1", voter: "X", poll: "p1", options: ["o1"], at: 100)

        // 1. Optimistic apply (records the voter, bumps the count).
        repo.applyOptimisticVote(pollEvent: poll, optionIds: ["o1"], voterPubkey: "X", ts: 100)
        #expect(repo.tally(for: "p1").totalVotes == 1)
        #expect(repo.tally(for: "p1").voteCounts["o1"] == 1)

        // 2. Publish re-ingest of the SAME vote (equal ts → latest-wins early-out).
        repo.ingestPollResponse(signed)
        // 3. Disk replay / live-sub echo of the same event id (seenEventIds dedup).
        repo.ingestPollResponse(signed)

        #expect(repo.tally(for: "p1").totalVotes == 1)
        #expect(repo.tally(for: "p1").voteCounts["o1"] == 1)
    }

    @Test @MainActor func sameEventIdIsCountedOnce() {
        let repo = PollTallyRepository.shared
        repo.clear()
        let v = vote(id: "dup", voter: "X", poll: "p2", options: ["o1"], at: 100)
        repo.ingestPollResponse(v)
        repo.ingestPollResponse(v)
        #expect(repo.tally(for: "p2").totalVotes == 1)
        #expect(repo.tally(for: "p2").voteCounts["o1"] == 1)
    }

    // MARK: - Latest-wins

    @Test @MainActor func revoteMovesCountWithoutInflating() {
        let repo = PollTallyRepository.shared
        repo.clear()
        repo.ingestPollResponse(vote(id: "a", voter: "X", poll: "p3", options: ["o1"], at: 100))
        repo.ingestPollResponse(vote(id: "b", voter: "X", poll: "p3", options: ["o2"], at: 200))
        let t = repo.tally(for: "p3")
        #expect(t.totalVotes == 1)
        #expect((t.voteCounts["o1"] ?? 0) == 0)
        #expect(t.voteCounts["o2"] == 1)
    }

    @Test @MainActor func outOfOrderOlderRevoteIsIgnored() {
        let repo = PollTallyRepository.shared
        repo.clear()
        // Newer revote arrives first, then the stale older one.
        repo.ingestPollResponse(vote(id: "b", voter: "X", poll: "p4", options: ["o2"], at: 200))
        repo.ingestPollResponse(vote(id: "a", voter: "X", poll: "p4", options: ["o1"], at: 100))
        let t = repo.tally(for: "p4")
        #expect(t.totalVotes == 1)
        #expect(t.voteCounts["o2"] == 1)
        #expect((t.voteCounts["o1"] ?? 0) == 0)
    }

    @Test @MainActor func distinctVotersAccumulate() {
        let repo = PollTallyRepository.shared
        repo.clear()
        repo.ingestPollResponse(vote(id: "a", voter: "X", poll: "p5", options: ["o1"], at: 100))
        repo.ingestPollResponse(vote(id: "b", voter: "Y", poll: "p5", options: ["o1"], at: 100))
        let t = repo.tally(for: "p5")
        #expect(t.totalVotes == 2)
        #expect(t.voteCounts["o1"] == 2)
    }

    // MARK: - Multi-select

    @Test @MainActor func multiSelectCountsEveryChosenOption() {
        let repo = PollTallyRepository.shared
        repo.clear()
        repo.ingestPollResponse(vote(id: "a", voter: "X", poll: "p6", options: ["o1", "o2"], at: 100))
        let t = repo.tally(for: "p6")
        #expect(t.totalVotes == 1)
        #expect(t.voteCounts["o1"] == 1)
        #expect(t.voteCounts["o2"] == 1)
    }

    // MARK: - endsAt gating

    @Test @MainActor func voteAfterPollEndIsDropped() {
        let repo = PollTallyRepository.shared
        repo.clear()
        // markVisible caches the poll synchronously so ingest can read `endsAt`.
        let poll = pollEvent(id: "p7", options: [("o1", "A")], endsAt: 100)
        repo.markVisible(pollEvent: poll)
        repo.ingestPollResponse(vote(id: "late", voter: "X", poll: "p7", options: ["o1"], at: 200))
        #expect(repo.tally(for: "p7").totalVotes == 0)
        repo.clear() // cancel the markVisible debounce so it doesn't outlive the test
    }
}
