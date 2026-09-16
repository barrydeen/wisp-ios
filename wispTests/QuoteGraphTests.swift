import Foundation
import Testing
@testable import wisp

/// The quote graph remembers which note each note quoted, so a stack survives
/// losing a note in the middle of it.
///
/// A quote chain is discoverable one link at a time — A names B, and the link
/// from B to C lives inside B. Writing the edge down while B is in hand is the
/// only way that link outlives B.
@MainActor
struct QuoteGraphTests {

    private let quoter = String(repeating: "1", count: 64)
    private let quoted = String(repeating: "2", count: 64)
    private let author = String(repeating: "3", count: 64)

    private func fresh() -> QuoteGraph {
        QuoteGraph.shared.clear()
        return QuoteGraph.shared
    }

    @Test func recordsAndReadsBackAnEdge() {
        let g = fresh()
        g.record(eventId: quoter, quotedId: quoted, quotedAuthor: author)
        #expect(g.quoted(by: quoter)?.quotedId == quoted)
        #expect(g.quoted(by: quoter)?.quotedAuthor == author)
    }

    /// The point of the whole thing: the author of a note nobody can fetch,
    /// recovered from whoever quoted it.
    @Test func recoversTheAuthorOfAnUnfetchableNote() {
        let g = fresh()
        g.record(eventId: quoter, quotedId: quoted, quotedAuthor: author)
        #expect(g.author(of: quoted) == author)
    }

    @Test func unknownNotesAnswerNothing() {
        let g = fresh()
        #expect(g.quoted(by: quoter) == nil)
        #expect(g.author(of: quoted) == nil)
    }

    /// A first sighting may come from a bare `note1…` with no attribution. A
    /// later one that names the author is worth upgrading to.
    @Test func laterSightingCanSupplyAMissingAuthor() {
        let g = fresh()
        g.record(eventId: quoter, quotedId: quoted, quotedAuthor: nil)
        #expect(g.author(of: quoted) == nil)
        g.record(eventId: quoter, quotedId: quoted, quotedAuthor: author)
        #expect(g.author(of: quoted) == author)
    }

    /// A known author isn't downgraded by a later attribution-free sighting.
    @Test func aKnownAuthorIsNotLost() {
        let g = fresh()
        g.record(eventId: quoter, quotedId: quoted, quotedAuthor: author)
        g.record(eventId: quoter, quotedId: quoted, quotedAuthor: nil)
        #expect(g.author(of: quoted) == author)
    }

    /// Guard against junk that would make the graph lie: a note can't quote
    /// itself, and empty ids aren't edges.
    @Test func rejectsSelfReferenceAndEmptyIds() {
        let g = fresh()
        g.record(eventId: quoter, quotedId: quoter, quotedAuthor: author)
        g.record(eventId: "", quotedId: quoted, quotedAuthor: author)
        g.record(eventId: quoter, quotedId: "", quotedAuthor: author)
        #expect(g.quoted(by: quoter) == nil)
    }

    @Test func clearEmptiesTheGraph() {
        let g = fresh()
        g.record(eventId: quoter, quotedId: quoted, quotedAuthor: author)
        g.clear()
        #expect(g.quoted(by: quoter) == nil)
    }
}
