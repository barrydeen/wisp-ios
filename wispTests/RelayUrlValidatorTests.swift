import Testing
import Foundation
@testable import wisp

struct RelayUrlValidatorTests {

    @Test func acceptsCleanWss() {
        #expect(RelayUrlValidator.isValid("wss://relay.damus.io"))
        #expect(RelayUrlValidator.isValid("wss://relay.primal.net"))
        #expect(RelayUrlValidator.isValid("wss://nostr.wine/path/with/segments"))
    }

    @Test func rejectsNonWss() {
        #expect(!RelayUrlValidator.isValid("ws://relay.damus.io"))
        #expect(!RelayUrlValidator.isValid("http://relay.damus.io"))
        #expect(!RelayUrlValidator.isValid("https://relay.damus.io"))
        #expect(!RelayUrlValidator.isValid("relay.damus.io"))
    }

    @Test func rejectsLocalhostAndPrivate() {
        #expect(!RelayUrlValidator.isValid("wss://localhost"))
        #expect(!RelayUrlValidator.isValid("wss://127.0.0.1"))
        #expect(!RelayUrlValidator.isValid("wss://192.168.1.10"))
        #expect(!RelayUrlValidator.isValid("wss://10.0.0.1"))
    }

    @Test func rejectsExplicitPort() {
        // Mirrors Android: relays should be on the default 443 — explicit ports are usually
        // dev/local nodes that don't belong in a published relay list.
        #expect(!RelayUrlValidator.isValid("wss://relay.example.com:8080"))
        #expect(!RelayUrlValidator.isValid("wss://relay.example.com:443"))
    }

    @Test func acceptsOnionAtStorageLayerButNotConnect() {
        let onion = "wss://abcdef1234567890.onion"
        #expect(RelayUrlValidator.isValid(onion))
        #expect(RelayUrlValidator.isValid("ws://abcdef1234567890.onion"))
        // iOS has no Tor integration — `.onion` must not be opened.
        #expect(!RelayUrlValidator.isConnectable(onion))
    }

    @Test func connectableImpliesValid() {
        #expect(RelayUrlValidator.isConnectable("wss://relay.damus.io"))
        #expect(!RelayUrlValidator.isConnectable("wss://localhost"))
        #expect(!RelayUrlValidator.isConnectable("ws://relay.damus.io")) // ws:// only ok for .onion
    }
}
