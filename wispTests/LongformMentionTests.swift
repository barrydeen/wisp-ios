import Foundation
import Testing
@testable import wisp

/// Article bodies carry mentions as raw bech32 inside markdown rather than as
/// parsed segments, so resolving one to a name starts by decoding the entity
/// and collecting the pubkeys worth fetching. Both were missing: every
/// mention in every article rendered as a truncated `@nprofile1q…`.
struct LongformMentionTests {

    /// nprofile for a real author (kind-30023 naddr TLV, author field).
    private let authorHex = "ee6ea13ab9fe5c4a68eaf9b1a34fe014a66b40117c50ee2a614f4cda959b6e74"

    private var npub: String {
        Nip19.npubEncode(pubkey: Array(Hex.decode(authorHex)!))!
    }

    // MARK: - Decoding a person

    @Test func npubDecodesToPubkey() {
        #expect(MarkdownBlocks.profilePubkey(from: npub) == authorHex)
    }

    /// The `nostr:` scheme is optional in article markdown, and some authors
    /// publish it uppercased.
    @Test func schemePrefixIsOptionalAndCaseInsensitive() {
        #expect(MarkdownBlocks.profilePubkey(from: "nostr:\(npub)") == authorHex)
        #expect(MarkdownBlocks.profilePubkey(from: "NOSTR:\(npub)") == authorHex)
    }

    // MARK: - Not a person

    /// Notes, events, and addressable coordinates are not mentions and must
    /// keep falling through to the shortened display form.
    @Test func nonProfileEntitiesAreNotMentions() {
        #expect(MarkdownBlocks.profilePubkey(from: "note1qqqqqqqqqqqqqqqq") == nil)
        #expect(MarkdownBlocks.profilePubkey(from: "nevent1qqqqqqqqqqqqqqq") == nil)
        #expect(MarkdownBlocks.profilePubkey(from: "naddr1qqqqqqqqqqqqqqq") == nil)
    }

    /// A prefix that looks right but doesn't decode must not produce a pubkey
    /// — the renderer needs the nil to fall back rather than show a name for
    /// somebody it hasn't identified.
    @Test func undecodableProfileEntityYieldsNil() {
        #expect(MarkdownBlocks.profilePubkey(from: "npub1notrealbech32") == nil)
        #expect(MarkdownBlocks.profilePubkey(from: "nprofile1nonsense") == nil)
    }

    // MARK: - Collecting what to fetch

    @Test func mentionsAreExtractedFromProse() {
        let content = "Thanks to nostr:\(npub) for the review."
        #expect(MarkdownBlocks.profileMentions(in: content) == [authorHex])
    }

    /// One fetch per person, however many times they're cited.
    @Test func repeatedMentionsAreDeduped() {
        let content = "\(npub) wrote it, and nostr:\(npub) edited it too."
        #expect(MarkdownBlocks.profileMentions(in: content) == [authorHex])
    }

    @Test func nonProfileEntitiesAreNotCollected() {
        let content = "See note1qqqqqqqqqqqqqqqq and naddr1qqqqqqqqqqqqqqq."
        #expect(MarkdownBlocks.profileMentions(in: content).isEmpty)
    }

    @Test func proseWithoutMentionsCollectsNothing() {
        #expect(MarkdownBlocks.profileMentions(in: "Just an ordinary paragraph.").isEmpty)
    }

    // MARK: - Fallback display

    /// Unresolved mentions still shorten, and never expose hex.
    @Test func shortenedFallbackIsStillBech32() {
        let short = Nip19.shortNpub(hex: authorHex)
        #expect(short.hasPrefix("npub1"))
        #expect(!short.contains(authorHex.prefix(8)))
    }
}
