import Foundation

/// Pure depth-cap folding pass over a flat, DFS-preorder reply list —
/// extracted out of `ThreadView` so the algorithm has real unit test
/// coverage instead of living inline in a View. Closes wisp-ios#402.
///
/// Replies deeper than `depthCap` levels fold behind a `.collapsedReplies`
/// affordance the UI expands inline. Expanding a branch reveals its WHOLE
/// remaining subtree at once, not just one more level. A row on the path
/// to `exemptTargetId` (the highlighted / scroll target reply) is never
/// folded, so a freshly posted or deep-linked reply is always reachable.
enum ThreadReplyFolder {
    static let depthCap = 3

    enum DisplayItem: Identifiable {
        case single(NestedReplyRow, midAir: Bool)
        case wotGroup(count: Int, depth: Int, id: String)
        /// Consecutive same-depth rows from muted authors, collapsed to one
        /// counted row. Only produced when the display mode offers no
        /// per-post reveal — with a Show link each row has to stand alone.
        case mutedGroup(count: Int, depth: Int, id: String)
        /// A folded subtree under `anchor`, expandable inline. `depth` is
        /// the anchor's depth + 1 (one level deeper).
        case collapsedReplies(anchor: NestedReplyRow, depth: Int, hiddenCount: Int)

        var id: String {
            switch self {
            case .single(let r, _): return r.id
            case .wotGroup(_, _, let gid): return "wot-\(gid)"
            case .mutedGroup(_, _, let gid): return "muted-\(gid)"
            case .collapsedReplies(let anchor, _, _): return "collapsed-\(anchor.id)"
            }
        }
    }

    static func fold(
        items: [NestedReplyRow],
        expandedBranchIds: Set<String>,
        exemptTargetId: String?,
        depthCap: Int = depthCap,
        /// Collapse runs of muted-author rows into one counted row. Off by
        /// default: only the placeholder-without-reveal mode wants it, since
        /// N identical unactionable rows are pure noise, while a mode with a
        /// per-row Show link needs each row addressable.
        groupMuted: Bool = false
    ) -> [DisplayItem] {
        let exempt = ancestorChain(to: exemptTargetId, in: items)

        // Pass 1 — depth-cap fold. `insideExpandedDepth` stays set for
        // every descendant of an expanded anchor until the walk returns to
        // the anchor's own depth or shallower, so expansion is whole-
        // subtree, not one-level-at-a-time.
        var folded: [NestedReplyRow] = []
        var collapsedAfter: [String: Int] = [:]
        var i = 0
        var insideExpandedDepth: Int? = nil
        while i < items.count {
            let item = items[i]
            if let d = insideExpandedDepth, item.depth <= d {
                insideExpandedDepth = nil
            }
            let hasChildren = i + 1 < items.count && items[i + 1].depth > item.depth
            let capHere = item.depth >= depthCap
                && hasChildren
                && insideExpandedDepth == nil
                && !expandedBranchIds.contains(item.id)
                && !exempt.contains(item.id)
            folded.append(item)
            if capHere {
                var hiddenCount = 0
                var j = i + 1
                while j < items.count && items[j].depth > item.depth {
                    hiddenCount += 1
                    j += 1
                }
                collapsedAfter[item.id] = hiddenCount
                i = j
            } else {
                if expandedBranchIds.contains(item.id) { insideExpandedDepth = item.depth }
                i += 1
            }
        }

        // Pass 2 — mid-air connector detection + the existing consecutive
        // WoT-hidden grouping + collapsed-marker insertion, in one forward
        // scan over the fold survivors. `prevPostDepth` only advances on
        // rendered rows (real posts or a WoT group).
        var result: [DisplayItem] = []
        var prevPostDepth = -1
        var k = 0
        while k < folded.count {
            let item = folded[k]
            if item.row.isWotHidden {
                let groupDepth = item.depth
                let groupId = item.id
                var count = 1
                var j = k + 1
                while j < folded.count && folded[j].row.isWotHidden && folded[j].depth == groupDepth {
                    count += 1
                    j += 1
                }
                result.append(.wotGroup(count: count, depth: groupDepth, id: groupId))
                prevPostDepth = groupDepth
                // A WoT-hidden row can itself be a fold anchor (its subtree
                // still walks into `items` one level deeper) — preserve
                // reachability of anything folded under the last grouped
                // placeholder instead of silently dropping it.
                let lastGrouped = folded[j - 1]
                if let hiddenCount = collapsedAfter[lastGrouped.id] {
                    result.append(.collapsedReplies(anchor: lastGrouped, depth: lastGrouped.depth + 1, hiddenCount: hiddenCount))
                }
                k = j
                continue
            }
            if groupMuted, item.row.isBlocked {
                let groupDepth = item.depth
                let groupId = item.id
                var count = 1
                var j = k + 1
                while j < folded.count && folded[j].row.isBlocked && folded[j].depth == groupDepth {
                    count += 1
                    j += 1
                }
                result.append(.mutedGroup(count: count, depth: groupDepth, id: groupId))
                prevPostDepth = groupDepth
                // Same reachability guard as the WoT group: a muted row can be
                // a fold anchor, and anything folded beneath the last grouped
                // row must stay expandable rather than vanish.
                let lastGrouped = folded[j - 1]
                if let hiddenCount = collapsedAfter[lastGrouped.id] {
                    result.append(.collapsedReplies(anchor: lastGrouped, depth: lastGrouped.depth + 1, hiddenCount: hiddenCount))
                }
                k = j
                continue
            }
            let midAir = item.depth > 0 && prevPostDepth != item.depth
            prevPostDepth = item.depth
            result.append(.single(item, midAir: midAir))
            if let hiddenCount = collapsedAfter[item.id] {
                result.append(.collapsedReplies(anchor: item, depth: item.depth + 1, hiddenCount: hiddenCount))
            }
            k += 1
        }
        return result
    }

    /// `targetId` and every ancestor of it in the flat depth-tagged list,
    /// stack-reconstructed from the DFS-preorder depth sequence.
    static func ancestorChain(to targetId: String?, in items: [NestedReplyRow]) -> Set<String> {
        guard let targetId else { return [] }
        var stack: [String] = []
        for item in items {
            while stack.count > item.depth { stack.removeLast() }
            stack.append(item.id)
            if item.id == targetId { return Set(stack) }
        }
        return []
    }

    /// Direct-parent event for every row in `items` — the nearest
    /// preceding row at `depth - 1`, reconstructed from the DFS-preorder
    /// depth sequence (same stack technique as `ancestorChain`, so this
    /// stays O(n) rather than an O(n) lookup repeated per row). Guaranteed
    /// to agree with `Nip10.replyTarget(of:)` since that's exactly what
    /// built this tree in the first place (`ThreadViewModel.parent(of:)`).
    /// Depth-0 rows resolve to `focal` instead, since their parent isn't a
    /// row in `items` at all. Drives the "Replying to X" label so every
    /// reply names who it directly targets — the connector rail only shows
    /// structure, not identity, and that distinction is exactly what
    /// wisp-ios#402 was about.
    static func directParentEvents(in items: [NestedReplyRow], focal: NostrEvent?) -> [String: NostrEvent] {
        var stack: [NestedReplyRow] = []
        var parents: [String: NostrEvent] = [:]
        for item in items {
            while stack.count > item.depth { stack.removeLast() }
            if let parent = stack.last {
                parents[item.id] = parent.row.event
            } else if let focal {
                parents[item.id] = focal
            }
            stack.append(item)
        }
        return parents
    }
}
