import Foundation
import Testing
@testable import wisp

/// An npub inside a URL — a Blossom server's `npub1….blossom.band` subdomain —
/// is a hostname, not a mention. `ContentParser` already excludes
/// dot-followed-by-letters from its npub pattern; these tests pin the same
/// rule on the composer's two mention paths, where an NSDataDetector URL
/// guard can't help because it doesn't detect scheme-less domains as links.
@MainActor
struct ComposeMentionTests {

    private static let npub = Nip19.npubEncode(pubkey: [UInt8](repeating: 0x5e, count: 32)) ?? ""
    private static let hash = "423a2423e536349b9adb8eaa1835f230b7a42798c5a181727b1b4601f96e0e91"

    private static var bareBlossomUrl: String { "\(npub).blossom.band/\(hash).png" }
    private static var httpsBlossomUrl: String { "https://\(npub).blossom.band/\(hash).png" }

    // MARK: - resolveNostrMentions (composer preview)

    @Test func previewDoesNotConvertNpubSubdomainToUsername() throws {
        #expect(!Self.npub.isEmpty)
        // The rendered note must keep the URL verbatim — before the fix the
        // preview showed "@username.blossom.band/…" instead.
        #expect(ComposeView.resolveNostrMentions(Self.bareBlossomUrl) == Self.bareBlossomUrl)
        #expect(ComposeView.resolveNostrMentions(Self.httpsBlossomUrl) == Self.httpsBlossomUrl)
        #expect(
            ComposeView.resolveNostrMentions("get it at \(Self.bareBlossomUrl) now")
                == "get it at \(Self.bareBlossomUrl) now"
        )
    }

    @Test func previewStillConvertsStandaloneNpub() throws {
        let resolved = ComposeView.resolveNostrMentions("ping \(Self.npub) please")
        // A real npub with no profile in the repo resolves to the short form —
        // either way it must NOT be the raw token.
        #expect(resolved != "ping \(Self.npub) please")
        #expect(resolved.hasPrefix("ping @"))
    }

    // MARK: - autoPrefixBareBech32 (publish path)

    @Test func publishPathDoesNotPrefixNpubInsideUrl() throws {
        // Before the fix this rewrote the URL to
        // "nostr:npub1….blossom.band/…" — corrupting the published content.
        #expect(ComposeViewModel.autoPrefixBareBech32(Self.bareBlossomUrl) == Self.bareBlossomUrl)
        #expect(ComposeViewModel.autoPrefixBareBech32(Self.httpsBlossomUrl) == Self.httpsBlossomUrl)
    }

    @Test func publishPathStillPrefixesStandaloneNpub() throws {
        #expect(
            ComposeViewModel.autoPrefixBareBech32("ping \(Self.npub) please")
                == "ping nostr:\(Self.npub) please"
        )
        // Sentence-final bech32 followed by ". " still prefixes — only
        // dot+letters (a domain continuation) is treated as a URL.
        #expect(
            ComposeViewModel.autoPrefixBareBech32("see \(Self.npub). thoughts?")
                == "see nostr:\(Self.npub). thoughts?"
        )
    }

    // MARK: - ContentParser parity

    @Test func parserNeverEmitsProfileForNpubSubdomain() throws {
        for url in [Self.bareBlossomUrl, Self.httpsBlossomUrl] {
            let segments = ContentParser.parse(content: "hosted at \(url)", tags: [])
            let hasProfile = segments.contains { seg in
                if case .nostrProfile = seg { return true }
                return false
            }
            #expect(!hasProfile, "parser converted a URL subdomain to a mention: \(url)")
        }
    }
}
