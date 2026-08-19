import Foundation
import Testing
@testable import wisp

/// Block-segment adjacency: blank lines around cards (invoice, quote, media,
/// link preview) must not survive as text rows — each one renders as a full
/// empty line inside the UITextView plus VStack spacing on both sides, which
/// reads as a large gap between the preceding element and the card.
struct ContentParserBlockSpacingTests {

    /// Fixture invoice for parser-level tests. `Bolt11.decode` doesn't verify
    /// the bech32 checksum, but it does enforce the charset and a ≥111-symbol
    /// data part, and the parser only emits `.lightningInvoice` on a
    /// successful decode — so a deterministic run of valid charset symbols
    /// (the charset contains no `1`, keeping the separator unambiguous) is
    /// enough. These tests exercise segment splitting, not TLV parsing.
    private static let invoice = "lnbc1" + String(
        repeating: "qpzry9x8gf2tvdw0s3jn54khce6mua7l", count: 6
    )

    /// Real bech32 nevent (Nip19 verifies checksums), so the parser actually
    /// classifies it as `.nostrNote` rather than leaving it as text.
    private static let quote = Nip19.neventEncode(
        eventId32: [UInt8](repeating: 0xab, count: 32)
    ) ?? ""

    @Test func textBeforeInvoiceKeepsNoTrailingBlankLine() throws {
        let segments = ContentParser.parse(content: "please pay\n\n\(Self.invoice)", tags: [])
        let first = try #require(segments.first)
        guard case .text(let t) = first else {
            Issue.record("expected leading text, got \(first)")
            return
        }
        // The single kept trailing "\n" of the old trim was an empty line of
        // height inside the text view — the reported gap.
        #expect(t == "please pay")
        guard case .lightningInvoice = segments.last else {
            Issue.record("expected trailing invoice, got \(String(describing: segments.last))")
            return
        }
    }

    @Test func quoteBeforeInvoiceDropsBlankLineRow() throws {
        #expect(!Self.quote.isEmpty)
        let segments = ContentParser.parse(
            content: "check this\n\n\(Self.quote)\n\n\(Self.invoice)", tags: []
        )
        // No empty text segment may survive between the two cards.
        #expect(segments.count == 3)
        guard case .text(let t) = segments.first else { return }
        #expect(t == "check this")
        if case .nostrNote = segments[1] {} else {
            Issue.record("expected quote in the middle, got \(segments[1])")
        }
    }

    @Test func textAfterInvoiceDropsLeadingBlankLines() throws {
        let segments = ContentParser.parse(content: "\(Self.invoice)\n\nthanks", tags: [])
        #expect(segments.count == 2)
        guard case .lightningInvoice = segments.first else {
            Issue.record("expected leading invoice")
            return
        }
        guard case .text(let t) = segments.last else { return }
        #expect(t == "thanks")
    }

    @Test func singleNewlineBeforeInvoiceAlsoTightened() throws {
        let segments = ContentParser.parse(content: "pay\n\(Self.invoice)", tags: [])
        guard case .text(let t) = segments.first else { return }
        #expect(t == "pay")
    }

    @Test func textBeforeMediaTightensTheSameWay() throws {
        let segments = ContentParser.parse(
            content: "gm\n\nhttps://i.nostr.build/abc.png", tags: []
        )
        guard case .text(let t) = segments.first else { return }
        #expect(t == "gm")
    }

    // MARK: - Non-regressions

    @Test func plainParagraphBreaksAreUntouched() throws {
        // No blocks anywhere — the user's paragraph structure must survive.
        let segments = ContentParser.parse(content: "a\n\nb", tags: [])
        guard case .text(let t) = try #require(segments.first) else { return }
        #expect(segments.count == 1)
        #expect(t == "a\n\nb")
    }

    @Test func inlineJoinerSpaceBetweenEmojiSurvives() throws {
        // A whitespace-only run between two INLINE segments is a joiner (the
        // space between two custom-emoji pills), not a blank-line gap — it
        // must survive even though whitespace-only runs adjacent to blocks
        // are pruned.
        let emojiMap = [
            "wisp": "https://example.invalid/wisp.png",
            "zap": "https://example.invalid/zap.png"
        ]
        let segments = ContentParser.parse(
            content: ":wisp: :zap:", tags: [], emojiMap: emojiMap
        )
        #expect(segments.count == 3)
        guard case .customEmoji = segments[0] else { Issue.record("expected emoji first"); return }
        guard case .text(let t) = segments[1] else { Issue.record("expected joiner text"); return }
        #expect(t == " ")
        guard case .customEmoji = segments[2] else { Issue.record("expected emoji last"); return }
    }

    @Test func textBetweenTwoBlocksKeepsItsContent() throws {
        // Real content sandwiched between cards is trimmed of blank lines on
        // both sides but never dropped.
        let segments = ContentParser.parse(
            content: "\(Self.quote)\n\nsee below\n\n\(Self.invoice)", tags: []
        )
        #expect(segments.count == 3)
        guard case .text(let t) = segments[1] else { Issue.record("expected middle text"); return }
        #expect(t == "see below")
    }
}
