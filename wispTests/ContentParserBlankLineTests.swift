import Foundation
import Testing
@testable import wisp

/// Pass 6 of `ContentParser`: surplus blank lines inside a post's prose.
///
/// A post padded with trailing newlines, or paragraphs split by three or
/// more, renders every extra newline as a real empty line — a gap the reader
/// can't collapse and the author usually didn't ask for. One blank line is
/// the paragraph break and survives; single newlines are always left alone.
///
/// The block-adjacent case (blank lines hugging an image / invoice / quote
/// card) is pass 5's job and is covered by `ContentParserBlockSpacingTests`.
struct ContentParserBlankLineTests {

    private func soleText(_ content: String) throws -> String {
        let segments = ContentParser.parse(content: content, tags: [])
        #expect(segments.count == 1)
        guard case .text(let t) = try #require(segments.first) else {
            Issue.record("expected a single text segment, got \(segments)")
            return ""
        }
        return t
    }

    // MARK: - Surplus is removed

    @Test func trailingNewlinesAreDropped() throws {
        #expect(try soleText("gm\n\n\n") == "gm")
        #expect(try soleText("gm\n") == "gm")
    }

    @Test func leadingBlankLinesAreDropped() throws {
        #expect(try soleText("\n\n\ngm") == "gm")
    }

    @Test func surplusBetweenParagraphsCollapsesToOneBlankLine() throws {
        #expect(try soleText("first\n\n\n\n\nsecond") == "first\n\nsecond")
    }

    /// Clients that hard-wrap often leave spaces on the "blank" lines, so a
    /// pure newline-run check would miss the most common real-world shape.
    @Test func blankLinesCarryingWhitespaceStillCollapse() throws {
        #expect(try soleText("first\n   \n \t \nsecond") == "first\n\nsecond")
        #expect(try soleText("gm\n   \n  ") == "gm")
    }

    @Test func whitespaceOnlyPostProducesNoTextSegment() throws {
        #expect(ContentParser.parse(content: "\n\n  \n", tags: []).isEmpty)
    }

    // MARK: - Meaningful structure survives

    @Test func singleNewlinesAreNeverTouched() throws {
        // A stanza / address / hand-made list: every break is intentional.
        #expect(try soleText("one\ntwo\nthree") == "one\ntwo\nthree")
    }

    @Test func oneBlankLineParagraphBreakSurvives() throws {
        #expect(try soleText("first\n\nsecond") == "first\n\nsecond")
    }

    /// Indentation on the first visible line isn't a blank line — only the
    /// newlines before it are stripped.
    @Test func indentAfterLeadingBlankLinesSurvives() throws {
        #expect(try soleText("\n\n    indented") == "    indented")
    }

    // MARK: - Interaction with inline segments

    /// The edge trims apply to the ends of the POST, not of every text run —
    /// the breaks around an inline hashtag are interior structure.
    @Test func breaksAroundAnInlineHashtagSurvive() throws {
        let segments = ContentParser.parse(content: "before\n\n#nostr\n\nafter", tags: [])
        #expect(segments.count == 3)
        guard case .text(let head) = segments[0] else { Issue.record("expected leading text"); return }
        guard case .hashtag = segments[1] else { Issue.record("expected hashtag"); return }
        guard case .text(let tail) = segments[2] else { Issue.record("expected trailing text"); return }
        #expect(head == "before\n\n")
        #expect(tail == "\n\nafter")
    }

    /// Trailing padding after the post's last inline segment still goes.
    @Test func trailingPaddingAfterHashtagIsDropped() throws {
        let segments = ContentParser.parse(content: "gm #nostr\n\n\n", tags: [])
        #expect(segments.count == 2)
        guard case .hashtag = segments.last else {
            Issue.record("expected the hashtag to end the post, got \(segments)")
            return
        }
    }

    /// Opting out (used by the mention scanner, which only wants pubkeys)
    /// leaves the raw text exactly as published.
    @Test func trimBlankLinesFalseLeavesTextAlone() throws {
        let segments = ContentParser.parse(
            content: "gm\n\n\n\nbye\n\n", tags: [], trimBlankLines: false
        )
        guard case .text(let t) = try #require(segments.first) else { return }
        #expect(t == "gm\n\n\n\nbye\n\n")
    }
}

/// The other half: Wisp shouldn't *emit* the padding in the first place.
/// `ContentParser` pass 6 only tidies what a Wisp reader sees — a note
/// published with trailing newlines still renders with real empty lines in
/// every other client.
struct ComposeTrailingBlankLineTests {

    @Test func trailingNewlinesAreTrimmedBeforePublish() {
        #expect(ComposeViewModel.trimTrailingBlankLines("gm\n\n\n") == "gm")
        #expect(ComposeViewModel.trimTrailingBlankLines("gm\n  \n\t") == "gm")
    }

    @Test func interiorSpacingIsTheAuthorsToKeep() {
        // Only the tail is tidied — the middle of a post is never rewritten.
        #expect(
            ComposeViewModel.trimTrailingBlankLines("one\n\n\n\ntwo\n\n")
                == "one\n\n\n\ntwo"
        )
    }

    @Test func postWithoutPaddingIsUnchanged() {
        #expect(ComposeViewModel.trimTrailingBlankLines("gm") == "gm")
        #expect(ComposeViewModel.trimTrailingBlankLines("one\ntwo") == "one\ntwo")
    }

    @Test func allWhitespaceCollapsesToEmpty() {
        #expect(ComposeViewModel.trimTrailingBlankLines("\n\n  \n").isEmpty)
    }
}
