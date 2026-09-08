//
//  ThreadReplyFolderTests.swift
//  wispTests
//
//  Coverage for the depth-cap folding algorithm behind collapsible reply
//  threads (closes wisp-ios#402). Extracted from ThreadView specifically
//  so this logic has real test coverage.
//

import Testing
@testable import wisp

struct ThreadReplyFolderTests {

    private func event(_ id: String) -> NostrEvent {
        NostrEvent(id: id, pubkey: "pub-\(id)", kind: 1, createdAt: 0, tags: [], content: "", sig: "")
    }

    private func row(_ id: String, depth: Int, wotHidden: Bool = false, blocked: Bool = false) -> NestedReplyRow {
        NestedReplyRow(row: ThreadRow(event: event(id), isBlocked: blocked, isWotHidden: wotHidden), depth: depth)
    }

    private func singleIds(_ result: [ThreadReplyFolder.DisplayItem]) -> [String] {
        result.compactMap { item in
            if case .single(let r, _) = item { return r.id }
            return nil
        }
    }

    @Test func emptyThreadProducesEmptyResult() {
        #expect(ThreadReplyFolder.fold(items: [], expandedBranchIds: [], exemptTargetId: nil).isEmpty)
    }

    @Test func directParentEventsResolvesStructuralParentNotGrandparent() {
        // r1(0) -> r2(1) -> [c1(2), c2(2)] two depth-2 siblings under r2.
        let items = [row("r1", depth: 0), row("r2", depth: 1), row("c1", depth: 2), row("c2", depth: 2)]
        let focal = event("root")
        let parents = ThreadReplyFolder.directParentEvents(in: items, focal: focal)

        #expect(parents["r1"]?.id == "root")
        #expect(parents["r2"]?.id == "r1")
        #expect(parents["c1"]?.id == "r2")
        #expect(parents["c2"]?.id == "r2")
    }

    @Test func shallowThreadUnderCapNeverFolds() {
        let items = [row("r1", depth: 0), row("r2", depth: 1)]
        let result = ThreadReplyFolder.fold(items: items, expandedBranchIds: [], exemptTargetId: nil)
        #expect(result.count == 2)
        for item in result {
            if case .collapsedReplies = item { Issue.record("shallow thread should never fold") }
        }
    }

    @Test func depthCapFoldsRepliesBeyondCap() {
        // root -> r2(1) -> r3(2) -> r4(3) -> r5(4) -> r6(5)
        let items = [
            row("r1", depth: 0), row("r2", depth: 1), row("r3", depth: 2),
            row("r4", depth: 3), row("r5", depth: 4), row("r6", depth: 5),
        ]
        let result = ThreadReplyFolder.fold(items: items, expandedBranchIds: [], exemptTargetId: nil)

        // Depths 0..3 render as posts (root + DEPTH_CAP levels); r4's
        // subtree (r5, r6) folds behind one marker anchored at r4.
        #expect(singleIds(result) == ["r1", "r2", "r3", "r4"])
        guard case .collapsedReplies(let anchor, let depth, let hiddenCount) = result.last else {
            Issue.record("expected a trailing collapsedReplies marker")
            return
        }
        #expect(anchor.id == "r4")
        #expect(depth == 4)
        #expect(hiddenCount == 2)
    }

    @Test func expandingRevealsWholeSubtreeUncapped() {
        let items = [
            row("r1", depth: 0), row("r2", depth: 1), row("r3", depth: 2),
            row("r4", depth: 3), row("r5", depth: 4), row("r6", depth: 5), row("r7", depth: 6),
        ]
        let result = ThreadReplyFolder.fold(items: items, expandedBranchIds: ["r4"], exemptTargetId: nil)

        // Expanding r4 reveals everything below it in one shot — the cap
        // does NOT reapply one level deeper.
        #expect(singleIds(result) == ["r1", "r2", "r3", "r4", "r5", "r6", "r7"])
        for item in result {
            if case .collapsedReplies = item { Issue.record("expanded branch should not re-fold") }
        }
    }

    @Test func exemptTargetPathIsNeverFoldedButSiblingsStillFold() {
        // Two branches off r3(depth 2): branch A has no target and folds at
        // a4; branch B leads to the exempt target and must render fully.
        let items = [
            row("r1", depth: 0), row("r2", depth: 1), row("r3", depth: 2),
            row("a4", depth: 3), row("a5", depth: 4), row("a6", depth: 5),
            row("b4", depth: 3), row("b5", depth: 4), row("target", depth: 5),
        ]
        let result = ThreadReplyFolder.fold(items: items, expandedBranchIds: [], exemptTargetId: "target")
        let ids = Set(singleIds(result))

        #expect(ids.contains("a4"))
        #expect(!ids.contains("a5"))
        #expect(!ids.contains("a6"))
        #expect(ids.contains("b4"))
        #expect(ids.contains("b5"))
        #expect(ids.contains("target"))
    }

    @Test func midAirOnlyOnDepthTransitionsNotBetweenSiblings() {
        // r1 -> three depth-1 siblings under the same parent.
        let items = [row("r1", depth: 0), row("c1", depth: 1), row("c2", depth: 1), row("c3", depth: 1)]
        let result = ThreadReplyFolder.fold(items: items, expandedBranchIds: [], exemptTargetId: nil)

        let flags = result.compactMap { item -> (String, Bool)? in
            if case .single(let r, let midAir) = item { return (r.id, midAir) }
            return nil
        }
        // r1 is depth 0 (no rail at all). c1 is the first reply of a
        // branch — its rail can't align with r1's, so it's dashed. c2/c3
        // are same-depth siblings directly below a same-depth row, so
        // their rail continues the one above without a break.
        #expect(flags.map(\.0) == ["r1", "c1", "c2", "c3"])
        #expect(flags.map(\.1) == [false, true, false, false])
    }

