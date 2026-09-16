import Foundation
import Testing
@testable import wisp

/// Round-trip coverage for `Nip19.naddrEncode` — the encoder behind emoji-pack
/// sharing. `naddrDecode` already existed and is used here as the oracle:
/// anything we emit must come back as the same coordinate, since a recipient's
/// client resolves the pack purely from these fields.
struct Nip19NaddrTests {

    private let pubkeyHex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"

    private var pubkeyBytes: [UInt8] {
        guard let data = Hex.decode(pubkeyHex) else { return [] }
        return Array(data)
    }

    private struct Decoded {
        let dTag: String
        let relays: [String]
        let author: String?
        let kind: Int?
    }

    private func decode(_ naddr: String?) -> Decoded? {
        guard let naddr,
              case .addressRef(let dTag, let relays, let author, let kind)? =
                Nip19.decodeNostrUri(naddr) else { return nil }
        return Decoded(dTag: dTag, relays: relays, author: author, kind: kind)
    }

    @Test func roundTripsCoordinate() {
        let naddr = Nip19.naddrEncode(kind: 30030, pubkey32: pubkeyBytes, dTag: "my-pack")
        #expect(naddr?.hasPrefix("naddr1") == true)

        let out = decode(naddr)
        #expect(out?.dTag == "my-pack")
        #expect(out?.author == pubkeyHex)
        #expect(out?.kind == 30030)
        #expect(out?.relays.isEmpty == true)
    }

    @Test func roundTripsRelayHints() {
        let relays = ["wss://relay.damus.io", "wss://nos.lol"]
        let out = decode(
            Nip19.naddrEncode(kind: 30030, pubkey32: pubkeyBytes, dTag: "pack", relays: relays)
        )
        #expect(out?.relays == relays)
    }

    @Test func roundTripsNostrPrefixedUri() {
        // What the share action actually puts on the pasteboard.
        let naddr = Nip19.naddrEncode(kind: 30030, pubkey32: pubkeyBytes, dTag: "pack")
        let out = decode(naddr.map { "nostr:\($0)" })
        #expect(out?.dTag == "pack")
        #expect(out?.kind == 30030)
    }

    @Test func roundTripsUnicodeDTag() {
        // `d` tags are arbitrary text, and the TLV length prefix counts bytes
        // rather than characters.
        let out = decode(Nip19.naddrEncode(kind: 30030, pubkey32: pubkeyBytes, dTag: "パック-🎉"))
        #expect(out?.dTag == "パック-🎉")
    }

    @Test func rejectsWrongPubkeyLength() {
        #expect(Nip19.naddrEncode(kind: 30030, pubkey32: [0x01, 0x02], dTag: "pack") == nil)
    }

    @Test func rejectsOversizedDTag() {
        // A TLV value is length-prefixed with one byte. Encoding a longer `d`
        // tag would drop it and emit an naddr that decodes to an empty tag —
        // i.e. a link that silently points at the wrong pack, or none.
        let tooLong = String(repeating: "a", count: 256)
        #expect(Nip19.naddrEncode(kind: 30030, pubkey32: pubkeyBytes, dTag: tooLong) == nil)

        let atLimit = String(repeating: "a", count: 255)
        #expect(Nip19.naddrEncode(kind: 30030, pubkey32: pubkeyBytes, dTag: atLimit) != nil)
    }

    @Test func encodesNonEmojiKindsToo() {
        // Nothing about the encoder is pack-specific; long-form is the other
        // addressable kind wisp renders as a card.
        let out = decode(Nip19.naddrEncode(kind: 30023, pubkey32: pubkeyBytes, dTag: "an-article"))
        #expect(out?.kind == 30023)
        #expect(out?.dTag == "an-article")
    }
}
