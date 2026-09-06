import Foundation
import Testing
@testable import wisp

/// The feed's content filter, cycled by the grid button beside the avatar.
struct FeedContentFilterTests {

    // MARK: - The cycle

    /// Every filter is reachable by tapping, and tapping enough times returns
    /// to the start — a case left out of `next` would be unreachable even
    /// though `allCases` lists it.
    @Test func cycleVisitsEveryFilterAndWraps() {
        var seen: [FeedContentFilter] = []
        var current = FeedContentFilter.all
        for _ in 0..<FeedContentFilter.allCases.count {
            seen.append(current)
            current = current.next
        }
        #expect(current == .all)
        #expect(Set(seen) == Set(FeedContentFilter.allCases))
    }

    @Test func articlesSitsBetweenNotesAndGallery() {
        #expect(FeedContentFilter.notes.next == .articles)
        #expect(FeedContentFilter.articles.next == .gallery)
    }

    // MARK: - What each filter accepts

    @Test func articlesAcceptsOnlyLongForm() {
        #expect(FeedContentFilter.articles.accepts(kind: 30023))
        #expect(!FeedContentFilter.articles.accepts(kind: 1))
        #expect(!FeedContentFilter.articles.accepts(kind: 6))
        #expect(!FeedContentFilter.articles.accepts(kind: 20))
    }

    /// Articles used to be folded in here. With a filter of their own, leaving
    /// them would make two of the options overlap.
    @Test func notesNoLongerAcceptsArticles() {
        #expect(FeedContentFilter.notes.accepts(kind: 1))
        #expect(FeedContentFilter.notes.accepts(kind: 6))
        #expect(!FeedContentFilter.notes.accepts(kind: 30023))
    }

    @Test func galleryCoversPictureVideoAndAudio() {
        #expect(FeedContentFilter.gallery.accepts(kind: 20))
        #expect(FeedContentFilter.gallery.accepts(kind: 21))
        #expect(FeedContentFilter.gallery.accepts(kind: 22))
    }

    @Test func allAcceptsEverything() {
        for kind in [1, 6, 20, 21, 22, 30023, Nip88.kindPoll] {
            #expect(FeedContentFilter.all.accepts(kind: kind))
        }
    }

    /// No kind should land in two filters, or the same post appears under two
    /// different labels.
    @Test func filtersDoNotOverlap() {
        let kinds = [1, 6, 20, 21, 22, 30023, Nip88.kindPoll]
        for kind in kinds {
            let matches = FeedContentFilter.allCases
                .filter { $0 != .all && $0.accepts(kind: kind) }
            #expect(matches.count <= 1, "kind \(kind) matched \(matches)")
        }
    }

    // MARK: - Reaching the feed at all

    /// A filter is only as good as what survives ingest. Long-form was
    /// dropped by `isFeedRenderable`, so it never reached the feed no matter
    /// what was subscribed to.
    @Test func longFormReachesTheFeed() {
        let article = NostrEvent(
            id: "id", pubkey: "pk", kind: 30023, createdAt: 0,
            tags: [], content: "", sig: ""
        )
        #expect(FeedViewModel.isFeedRenderable(article, includeReplies: false))
    }

    /// Video and audio gallery kinds have no card yet, so they stay out —
    /// admitting them would add rows nothing can draw. The `gallery` filter
    /// still names them for when that changes.
    @Test func videoAndAudioStayOutUntilTheyCanBeDrawn() {
        for kind in [21, 22] {
            let event = NostrEvent(
                id: "id", pubkey: "pk", kind: kind, createdAt: 0,
                tags: [], content: "", sig: ""
            )
            #expect(!FeedViewModel.isFeedRenderable(event, includeReplies: false))
        }
    }

    /// NIP-22 comments stay out — they belong on the profile Comments tab,
    /// not the timeline.
    @Test func commentsStayOutOfTheFeed() {
        let comment = NostrEvent(
            id: "id", pubkey: "pk", kind: 1111, createdAt: 0,
            tags: [], content: "", sig: ""
        )
        #expect(!FeedViewModel.isFeedRenderable(comment, includeReplies: true))
    }

    // MARK: - Presentation

    @Test func everyFilterHasAnIconAndEmptyState() {
        for filter in FeedContentFilter.allCases {
            #expect(!filter.iconName.isEmpty)
            #expect(!filter.emptyStateCaption.isEmpty)
        }
    }

    /// The icons distinguish the filters — a repeated glyph makes the button
    /// look stuck.
    @Test func iconsAreDistinct() {
        let icons = FeedContentFilter.allCases.map(\.iconName)
        #expect(Set(icons).count == icons.count)
    }
}
