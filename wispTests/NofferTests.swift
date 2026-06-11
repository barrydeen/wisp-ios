import Foundation
import Testing
@testable import wisp

/// Tests for the CLINK `noffer1…` decoder. We don't have a publicly-shared
/// production noffer to pin as a fixture, so each test encodes a synthetic
/// offer via the app's own `Bech32` encoder and round-trips it through
/// `Noffer.decode`, pinning the TLV byte layout from the CLINK spec.
struct NofferTests {

    private static let pubkeyHex = "ee6ea13ab9fe5c4a68eaf9b1a34fe014a66b40117c50ee2a614f4cda959b6e74"
    private static let relay = "wss://relay.example.com"
    private static let offerId = "tip-jar"

    private struct Tlv { let type: UInt8; let value: [UInt8] }

    private func encode(_ tlvs: [Tlv]) -> String {
        var bytes: [UInt8] = []
        for tlv in tlvs {
            bytes.append(tlv.type)
            bytes.append(UInt8(tlv.value.count))
            bytes.append(contentsOf: tlv.value)
        }
        return Bech32.encode(hrp: "noffer", data: Data(bytes))
    }

    private var pubkeyBytes: [UInt8] { Array(Hex.decode(Self.pubkeyHex)!) }
    private var relayBytes: [UInt8] { Array(Self.relay.utf8) }
    private var offerBytes: [UInt8] { Array(Self.offerId.utf8) }

    @Test func decodesMinimumTlvsAndDefaultsToSpontaneous() throws {
        let noffer = encode([
            Tlv(type: 0, value: pubkeyBytes),
            Tlv(type: 1, value: relayBytes),
            Tlv(type: 2, value: offerBytes)
        ])
        let decoded = try Noffer.decode(noffer)
        #expect(decoded.pubkey == Self.pubkeyHex)
        #expect(decoded.relay == Self.relay)
        #expect(decoded.offerId == Self.offerId)
        #expect(decoded.pricing == .spontaneous)
        #expect(decoded.price == nil)
        #expect(decoded.currency == nil)
    }

    @Test func decodesFixedPricingWithPrice() throws {
        let noffer = encode([
            Tlv(type: 0, value: pubkeyBytes),
            Tlv(type: 1, value: relayBytes),
            Tlv(type: 2, value: offerBytes),
            Tlv(type: 3, value: [0]),            // Fixed
            Tlv(type: 4, value: [0x27, 0x10])    // 10000 big-endian
        ])
        let decoded = try Noffer.decode(noffer)
        #expect(decoded.pricing == .fixed)
        #expect(decoded.price == 10000)
    }

    @Test func decodesVariablePricingWithCurrency() throws {
        let noffer = encode([
            Tlv(type: 0, value: pubkeyBytes),
            Tlv(type: 1, value: relayBytes),
            Tlv(type: 2, value: offerBytes),
            Tlv(type: 3, value: [1]),            // Variable
            Tlv(type: 5, value: Array("USD".utf8))
        ])
        let decoded = try Noffer.decode(noffer)
        #expect(decoded.pricing == .variable)
        #expect(decoded.currency == "USD")
    }

    @Test func acceptsNostrUriPrefix() throws {
        let noffer = encode([
            Tlv(type: 0, value: pubkeyBytes),
            Tlv(type: 1, value: relayBytes),
            Tlv(type: 2, value: offerBytes)
        ])
        #expect(try Noffer.decode("nostr:" + noffer).pubkey == Self.pubkeyHex)
        #expect(try Noffer.decode("NOSTR:" + noffer).pubkey == Self.pubkeyHex)
        // `raw` always strips the scheme prefix.
        #expect(try Noffer.decode("nostr:" + noffer).raw == noffer)
    }

    @Test func throwsOnWrongHrp() {
        #expect(throws: (any Error).self) {
            try Noffer.decode("npub1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
        }
    }

    @Test func throwsOnMissingRequiredTlvs() {
        let noffer = encode([Tlv(type: 0, value: pubkeyBytes)])  // missing relay + offer id
        #expect(throws: (any Error).self) { try Noffer.decode(noffer) }
    }

    @Test func throwsOnWrongLengthPubkey() {
        let noffer = encode([
            Tlv(type: 0, value: [UInt8](repeating: 0, count: 16)),  // 16-byte pubkey is invalid
            Tlv(type: 1, value: relayBytes),
            Tlv(type: 2, value: offerBytes)
        ])
        #expect(throws: (any Error).self) { try Noffer.decode(noffer) }
    }

    @Test func isNofferStringMatchesShapeOnly() {
        let noffer = encode([
            Tlv(type: 0, value: pubkeyBytes),
            Tlv(type: 1, value: relayBytes),
            Tlv(type: 2, value: offerBytes)
        ])
        #expect(Noffer.isNofferString(noffer))
        #expect(Noffer.isNofferString("nostr:" + noffer))
        #expect(!Noffer.isNofferString("npub1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"))
        #expect(!Noffer.isNofferString(""))
        #expect(!Noffer.isNofferString(nil))
    }

    @Test func stripNostrPrefixWorks() {
        #expect(Noffer.stripNostrPrefix("nostr:noffer1abc") == "noffer1abc")
        #expect(Noffer.stripNostrPrefix("NOSTR:noffer1abc") == "noffer1abc")
        #expect(Noffer.stripNostrPrefix("  nostr:noffer1abc  ") == "noffer1abc")
        #expect(Noffer.stripNostrPrefix("noffer1abc") == "noffer1abc")
    }
}
