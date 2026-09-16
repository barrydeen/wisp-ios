import Foundation
import Testing
@testable import wisp

/// Covers `EmojiRepository.packResolutionRelays` — the relay set used to resolve
/// a pack from its `30030:<pubkey>:<d>` coordinate.
///
/// The bug these pin down: the set used to be author-writes *or* indexers, never
/// both. A pack whose author publishes a kind-10002 that omits the relay the
/// pack actually landed on was then unresolvable, because a coordinate carries
/// no relay of its own. Real case: `30030:a9434ee1…:Wisp`, whose author
/// advertises only relay.primal.net while the pack lives on nos.lol and
/// relay.damus.io — both already in `RelayDefaults.indexers`, never queried.
struct EmojiPackResolutionTests {

    @Test func indexersAreIncludedEvenWhenAuthorAdvertisesRelays() {
        let relays = EmojiRepository.packResolutionRelays(
            authorWrites: ["wss://relay.primal.net"],
            hints: []
        )
        #expect(relays.contains("wss://relay.primal.net"))
        // The relays that actually carry the pack in the case above.
        #expect(relays.contains("wss://nos.lol"))
        #expect(relays.contains("wss://relay.damus.io"))
    }

    @Test func authorRelaysComeFirstThenHintsThenIndexers() {
        let relays = EmojiRepository.packResolutionRelays(
            authorWrites: ["wss://author.example"],
            hints: ["wss://hint.example"]
        )
        #expect(relays.first == "wss://author.example")
        #expect(relays.dropFirst().first == "wss://hint.example")
        let hintIndex = relays.firstIndex(of: "wss://hint.example")
        let indexerIndex = relays.firstIndex(of: RelayDefaults.indexers[0])
        #expect(hintIndex != nil)
        #expect(indexerIndex != nil)
        #expect(hintIndex! < indexerIndex!)
    }

    // A kind-10002 usually spells relays with a trailing slash; the indexer
    // constants don't. Both spellings open the same socket.
    @Test func trailingSlashDoesNotProduceADuplicate() {
        let relays = EmojiRepository.packResolutionRelays(
            authorWrites: ["wss://nos.lol/"],
            hints: ["wss://nos.lol"]
        )
        #expect(relays.filter { $0 == "wss://nos.lol" }.count == 1)
        #expect(!relays.contains("wss://nos.lol/"))
    }

    @Test func emptyAndBlankEntriesAreDropped() {
        let relays = EmojiRepository.packResolutionRelays(
            authorWrites: ["", "   "],
            hints: [""]
        )
        #expect(!relays.contains(""))
        #expect(relays.allSatisfy { !$0.isEmpty })
        #expect(!relays.isEmpty)  // indexers still present
    }

    // An author with no relay list at all must still resolve — this was the one
    // path the old either/or logic got right, so it needs to stay working.
    @Test func noAuthorRelaysStillFallsBackToIndexers() {
        let relays = EmojiRepository.packResolutionRelays(authorWrites: [], hints: [])
        #expect(relays == Array(RelayDefaults.indexers.prefix(8)))
    }

    // The fan-out is bounded: an author advertising a dozen relays plus hints
    // must not open a socket to each.
    @Test func relaySetIsCapped() {
        let many = (1...12).map { "wss://relay\($0).example" }
        let relays = EmojiRepository.packResolutionRelays(
            authorWrites: many,
            hints: ["wss://hint1.example", "wss://hint2.example"]
        )
        #expect(relays.count <= 8)
        // Author relays are capped at 4 so hints and indexers still get a turn.
        #expect(relays.filter { $0.hasPrefix("wss://relay") }.count == 4)
        #expect(relays.contains("wss://hint1.example"))
    }
}