    @Test func wotGroupPreservesReachabilityOfFoldedDescendants() {
        // r1->r2->r3, then two same-depth WoT-hidden siblings at depth 3;
        // only the second (w2) has its own deep children past the cap.
        let items = [
            row("r1", depth: 0), row("r2", depth: 1), row("r3", depth: 2),
            row("w1", depth: 3, wotHidden: true),
            row("w2", depth: 3, wotHidden: true),
            row("d4", depth: 4), row("d5", depth: 5),
        ]
        let result = ThreadReplyFolder.fold(items: items, expandedBranchIds: [], exemptTargetId: nil)

        guard case .wotGroup(let count, let depth, _) = result[3] else {
            Issue.record("expected a wotGroup absorbing both hidden siblings")
            return
        }
        #expect(count == 2)
        #expect(depth == 3)
        guard case .collapsedReplies(let anchor, let foldDepth, let hiddenCount) = result[safe: 4] else {
            Issue.record("expected a collapsedReplies marker right after the wotGroup, not dropped")
            return
        }
        #expect(anchor.id == "w2")
        #expect(foldDepth == 4)
        #expect(hiddenCount == 2)
    }

    // MARK: - Muted-author grouping

    /// With no per-post reveal there's nothing to do with an individual muted
    /// row, so a run of them collapses to one counted row rather than stacking
    /// identical placeholders.
    @Test func consecutiveMutedRowsCollapseIntoOneCountedRow() {
        let items = [
            row("a", depth: 0),
            row("m1", depth: 0, blocked: true),
            row("m2", depth: 0, blocked: true),
            row("m3", depth: 0, blocked: true),
            row("b", depth: 0),
        ]
        let result = ThreadReplyFolder.fold(
            items: items, expandedBranchIds: [], exemptTargetId: nil, groupMuted: true
        )
        #expect(result.count == 3)
        guard case .mutedGroup(let count, let depth, _) = result[1] else {
            Issue.record("expected a muted group, got \(result)")
            return
        }
        #expect(count == 3)
        #expect(depth == 0)
        #expect(singleIds(result) == ["a", "b"])
    }

    /// The reveal mode needs each row addressable for its own Show link.
    @Test func mutedRowsStaySeparateWhenGroupingIsOff() {
        let items = [
            row("m1", depth: 0, blocked: true),
            row("m2", depth: 0, blocked: true),
        ]
        let result = ThreadReplyFolder.fold(
            items: items, expandedBranchIds: [], exemptTargetId: nil, groupMuted: false
        )
        #expect(result.count == 2)
        #expect(singleIds(result) == ["m1", "m2"])
    }

    /// Grouping is per-depth: rows at different depths are different points in
    /// the conversation and must not merge into one count.
    @Test func mutedRowsAtDifferentDepthsDoNotMerge() {
        let items = [
            row("m1", depth: 0, blocked: true),
            row("m2", depth: 1, blocked: true),
        ]
        let result = ThreadReplyFolder.fold(
            items: items, expandedBranchIds: [], exemptTargetId: nil, groupMuted: true
        )
        #expect(result.count == 2)
        for item in result {
            guard case .mutedGroup(let count, _, _) = item else {
                Issue.record("expected two muted groups, got \(result)")
                return
            }
            #expect(count == 1)
        }
    }

    /// A muted run must not swallow an unmuted reply that sits between two
    /// muted ones — that would hide a visible author's post.
    @Test func anUnmutedReplyBreaksTheRun() {
        let items = [
            row("m1", depth: 0, blocked: true),
            row("visible", depth: 0),
            row("m2", depth: 0, blocked: true),
        ]
        let result = ThreadReplyFolder.fold(
            items: items, expandedBranchIds: [], exemptTargetId: nil, groupMuted: true
        )
        #expect(result.count == 3)
        #expect(singleIds(result) == ["visible"])
    }

    /// WoT-hidden and muted are distinct states with distinct copy; a run of
    /// one must not absorb the other.
    @Test func mutedAndWotRunsGroupSeparately() {
        let items = [
            row("w1", depth: 0, wotHidden: true),
            row("m1", depth: 0, blocked: true),
        ]
        let result = ThreadReplyFolder.fold(
            items: items, expandedBranchIds: [], exemptTargetId: nil, groupMuted: true
        )
        #expect(result.count == 2)
        guard case .wotGroup = result[0] else { Issue.record("expected WoT group first"); return }
        guard case .mutedGroup = result[1] else { Issue.record("expected muted group second"); return }
    }

    /// A muted row can be a fold anchor. Anything folded beneath the last row
    /// of a collapsed run has to stay reachable rather than vanish.
    @Test func subtreeFoldedUnderAMutedRunStaysExpandable() {
        let items = [
            row("m1", depth: 3, blocked: true),
            row("child", depth: 4),
            row("grandchild", depth: 5),
        ]
        let result = ThreadReplyFolder.fold(
            items: items, expandedBranchIds: [], exemptTargetId: nil, groupMuted: true
        )
        guard case .mutedGroup = result.first else {
            Issue.record("expected the muted row to group, got \(result)")
            return
        }
        let hasCollapsed = result.contains { if case .collapsedReplies = $0 { return true } else { return false } }
        #expect(hasCollapsed)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
