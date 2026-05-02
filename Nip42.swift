import Foundation

/// NIP-42: client authentication on relays via kind-22242 events.
/// Spec: https://github.com/nostr-protocol/nips/blob/master/42.md
nonisolated enum Nip42 {

    static let kindAuth = 22242

    /// Build a signed kind-22242 AUTH event in response to a relay's
    /// `["AUTH", challenge]` frame.
    static func buildAuthEvent(challenge: String, relayUrl: String, keypair: Keypair,
                               createdAt: Int = Int(Date().timeIntervalSince1970)) throws -> NostrEvent {
        let tags: [[String]] = [
            ["relay", relayUrl],
            ["challenge", challenge]
        ]
        let priv = Hex.decode(keypair.privkey) ?? Data()
        return try NostrEvent.sign(privkey32: priv, pubkey: keypair.pubkey, kind: kindAuth,
                                   createdAt: createdAt, tags: tags, content: "")
    }
}
