import Foundation
import Testing
@testable import wisp

/// Finding the author of a quoted note from the note that quotes it.
///
/// NIP-18 requires a quote to carry `["q", <id>, <relay>, <pubkey>]`, so the
/// quoting note already names who wrote the note being quoted. That's the only
/// attribution available when the quoted event itself can't be fetched, and
/// it's what makes an outbox lookup — querying the author's own NIP-65 write
/// relays — possible at all.
struct QuoteOutboxTests {

    private let quoted = String(repeating: "a", count: 64)
    private let author = String(repeating: "b", count: 64)
    private let other = String(repeating: "c", count: 64)

    /// Mirrors the lookup `RichContentView` performs on the quoting note's
    /// tags, so the rule is testable without building a view.
    private func authorOfQuote(_ eventId: String, in tags: [[String]]) -> String? {
        tags.first {
            $0.count >= 4 && $0[0] == "q" && $0[1] == eventId && !$0[3].isEmpty
        }?[3]
    }

    @Test func findsTheAuthorFromTheQTag() {
        let tags = [["q", quoted, "wss://relay.example", author]]
        #expect(authorOfQuote(quoted, in: tags) == author)
    }

    /// A note can quote several others; each `q` names its own author.
    @Test func picksTheTagForThisQuote() {
        let tags = [
            ["q", other, "", other],
            ["q", quoted, "", author],
        ]
        #expect(authorOfQuote(quoted, in: tags) == author)
    }

    /// The pubkey is the optional fourth element. Without it there's no author
    /// to look up, and the fetch falls back to hints and defaults.
    @Test func qTagWithoutAPubkeyYieldsNothing() {
        #expect(authorOfQuote(quoted, in: [["q", quoted, "wss://relay.example"]]) == nil)
        #expect(authorOfQuote(quoted, in: [["q", quoted, "", ""]]) == nil)
    }

    /// An `e` tag is a reply or mention, not a quote — reading an author out
    /// of one would attribute the wrong person.
    @Test func ignoresNonQuoteTags() {
        let tags = [["e", quoted, "", "reply", author]]
        #expect(authorOfQuote(quoted, in: tags) == nil)
    }

    @Test func noTagsYieldsNothing() {
        #expect(authorOfQuote(quoted, in: []) == nil)
    }
}
