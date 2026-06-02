import Foundation

@MainActor
enum Signer {

    enum SignerError: Swift.Error, CustomStringConvertible {
        case localKeyMissing

        var description: String {
            switch self {
            case .localKeyMissing: return "Missing local private key"
            }
        }
    }

    static func sign(
        keypair: Keypair,
        kind: Int,
        tags: [[String]],
        content: String,
        createdAt: Int? = nil
    ) async throws -> NostrEvent {
        let ts = createdAt ?? Int(Date().timeIntervalSince1970)
        guard let priv = Hex.decode(keypair.privkey), priv.count == 32 else {
            throw SignerError.localKeyMissing
        }
        return try NostrEvent.sign(
            privkey32: priv,
            pubkey: keypair.pubkey,
            kind: kind,
            createdAt: ts,
            tags: tags,
            content: content
        )
    }

    // MARK: - Encryption helpers

    // `nonisolated` so the secp256k1 ECDH + ChaCha20 work runs OFF the main
    // actor. The project defaults to `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
    // which silently pinned these pure-crypto helpers to the main thread — so
    // draining a NIP-17 gift-wrap backlog (kind:1059) decrypted hundreds of wraps
    // on the main thread in a tight loop and froze the app for 5–10s. They touch
    // no main-actor state; only the passed-in keypair + nonisolated `Nip44`/`Hex`.
    nonisolated static func nip44Encrypt(keypair: Keypair, peerPubkey: String, plaintext: String) async throws -> String {
        guard let priv = Hex.decode(keypair.privkey), priv.count == 32,
              let peer = Hex.decode(peerPubkey), peer.count == 32 else {
            throw SignerError.localKeyMissing
        }
        let convo = try Nip44.getConversationKey(privkey32: priv, peerXonlyPubkey32: peer)
        return try Nip44.encrypt(plaintext: plaintext, conversationKey: convo)
    }

    nonisolated static func nip44Decrypt(keypair: Keypair, peerPubkey: String, payload: String) async throws -> String {
        guard let priv = Hex.decode(keypair.privkey), priv.count == 32,
              let peer = Hex.decode(peerPubkey), peer.count == 32 else {
            throw SignerError.localKeyMissing
        }
        let convo = try Nip44.getConversationKey(privkey32: priv, peerXonlyPubkey32: peer)
        return try Nip44.decrypt(payload: payload, conversationKey: convo)
    }
}

extension Keypair {
    /// True for accounts logged in via npub/nprofile QR scan — read-only, no signing capability.
    var isWatchOnly: Bool { NostrKey.isWatchOnly(pubkey: pubkey) }
}
