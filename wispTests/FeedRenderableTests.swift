import Foundation
import Testing
@testable import wisp

/// Locks the feed's top-level-row gate, `FeedViewModel.isFeedRenderable`,
/// across both states of the "Include replies in feeds" setting. The method
/// is `nonisolated static`, so the suite needs no actor isolation.
@Suite struct FeedRenderableTests {

    private func event(kind: Int, tags: [[String]] = []) -> NostrEvent {
        NostrEvent(id: "id", pubkey: "author", kind: kind, createdAt: 0, tags: tags, content: "", sig: "")
    }

    @Test func rootNotePassesEitherWay() {
        let root = event(kind: 1)
        #expect(FeedViewModel.isFeedRenderable(root, includeReplies: false))
        #expect(FeedViewModel.isFeedRenderable(root, includeReplies: true))
    }

    @Test func replyPassesOnlyWhenIncluded() {
        let reply = event(kind: 1, tags: [["e", "parent", "", "reply"]])
        #expect(!FeedViewModel.isFeedRenderable(reply, includeReplies: false))
        #expect(FeedViewModel.isFeedRenderable(reply, includeReplies: true))
    }

    /// A kind-1 quoting another note via a mention-marked e-tag is not a root
    /// note, so it rides the same gate as replies.
    @Test func mentionTaggedNoteFollowsReplyGate() {
        let quote = event(kind: 1, tags: [["e", "quoted", "", "mention"]])
        #expect(!FeedViewModel.isFeedRenderable(quote, includeReplies: false))
        #expect(FeedViewModel.isFeedRenderable(quote, includeReplies: true))
    }

    @Test func repostAndGalleryAndPollsPassEitherWay() {
        for kind in [6, 20, Nip88.kindPoll, Nip69.kindZapPoll] {
            let e = event(kind: kind, tags: [["e", "inner"]])
            #expect(FeedViewModel.isFeedRenderable(e, includeReplies: false))
            #expect(FeedViewModel.isFeedRenderable(e, includeReplies: true))
        }
    }

    /// Kinds the follows feed never surfaces as rows (e.g. video, reaction)
    /// stay excluded regardless of the replies setting.
    @Test func nonFeedKindsStayExcluded() {
        for kind in [7, 21, 22, 30023] {
            let e = event(kind: kind)
            #expect(!FeedViewModel.isFeedRenderable(e, includeReplies: false))
            #expect(!FeedViewModel.isFeedRenderable(e, includeReplies: true))
        }
    }
}
