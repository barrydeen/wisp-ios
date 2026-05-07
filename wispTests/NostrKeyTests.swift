import Foundation
import Testing
@testable import wisp

struct NostrKeyTests {

    @Test func parsesLocalNsecBlob() {
        let priv = String(repeating: "a", count: 64)
        let pub = String(repeating: "b", count: 64)
        let kp = NostrKey.parseKeychainBlob("\(priv):\(pub)")
        #expect(kp?.privkey == priv)
        #expect(kp?.pubkey == pub)
    }

    /// Regression: remote-signer accounts persist with an empty privkey, so the
    /// blob starts with `:`. The previous loader used `String.split(separator:)`
    /// which drops the leading empty subsequence, yielding a 1-element array
    /// and a failed `parts.count == 2` guard. Remote accounts then appeared
    /// "wiped" on every app launch.
    @Test func parsesRemoteAccountBlobWithEmptyPrivkey() {
        let pub = String(repeating: "c", count: 64)
        let kp = NostrKey.parseKeychainBlob(":\(pub)")
        #expect(kp?.privkey == "")
        #expect(kp?.pubkey == pub)
    }

    @Test func rejectsBlobWithoutSeparator() {
        #expect(NostrKey.parseKeychainBlob("nocolon") == nil)
    }

    @Test func rejectsBlobWithEmptyPubkey() {
        #expect(NostrKey.parseKeychainBlob("priv:") == nil)
    }
}
