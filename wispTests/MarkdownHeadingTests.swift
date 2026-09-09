import Foundation
import Testing
@testable import wisp

/// Telling an ATX heading from a hashtag.
///
/// Long-form authors routinely close a post with a line of tags. Treating any
/// `#`-leading line as a heading rendered `#nostr` at the foot of an article
/// as a level-1 headline — louder than the article's own title.
struct MarkdownHeadingTests {

    // MARK: - Real headings

    @Test func hashFollowedBySpaceIsAHeading() {
        let h = MarkdownBlocks.atxHeading("# Introduction")
        #expect(h?.level == 1)
        #expect(h?.text == "Introduction")
    }

    @Test func levelsCountTheHashes() {
        #expect(MarkdownBlocks.atxHeading("## Two")?.level == 2)
        #expect(MarkdownBlocks.atxHeading("###### Six")?.level == 6)
    }

    /// Surplus hashes beyond six stay in the text, matching the Android port.
    @Test func beyondSixCapsAtSixAndKeepsTheRest() {
        let h = MarkdownBlocks.atxHeading("####### Seven")
        #expect(h?.level == 6)
        #expect(h?.text == "# Seven")
    }

    /// A bare `#` line is still a heading per CommonMark, just an empty one.
    @Test func bareHashIsAnEmptyHeading() {
        let h = MarkdownBlocks.atxHeading("#")
        #expect(h?.level == 1)
        #expect(h?.text == "")
    }

    // MARK: - Hashtags are not headings

    @Test func hashtagIsNotAHeading() {
        #expect(MarkdownBlocks.atxHeading("#nostr") == nil)
        #expect(MarkdownBlocks.atxHeading("#zapreads") == nil)
    }

    @Test func multipleHashtagsOnOneLineAreNotAHeading() {
        #expect(MarkdownBlocks.atxHeading("#nostr #bitcoin #zapreads") == nil)
    }

    // MARK: - Through the block parser

    /// The tag line at the foot of an article stays prose.
    @Test func trailingTagLineParsesAsParagraph() {
        let blocks = MarkdownBlocks.parse("Some closing thoughts.\n\n#nostr #bitcoin")
        guard case .paragraph(let text)? = blocks.last else {
            Issue.record("expected a paragraph, got \(String(describing: blocks.last))")
            return
        }
        #expect(text == "#nostr #bitcoin")
    }

    @Test func realHeadingStillParsesAsHeading() {
        let blocks = MarkdownBlocks.parse("# Title\n\nBody text.")
        guard case .heading(let level, let text)? = blocks.first else {
            Issue.record("expected a heading, got \(String(describing: blocks.first))")
            return
        }
        #expect(level == 1)
        #expect(text == "Title")
    }

    /// A hashtag directly under prose belongs to that paragraph rather than
    /// splitting it — the paragraph terminator uses the same rule.
    @Test func hashtagDoesNotBreakAParagraph() {
        let blocks = MarkdownBlocks.parse("Closing line\n#nostr")
        #expect(blocks.count == 1)
        guard case .paragraph(let text)? = blocks.first else {
            Issue.record("expected one paragraph, got \(blocks)")
            return
        }
        #expect(text.contains("Closing line"))
        #expect(text.contains("#nostr"))
    }
}
