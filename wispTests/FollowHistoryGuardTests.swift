import Testing
import Foundation
@testable import wisp

struct FollowHistoryGuardTests {

    private func kind3(_ pubkeys: [String], createdAt: Int = 0, kind: Int = 3) -> NostrEvent {
        NostrEvent(
            id: String(repeating: "0", count: 64),
            pubkey: "me",
            kind: kind,
            createdAt: createdAt,
            tags: pubkeys.map { ["p", $0] },
            content: "",
            sig: ""
        )
    }

    // MARK: - isSubstantialDrop

    @Test func substantialDrop_classicWipe() {
        // 400 → 1 is the canonical clobbered-list case.
        #expect(FollowHistoryGuard.isSubstantialDrop(current: 1, previous: 400))
    }

    @Test func substantialDrop_ignoresTinyPartialDrops() {
        // Below the meaningful floor we don't flag partial drops — normal
        // churn on a small list reads as proportionally large.
        #expect(!FollowHistoryGuard.isSubstantialDrop(current: 1, previous: 9))
    }

    @Test func substantialDrop_completeWipeAlwaysFiresWhenRecoverable() {
        // A drop to zero is unambiguous — surface whenever there's anything
        // recoverable. The deep sweep that produced `previous` already
        // filters out the "no history exists at all" case.
        #expect(FollowHistoryGuard.isSubstantialDrop(current: 0, previous: 9))
        #expect(FollowHistoryGuard.isSubstantialDrop(current: 0, previous: 5))
        #expect(FollowHistoryGuard.isSubstantialDrop(current: 0, previous: 1))
    }

    @Test func substantialDrop_nothingToRecover() {
        // If literally nothing was published before, there's nothing to offer.
        #expect(!FollowHistoryGuard.isSubstantialDrop(current: 0, previous: 0))
    }

    @Test func substantialDrop_needsAbsoluteFloor() {
        // 12 → 8: proportionally < 50%? No (8 is 66%). And only 4 lost. Not flagged.
        #expect(!FollowHistoryGuard.isSubstantialDrop(current: 8, previous: 12))
        // 20 → 17: only 3 lost — below the absolute floor.
        #expect(!FollowHistoryGuard.isSubstantialDrop(current: 17, previous: 20))
    }

    @Test func substantialDrop_needsRatioAndFloor() {
        // 30 → 14: more than half lost (14 < 15) and 16 lost. Flagged.
        #expect(FollowHistoryGuard.isSubstantialDrop(current: 14, previous: 30))
        // 30 → 16: 16 is > 50% of 30, so not "substantial" despite 14 lost.
        #expect(!FollowHistoryGuard.isSubstantialDrop(current: 16, previous: 30))
    }

    @Test func substantialDrop_growthIsNeverADrop() {
        #expect(!FollowHistoryGuard.isSubstantialDrop(current: 500, previous: 400))
        #expect(!FollowHistoryGuard.isSubstantialDrop(current: 400, previous: 400))
    }

    // MARK: - followedPubkeys

    @Test func followedPubkeys_dedupesPreservingOrder() {
        let event = NostrEvent(
            id: String(repeating: "0", count: 64),
            pubkey: "me", kind: 3, createdAt: 0,
            tags: [
                ["p", "alice"],
                ["e", "noteid"],          // wrong tag type
                ["p", "bob"],
                ["p", "alice"],           // duplicate
                ["p"],                    // malformed (too short)
                ["p", ""],                // empty pubkey
                ["client", "Wisp iOS"],
                ["p", "carol"]
            ],
            content: "", sig: ""
        )
        #expect(FollowHistoryGuard.followedPubkeys(in: event) == ["alice", "bob", "carol"])
    }

    // MARK: - bestVersion

    @Test func bestVersion_picksLargestBeatingCurrent() {
        let events = [
            kind3(["a", "b"]),                       // 2
            kind3(["a", "b", "c", "d", "e"]),        // 5  <- best
            kind3(["a", "b", "c"])                   // 3
        ]
        let best = FollowHistoryGuard.bestVersion(in: events, beating: 2)
        #expect(best?.count == 5)
    }

    @Test func bestVersion_nilWhenNothingBeatsCurrent() {
        let events = [kind3(["a", "b"]), kind3(["a"])]
        #expect(FollowHistoryGuard.bestVersion(in: events, beating: 2) == nil)
    }

    @Test func bestVersion_ignoresNonKind3() {
        let events = [
            kind3(["a", "b", "c", "d", "e"], kind: 30000),  // not a contact list
            kind3(["a", "b"])
        ]
        #expect(FollowHistoryGuard.bestVersion(in: events, beating: 1)?.count == 2)
    }
}
