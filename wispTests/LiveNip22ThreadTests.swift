import Foundation
import Testing
@testable import wisp

/// LIVE regression test for the NIP-22 thread display fix, driven against the
/// real relays with the real `ThreadViewModel` — no fixtures, no UI.
///
/// The thread is the one from the bug report: a kind-1 note
/// (`000007eb…`) whose comment chain continues through four nested kind-1111
/// comments, rooted via uppercase `E` on the note and threaded via lowercase
/// `e` between themselves. Before the fix the thread subscription asked only
/// `#e = root`, which matches just the top-level comment — everything below
/// the first reply never arrived. The fix pairs a `#E` root-scope filter with
/// the `#e` filter in one REQ and accepts either proof in the ingest guard.
@MainActor
struct LiveNip22ThreadTests {

    private static let rootId = "000007eb84fd9914f924d804a129594a8d7da143a24b305fe24996933ee31b68"
    private static let topLevelCommentId = "a55ad0ed46b97475103a60455f888d78743c0cd34f1486775866785e4809e1b3"
    /// The comment's author, as every real `ThreadRoute` hands it over —
    /// `resolveRelays` needs it to reach the author's outbox, where this
    /// thread actually lives (nos.lol / nostr.wine / ditto.pub).
    private static let authorHint = "3f770d65d3a764a9c5cb503ae123e62ec7598ad035d836e2a810f3877a745b24"
    private static let nestedCommentIds = [
        "00000817440a3658f51f70404dfa4264f7ed7c05322d82b9bafc316cc1bd9cd6",
        "01703a8354d7227fc5c732b72d2bba21fbca2cf0c432765b17c235c3ab8b6810",
        "0000079296cbf4bc3b26b90adc84472d109d302a5ac8feda86d40b625d88d2b1",
    ]

    @Test func threadViewModel_streamsTheWholeCommentChain() async throws {
        let keypair = Keypair(privkey: String(repeating: "1", count: 64),
                              pubkey: String(repeating: "a", count: 64))
        // Seed the thread at the top-level comment, the way a notification or
        // the search id-lookup deep-links into it.
        let vm = ThreadViewModel(seedEventId: Self.topLevelCommentId, authorHint: Self.authorHint, keypair: keypair)
        defer { vm.stop() }
        await vm.start()

        // The reply stream runs in 12s windows and re-opens once the root
        // resolves; give the chain two windows plus relay slop to land.
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline,
              !Set(Self.nestedCommentIds).isSubset(of: Set(vm.nestedReplies.map(\.id))) {
            try await Task.sleep(for: .seconds(2))
        }

        let rendered = Set(vm.nestedReplies.map(\.id))
        print("LIVE-NIP22 root=\(vm.rootId.prefix(8)) rendered=\(rendered.map { $0.prefix(8) }.sorted())")
        // The seed comment re-roots to the kind-1 note; the whole tree renders
        // under it — the top-level comment AND every nested reply below it.
        #expect(vm.rootId == Self.rootId, "seed comment should re-root to its E anchor")
        #expect(rendered.contains(Self.topLevelCommentId), "top-level comment missing")
        for id in Self.nestedCommentIds {
            #expect(rendered.contains(id), "nested comment \(id.prefix(8)) missing — rendered: \(rendered.map { $0.prefix(8) })")
        }
        // And the nesting is real: each comment hangs off the comment it answered.
        for row in vm.nestedReplies where Self.nestedCommentIds.contains(row.id) {
            #expect(row.depth >= 1, "\(row.id.prefix(8)) should be nested below the top-level comment")
        }
    }
}
