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

    static func nip44Encrypt(keypair: Keypair, peerPubkey: String, plaintext: String) async throws -> String {
        guard let priv = Hex.decode(keypair.privkey), priv.count == 32,
              let peer = Hex.decode(peerPubkey), peer.count == 32 else {
            throw SignerError.localKeyMissing
        }
        let convo = try Nip44.getConversationKey(privkey32: priv, peerXonlyPubkey32: peer)
        return try Nip44.encrypt(plaintext: plaintext, conversationKey: convo)
    }

    static func nip44Decrypt(keypair: Keypair, peerPubkey: String, payload: String) async throws -> String {
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
