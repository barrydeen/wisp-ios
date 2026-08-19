import Foundation
import Testing
@testable import wisp

/// Locks the NIP-22 tag semantics `PostCardView` and the feed depend on:
/// uppercase tags name the root scope, lowercase name the immediate parent,
/// and an external (`I`) root is what earns a comment its link-preview card.
@Suite struct Nip22CommentTests {

    private func comment(_ tags: [[String]], kind: Int = 1111) -> NostrEvent {
        NostrEvent(id: "c", pubkey: "author", kind: kind, createdAt: 0,
                   tags: tags, content: "", sig: "")
    }

    /// The reported case: a comment on a web page carries I/K/i/k and no
    /// p-tags at all.
    @Test func webRootIsExtracted() {
        let url = "https://bitcoinmagazine.com/guides/some-article"
        let e = comment([["I", url], ["K", "web"], ["i", url], ["k", "web"]])
        let root = Nip22.externalRoot(of: e)
        #expect(root?.value == url)
        #expect(root?.kind == "web")
        #expect(root?.openableURL?.absoluteString == url)
        #expect(root?.displayHost == "bitcoinmagazine.com")
    }

    /// `www.` is stripped so the source label reads as the brand.
    @Test func displayHostDropsWWW() {
        let e = comment([["I", "https://www.example.com/a"], ["K", "web"]])
        #expect(Nip22.externalRoot(of: e)?.displayHost == "example.com")
    }

    /// A comment rooted on a nostr event must NOT produce an external ref —
    /// it already renders with its parent inline.
    @Test func eventRootedCommentHasNoExternalRoot() {
        let e = comment([
            ["E", "rootid", "wss://r", "rootpk"], ["K", "1063"],
            ["e", "parentid", "wss://r", "parentpk"], ["k", "1111"],
        ])
        #expect(Nip22.externalRoot(of: e) == nil)
    }

    /// Only kind 1111 is a comment; a kind-1 carrying an `I` tag isn't.
    @Test func nonCommentKindIsIgnored() {
        let e = comment([["I", "https://example.com"], ["K", "web"]], kind: 1)
        #expect(Nip22.externalRoot(of: e) == nil)
        #expect(Nip22.isComment(e) == false)
    }

    /// A non-URL identifier isn't openable on its own, but the tag's hint is.
    @Test func podcastGuidUsesHintForOpenableURL() {
        let e = comment([
            ["I", "podcast:item:guid:d98d189b", "https://fountain.fm/episode/z1y9"],
            ["K", "podcast:item:guid"],
        ])
        let root = Nip22.externalRoot(of: e)
        #expect(root?.openableURL?.absoluteString == "https://fountain.fm/episode/z1y9")
        #expect(root?.displayHost == "fountain.fm")
    }

    /// With no hint, a bare identifier yields no link — the card falls back to
    /// showing the raw value rather than a dead preview.
    @Test func bareIdentifierHasNoOpenableURL() {
        let e = comment([["I", "isbn:9780262033848"], ["K", "isbn"]])
        let root = Nip22.externalRoot(of: e)
        #expect(root?.openableURL == nil)
        #expect(root?.displayHost == nil)
    }

    /// Non-http schemes must not be treated as openable web links.
    @Test func nonHttpSchemeIsNotOpenable() {
        let e = comment([["I", "javascript:alert(1)"], ["K", "web"]])
        #expect(Nip22.externalRoot(of: e)?.openableURL == nil)
    }

    /// Top-level comment: parent mirrors the root.
    @Test func topLevelParentMirrorsRoot() {
        let url = "https://example.com/a"
        let e = comment([["I", url], ["K", "web"], ["i", url], ["k", "web"]])
        #expect(Nip22.externalParent(of: e)?.value == url)
    }

    /// Reply to another comment: the parent is an event, so there's no
    /// external parent even though the root is still the web page.
    @Test func replyToCommentHasEventParentNotExternal() {
        let url = "https://example.com/a"
        let e = comment([
            ["I", url], ["K", "web"],
            ["e", "parentcomment", "wss://r", "pk"], ["k", "1111"],
        ])
        #expect(Nip22.externalRoot(of: e)?.value == url)
        #expect(Nip22.externalParent(of: e) == nil)
    }

    /// A reply must stay kind-1111 and carry the root scope forward unchanged,
    /// pointing its lowercase tags at the comment being replied to.
    @Test func buildReplyTagsCarriesRootAndTargetsParent() {
        let url = "https://example.com/a"
        let parent = NostrEvent(id: "parentid", pubkey: "parentpk", kind: 1111,
                                createdAt: 0,
                                tags: [["I", url], ["K", "web"], ["i", url], ["k", "web"]],
                                content: "", sig: "")
        let tags = Nip22.buildReplyTags(to: parent)
        #expect(tags != nil)
        guard let tags else { return }

        #expect(tags.contains(["I", url]))
        #expect(tags.contains(["K", "web"]))
        // Parent is the comment itself — an event — so e/k/p, not a repeated `i`.
        #expect(tags.contains(["e", "parentid", "", "parentpk"]))
        #expect(tags.contains(["k", "1111"]))
        #expect(tags.contains(["p", "parentpk"]))
        #expect(!tags.contains { $0.first == "i" })
    }

    /// Replying to a note that isn't an external-rooted comment is out of
    /// scope — callers fall back to NIP-10 kind-1 threading.
    @Test func buildReplyTagsReturnsNilForPlainNote() {
        let note = NostrEvent(id: "n", pubkey: "pk", kind: 1, createdAt: 0,
                              tags: [], content: "", sig: "")
        #expect(Nip22.buildReplyTags(to: note) == nil)
    }
}
