import Foundation
import Testing
@testable import wisp

/// Locks the engagement-consistency invariants introduced to fix the feed/thread
/// count discrepancies:
///   • `sinceFloor` — the `since` policy for incremental engagement fetches
///     (warm → MIN-overlap, any-cold → nil, forceFull → nil).
///   • `ingestForwarded` — the thread→feed write-back must raise a count exactly
///     once and never inflate on re-delivery (shared dedup set), which is what
///     keeps the feed and thread showing the same number.
@Suite struct EngagementRepositoryTests {

    // MARK: - sinceFloor (pure)

    @Test func sinceFloorWarmBatchUsesMinMinusOverlap() {
        let cursor = ["a": 1_000, "b": 1_200, "c": 1_050]
        // MIN across the batch is 1_000; minus the default 60s overlap.
        #expect(EngagementRepository.sinceFloor(forTargets: ["a", "b", "c"], cursor: cursor, forceFull: false) == 940)
    }

    @Test func sinceFloorAnyColdTargetDisablesSince() {
        let cursor = ["a": 1_000, "b": 1_200] // "c" has no cursor → cold
        #expect(EngagementRepository.sinceFloor(forTargets: ["a", "b", "c"], cursor: cursor, forceFull: false) == nil)
    }

    @Test func sinceFloorForceFullDisablesSince() {
        let cursor = ["a": 1_000, "b": 1_200, "c": 1_050]
        #expect(EngagementRepository.sinceFloor(forTargets: ["a", "b", "c"], cursor: cursor, forceFull: true) == nil)
    }

    @Test func sinceFloorEmptyTargetsIsNil() {
        #expect(EngagementRepository.sinceFloor(forTargets: [], cursor: ["a": 1_000], forceFull: false) == nil)
    }

    @Test func sinceFloorClampsToZero() {
        // A cursor smaller than the overlap must not produce a negative `since`.
        #expect(EngagementRepository.sinceFloor(forTargets: ["a"], cursor: ["a": 30], forceFull: false) == 0)
    }

    @Test func sinceFloorCustomOverlap() {
        #expect(EngagementRepository.sinceFloor(forTargets: ["a"], cursor: ["a": 1_000], overlap: 120, forceFull: false) == 880)
    }

    // MARK: - ingestForwarded (thread → feed box)

    private func reaction(id: String, reactor: String, note: String, content: String = "+", at: Int = 100) -> NostrEvent {
        NostrEvent(id: id, pubkey: reactor, kind: 7, createdAt: at, tags: [["e", note]], content: content, sig: "")
    }

    private func reply(id: String, author: String, parent: String, at: Int = 100) -> NostrEvent {
        NostrEvent(id: id, pubkey: author, kind: 1, createdAt: at, tags: [["e", parent]], content: "hi", sig: "")
    }

    @Test @MainActor func forwardedReactionRaisesCountOnce() {
        let repo = EngagementRepository.shared
        repo.clear()
        let note = "note-forward-1"
        repo.ingestForwarded(reaction(id: "r1", reactor: "alice", note: note))
        #expect(repo.box(for: note).counts.reactions == 1)
    }

    @Test @MainActor func forwardedReactionIsIdempotentOnReDelivery() {
        let repo = EngagementRepository.shared
        repo.clear()
        let note = "note-forward-2"
        let r = reaction(id: "r-dup", reactor: "alice", note: note)
        // Same event id arriving twice (thread replay + later feed sub) must not
        // inflate — the shared dedup set gates the second.
        repo.ingestForwarded(r)
        repo.ingestForwarded(r)
        #expect(repo.box(for: note).counts.reactions == 1)
    }

    @Test @MainActor func forwardedDistinctReactorsAccumulate() {
        let repo = EngagementRepository.shared
        repo.clear()
        let note = "note-forward-3"
        repo.ingestForwarded(reaction(id: "r1", reactor: "alice", note: note))
        repo.ingestForwarded(reaction(id: "r2", reactor: "bob", note: note, content: "🔥"))
        #expect(repo.box(for: note).counts.reactions == 2)
        #expect(repo.box(for: note).counts.reactors.count == 2)
    }

    @Test @MainActor func forwardedReplyRaisesReplyCount() {
        let repo = EngagementRepository.shared
        repo.clear()
        let note = "note-forward-4"
        repo.ingestForwarded(reply(id: "reply-1", author: "carol", parent: note))
        repo.ingestForwarded(reply(id: "reply-1", author: "carol", parent: note)) // re-delivery
        #expect(repo.box(for: note).counts.replies == 1)
    }
}
