import Testing
@testable import wisp

struct MarkdownBlocksTests {

    // MARK: - Headings

    @Test func headingLevels() {
        let blocks = MarkdownBlocks.parse("# One\n## Two\n###### Six\n####### Seven")
        #expect(blocks == [
            .heading(level: 1, text: "One"),
            .heading(level: 2, text: "Two"),
            .heading(level: 6, text: "Six"),
            // Level caps at 6; the surplus '#' stays in the text (Android parity).
            .heading(level: 6, text: "# Seven")
        ])
    }

    // MARK: - Paragraphs

    @Test func paragraphJoinsConsecutiveLines() {
        let blocks = MarkdownBlocks.parse("line one\nline two\n\nsecond para")
        #expect(blocks == [
            .paragraph("line one line two"),
            .paragraph("second para")
        ])
    }

    @Test func paragraphBreaksOnBlockStarters() {
        let blocks = MarkdownBlocks.parse("text\n# heading\nmore")
        #expect(blocks == [
            .paragraph("text"),
            .heading(level: 1, text: "heading"),
            .paragraph("more")
        ])
    }

    @Test func inlineImagesAreExtractedFromParagraphs() {
        let blocks = MarkdownBlocks.parse("before ![alt text](https://x.com/a.png) after")
        #expect(blocks == [
            .paragraph("before  after"),
            .image(url: "https://x.com/a.png", alt: "alt text")
        ])
    }

    @Test func paragraphThatIsOnlyAnInlineImageEmitsNoEmptyParagraph() {
        // The image regex requires the whole line, so a line with two images
        // is a paragraph whose cleaned text is empty.
        let blocks = MarkdownBlocks.parse("![a](https://x.com/a.png) ![b](https://x.com/b.png)")
        #expect(blocks == [
            .image(url: "https://x.com/a.png", alt: "a"),
            .image(url: "https://x.com/b.png", alt: "b")
        ])
    }

    // MARK: - Standalone images

    @Test func standaloneImageLine() {
        let blocks = MarkdownBlocks.parse("![cover](https://x.com/img.jpg)")
        #expect(blocks == [.image(url: "https://x.com/img.jpg", alt: "cover")])
    }

    @Test func standaloneImageWithTitleAndEmptyAlt() {
        let blocks = MarkdownBlocks.parse("![](https://x.com/img.jpg \"a title\")")
        #expect(blocks == [.image(url: "https://x.com/img.jpg", alt: nil)])
    }

    // MARK: - Code blocks

    @Test func fencedCodeWithLanguage() {
        let blocks = MarkdownBlocks.parse("```swift\nlet x = 1\nlet y = 2\n```")
        #expect(blocks == [.codeBlock(code: "let x = 1\nlet y = 2", language: "swift")])
    }

    @Test func fencedCodeWithoutLanguageOrClosingFence() {
        let blocks = MarkdownBlocks.parse("```\ncode line")
        #expect(blocks == [.codeBlock(code: "code line", language: nil)])
    }

    @Test func codeBlockPreservesBlankAndMarkupLines() {
        let blocks = MarkdownBlocks.parse("```\n# not a heading\n\n> not a quote\n```")
        #expect(blocks == [.codeBlock(code: "# not a heading\n\n> not a quote", language: nil)])
    }

    // MARK: - Blockquotes

    @Test func blockQuoteJoinsLines() {
        let blocks = MarkdownBlocks.parse("> first\n> second")
        #expect(blocks == [.blockQuote("first second")])
    }

    @Test func blockQuoteAbsorbsContinuationLines() {
        // Android quirk preserved: a non-empty line right after a `>` line is
        // pulled into the quote even without the marker.
        let blocks = MarkdownBlocks.parse("> quoted\ncontinuation\n\nafter")
        #expect(blocks == [
            .blockQuote("quoted continuation"),
            .paragraph("after")
        ])
    }

    // MARK: - Horizontal rules

    @Test func horizontalRuleVariants() {
        #expect(MarkdownBlocks.parse("---") == [.horizontalRule])
        #expect(MarkdownBlocks.parse("****") == [.horizontalRule])
        #expect(MarkdownBlocks.parse("___") == [.horizontalRule])
        #expect(MarkdownBlocks.parse("--") == [.paragraph("--")])
    }

    // MARK: - Nostr embeds

    @Test func standaloneNostrEntityNormalizesPrefix() {
        let bare = "nevent1qqs0123456789abcdef"
        #expect(MarkdownBlocks.parse(bare) == [.nostrEmbed(content: "nostr:\(bare)")])

        let prefixed = "nostr:naddr1qqs0123456789abcdef"
        #expect(MarkdownBlocks.parse(prefixed) == [.nostrEmbed(content: prefixed)])
    }

    @Test func inlineNostrEntityStaysInParagraph() {
        let blocks = MarkdownBlocks.parse("see nostr:note1abcdef0123456789 for details")
        #expect(blocks == [.paragraph("see nostr:note1abcdef0123456789 for details")])
    }

    // MARK: - shortenNostrEntity

    @Test func shortenNostrEntityRules() {
        #expect(MarkdownBlocks.shortenNostrEntity("nostr:npub1qqqqqqqqqqqqqqqq") == "@npub1qqqqq...")
        #expect(MarkdownBlocks.shortenNostrEntity("nprofile1qqqqqqqqqqqq") == "@nprofile1q...")
        #expect(MarkdownBlocks.shortenNostrEntity("nostr:nevent1qqqqqqqqqqqqqqq") == "nevent1qqqqq...")
        #expect(MarkdownBlocks.shortenNostrEntity("note1qqqqqqqqqqqqqqqq") == "note1qqqqqqq...")
    }

    // MARK: - Mixed document

    @Test func mixedDocument() {
        let md = """
        # Title

        Intro paragraph
        with two lines.

        ![hero](https://x.com/hero.png)

        > A quote

        ---

        ```js
        console.log(1)
        ```

        nostr:nevent1qqs0123456789abcdef

        Closing words.
        """
        let blocks = MarkdownBlocks.parse(md)
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Intro paragraph with two lines."),
            .image(url: "https://x.com/hero.png", alt: "hero"),
            .blockQuote("A quote"),
            .horizontalRule,
            .codeBlock(code: "console.log(1)", language: "js"),
            .nostrEmbed(content: "nostr:nevent1qqs0123456789abcdef"),
            .paragraph("Closing words.")
        ])
    }
}
