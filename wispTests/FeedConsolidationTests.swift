import Foundation
import Testing
@testable import wisp

/// Covers the repost-consolidation + merge helpers in `FeedViewModel` that the
/// scroll-perf work touched: the per-flush `mergeSortedDesc`, `consolidateReposts`,
/// and the now-cached `innerRepostRef`. These are MainActor-isolated statics
/// (the type defaults to MainActor isolation), so the suite is too.
@MainActor
@Suite struct FeedConsolidationTests {

    private func event(
        id: String,
        kind: Int,
        createdAt: Int,
        tags: [[String]] = [],
        content: String = ""
    ) -> NostrEvent {
        NostrEvent(id: id, pubkey: "author-\(id)", kind: kind, createdAt: createdAt, tags: tags, content: content, sig: "")
    }

    // MARK: - mergeSortedDesc

    @Test func mergeSortedDescProducesDescendingMerge() {
        let a = [event(id: "a3", kind: 1, createdAt: 300), event(id: "a1", kind: 1, createdAt: 100)]
        let b = [event(id: "b2", kind: 1, createdAt: 200), event(id: "b0", kind: 1, createdAt: 50)]
        let merged = FeedViewModel.mergeSortedDesc(a, b)
        #expect(merged.map(\.createdAt) == [300, 200, 100, 50])
    }

    // MARK: - consolidateReposts

    @Test func repostSupersedesOriginalNote() {
        let original = event(id: "cons-note1", kind: 1, createdAt: 100)
        let repost = event(
            id: "cons-repost1",
            kind: 6,
            createdAt: 200,
            content: #"{"id":"cons-note1","pubkey":"orig-author"}"#
        )
        let out = FeedViewModel.consolidateReposts(FeedViewModel.mergeSortedDesc([repost], [original]))
        // The kind-1 original is dropped (a kept repost covers it); the repost remains.
        #expect(out.map(\.id) == ["cons-repost1"])
    }

    @Test func newestRepostWinsPerInnerId() {
        let older = event(id: "cons-r-old", kind: 6, createdAt: 200, content: #"{"id":"cons-shared","pubkey":"x"}"#)
        let newer = event(id: "cons-r-new", kind: 6, createdAt: 300, content: #"{"id":"cons-shared","pubkey":"x"}"#)
        let out = FeedViewModel.consolidateReposts([newer, older])
        #expect(out.map(\.id) == ["cons-r-new"])
    }

    @Test func nonRepostEventsPassThrough() {
        let a = event(id: "pt-a", kind: 1, createdAt: 300)
        let b = event(id: "pt-b", kind: 1, createdAt: 200)
        let out = FeedViewModel.consolidateReposts([a, b])
        #expect(out.map(\.id) == ["pt-a", "pt-b"])
    }

    // MARK: - innerRepostRef (now cache-backed)

    @Test func innerRepostRefParsesEmbeddedJSON() {
        let repost = event(
            id: "ref-json",
            kind: 6,
            createdAt: 10,
            content: #"{"id":"inner-json","pubkey":"inner-author"}"#
        )
        let ref = FeedViewModel.innerRepostRef(of: repost)
        #expect(ref?.id == "inner-json")
        #expect(ref?.pubkey == "inner-author")
        // Second call hits the cache and must return the same value.
        let again = FeedViewModel.innerRepostRef(of: repost)
        #expect(again?.id == "inner-json")
        #expect(again?.pubkey == "inner-author")
    }

    @Test func innerRepostRefFallsBackToETag() {
        let repost = event(
            id: "ref-etag",
            kind: 6,
            createdAt: 10,
            tags: [["e", "inner-etag"], ["p", "inner-pk"]],
            content: ""
        )
        let ref = FeedViewModel.innerRepostRef(of: repost)
        #expect(ref?.id == "inner-etag")
        #expect(ref?.pubkey == "inner-pk")
    }

    @Test func innerRepostRefNilForNonRepost() {
        let note = event(id: "ref-note", kind: 1, createdAt: 10, content: "hello")
        #expect(FeedViewModel.innerRepostRef(of: note) == nil)
    }
}
