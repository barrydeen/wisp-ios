import Foundation
import Testing
@testable import wisp

/// Bare-domain linkification (`see zap.cooking/pow` → tappable link).
///
/// Ports the cross-platform contract from the web fix (zapcooking/frontend
/// "linkify bare domains on the full IANA TLD list"):
/// - the TLD gate is the full IANA list (`TldList`), not a hand-trimmed set
/// - a bare match is an inference → always `.inlineLink` with a synthesized
///   `https://`, never a `.link` preview card / media embed
/// - explicit URLs and nostr refs claim their spans first (no double-match,
///   scheme-less blossom URLs stay one whole link)
/// - no fuzzy email, trailing punctuation stays out
struct ContentParserBareDomainTests {

    private func segments(_ content: String) -> [ContentSegment] {
        ContentParser.parse(content: content, tags: [])
    }

    private func inlineLinks(_ content: String) -> [String] {
        segments(content).compactMap {
            if case .inlineLink(let url) = $0 { return url } else { return nil }
        }
    }

    @Test func bareDomainWithPathLinksWholeThing() {
        let urls = inlineLinks("see zap.cooking/pow for more")
        #expect(urls == ["https://zap.cooking/pow"])
    }

    @Test func modernGTLDsLinkify() {
        #expect(inlineLinks("check jumble.social/notes") == ["https://jumble.social/notes"])
        #expect(inlineLinks("photos at oven.to") == ["https://oven.to"])
        #expect(inlineLinks("hosted at something.blossom.band/img.png") == ["https://something.blossom.band/img.png"])
    }

    @Test func wwwPrefixedDomainLinks() {
        #expect(inlineLinks("go to www.zap.cooking now") == ["https://www.zap.cooking"])
    }

    @Test func bareMatchIsNeverAPreviewCard() {
        // A bare domain alone on its own line is exactly where the explicit-URL
        // pipeline would grant a block-level preview card — bare matches must
        // stay inline even there.
        let segs = segments("zap.cooking/pow")
        guard case .inlineLink(let url)? = segs.first else {
            Issue.record("expected inlineLink, got \(segs)")
            return
        }
        #expect(url == "https://zap.cooking/pow")
        #expect(!segs.contains { if case .link = $0 { return true } else { return false } })
    }

    @Test func bareMatchIsNeverAMediaEmbed() {
        // Even an image-looking path stays an inline link: a fuzzy match is an
        // inference, so it must never load a media embed.
        let urls = inlineLinks("served from files.example.com/pic.jpg")
        #expect(urls == ["https://files.example.com/pic.jpg"])
        #expect(!segments("files.example.com/pic.jpg").contains {
            if case .image = $0 { return true } else { return false }
        })
    }

    @Test func explicitUrlIsNotDoubleClaimed() {
        let segs = segments("see https://zap.cooking/pow")
        let linkish = segs.filter {
            if case .inlineLink = $0 { return true }
            if case .link = $0 { return true }
            return false
        }
        #expect(linkish.count == 1)
    }

    @Test func nonTLDLookalikesStayPlainText() {
        for content in ["bake at 350.degreesf", "add 1.5 cups flour"] {
            #expect(segments(content).count == 1, "content: \(content)")
            guard case .text? = segments(content).first else {
                Issue.record("expected plain text for \(content)")
                continue
            }
        }
    }

    @Test func trailingPunctuationStaysOutOfTheHref() {
        // The regex's path part swallows the comma; the href must not keep it.
        #expect(inlineLinks("see jumble.social/notes, please") == ["https://jumble.social/notes"])
        #expect(inlineLinks("see jumble.social, please") == ["https://jumble.social"])
    }

    @Test func nostrRefAndBareDomainCoexist() {
        let content = "npub1hjlev3xn736aqr4ecmjxwwzuu9k523kp5fpz9n862s4lwah2h22sm2zg68 and zap.cooking/pow"
        let segs = segments(content)
        #expect(segs.contains { if case .nostrProfile = $0 { return true } else { return false } })
        #expect(inlineLinks(content) == ["https://zap.cooking/pow"])
    }

    @Test func schemelessBlossomUrlStaysOneWholeLink() {
        // npub + .blossom.band path: the npub alternative declines (its guard
        // rejects a following `.`), so the bare-domain alternative claims the
        // whole span — one link, the npub is not carved out.
        let content = "npub1hjlev3xn736aqr4ecmjxwwzuu9k523kp5fpz9n862s4lwah2h22sm2zg68.blossom.band/img.png"
        #expect(inlineLinks(content) == ["https://\(content)"])
    }

    @Test func emailIsNotFuzzilyLinked() {
        // The lightning-address pass may claim `chef@zap.cooking`; what must
        // not happen is the bare-domain scan carving `zap.cooking` out of it.
        let segs = segments("ping chef@zap.cooking please")
        #expect(!segs.contains { if case .inlineLink("https://zap.cooking") = $0 { return true } else { return false } })
    }

    @Test func idnDomainsLinkify() {
        #expect(inlineLinks("see пример.рф today") == ["https://пример.рф"])
    }

    @Test func dottedEmailLocalPartDoesNotSplit() {
        #expect(inlineLinks("first.last@zap.cooking") == [])
        #expect(inlineLinks("ping chef@zap.cooking please") == [])
    }

    @Test func trailingPunctuationIsPreservedAsText() {
        let segs = segments("see jumble.social/notes, please")
        guard case .inlineLink(let url) = segs[1] else {
            Issue.record("expected inlineLink at index 1, got \(segs)")
            return
        }
        #expect(url == "https://jumble.social/notes")
        #expect(segs.dropFirst(2).contains { if case .text(let t) = $0 { return t.hasPrefix(",") } else { return false } })
    }
}
