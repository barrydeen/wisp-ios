import Testing
import Foundation
@testable import wisp

struct LinkPreviewUnescapeTests {

    // MARK: - numeric character references

    @Test func decodesPaddedDecimalApostrophe() {
        // bitcoinship.show serves og:title with the zero-padded form.
        #expect(LinkPreviewService.unescapeHtml("you&#039;re building") == "you're building")
    }

    @Test func decodesDecimalAndHexForms() {
        #expect(LinkPreviewService.unescapeHtml("&#39;") == "'")
        #expect(LinkPreviewService.unescapeHtml("&#x27;") == "'")
        #expect(LinkPreviewService.unescapeHtml("&#X27;") == "'")
        #expect(LinkPreviewService.unescapeHtml("&#8217;") == "\u{2019}")
        #expect(LinkPreviewService.unescapeHtml("&#x2019;") == "\u{2019}")
        #expect(LinkPreviewService.unescapeHtml("&#x1F600;") == "\u{1F600}")
    }

    // MARK: - named entities

    @Test func decodesNamedEntities() {
        #expect(LinkPreviewService.unescapeHtml("a &amp; b &lt;c&gt; &quot;q&quot; &apos;x&apos;") == "a & b <c> \"q\" 'x'")
        #expect(LinkPreviewService.unescapeHtml("BTC &ndash; Lightning&hellip;") == "BTC \u{2013} Lightning\u{2026}")
        #expect(LinkPreviewService.unescapeHtml("it&rsquo;s &ldquo;on&rdquo;") == "it\u{2019}s \u{201C}on\u{201D}")
    }

    // MARK: - single-pass decoding

    @Test func ampDecodesOnlyOnce() {
        #expect(LinkPreviewService.unescapeHtml("&amp;#039;") == "&#039;")
        #expect(LinkPreviewService.unescapeHtml("&amp;amp;") == "&amp;")
    }

    // MARK: - literal passthrough

    @Test func leavesStrayAmpersandsAndUnknownEntitiesAlone() {
        #expect(LinkPreviewService.unescapeHtml("fish & chips") == "fish & chips")
        #expect(LinkPreviewService.unescapeHtml("a &notanentity; b") == "a &notanentity; b")
        #expect(LinkPreviewService.unescapeHtml("&#; &#x; &#zz;") == "&#; &#x; &#zz;")
        #expect(LinkPreviewService.unescapeHtml("no entities here") == "no entities here")
    }

    @Test func passesThroughOutOfRangeScalarRefs() {
        // Surrogates and values above U+10FFFF can't form a valid scalar.
        #expect(LinkPreviewService.unescapeHtml("&#xD800;") == "&#xD800;")
        #expect(LinkPreviewService.unescapeHtml("&#x110000;") == "&#x110000;")
    }
}
