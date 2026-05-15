import Foundation

/// Unified signing facade for the active account. Routes to local Schnorr
/// signing for `nsec`/keychain accounts, or to a `Nip46Client` for remote-signed
/// accounts.
///
/// Existing call sites in the codebase use `NostrEvent.sign(privkey32:...)`
/// directly; that path is still correct for local accounts and is preserved.
/// Sites that want to support remote signing should call
/// `Signer.sign(keypair:kind:tags:content:)` instead — when `keypair.isRemote`
/// is true, it routes through `Nip46Manager.shared.activeClient`.
@MainActor
enum Signer {

    enum SignerError: Swift.Error, CustomStringConvertible {
        case noActiveRemoteSigner
        case localKeyMissing
        case remoteRefused(String)

        var description: String {
            switch self {
            case .noActiveRemoteSigner: return "Remote signer is not connected"
            case .localKeyMissing: return "Missing local private key"
            case .remoteRefused(let s): return s
            }
        }
    }

    /// Sign an event for the given keypair. For local accounts this is a
    /// straight-through call to `NostrEvent.sign(privkey32:...)`. For remote
    /// (NIP-46) accounts the unsigned template is forwarded to the active
    /// signer; the user approves on the signer device and the signed event
    /// comes back over relays.
    static func sign(
        keypair: Keypair,
        kind: Int,
        tags: [[String]],
        content: String,
        createdAt: Int? = nil
    ) async throws -> NostrEvent {
        let ts = createdAt ?? Int(Date().timeIntervalSince1970)
        if keypair.isRemote {
            guard let client = Nip46Manager.shared.activeClient else {
                throw SignerError.noActiveRemoteSigner
            }
            let unsigned: [String: Any] = [
                "pubkey": keypair.pubkey,
                "kind": kind,
                "created_at": ts,
                "tags": tags,
                "content": content
            ]
            return try await client.signEvent(unsigned: unsigned)
        }
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

    /// NIP-44 v2 encrypt `plaintext` to `peerPubkey` for the active keypair.
    /// Local accounts compute the conversation key in-process; remote accounts
    /// dispatch a `nip44_encrypt` RPC to the signer.
    static func nip44Encrypt(keypair: Keypair, peerPubkey: String, plaintext: String) async throws -> String {
        if keypair.isRemote {
            guard let client = Nip46Manager.shared.activeClient else {
                throw SignerError.noActiveRemoteSigner
            }
            return try await client.nip44Encrypt(peerPubkeyHex: peerPubkey, plaintext: plaintext)
        }
        guard let priv = Hex.decode(keypair.privkey), priv.count == 32,
              let peer = Hex.decode(peerPubkey), peer.count == 32 else {
            throw SignerError.localKeyMissing
        }
        let convo = try Nip44.getConversationKey(privkey32: priv, peerXonlyPubkey32: peer)
        return try Nip44.encrypt(plaintext: plaintext, conversationKey: convo)
    }

    /// NIP-44 v2 decrypt `payload` from `peerPubkey` for the active keypair.
    static func nip44Decrypt(keypair: Keypair, peerPubkey: String, payload: String) async throws -> String {
        if keypair.isRemote {
            guard let client = Nip46Manager.shared.activeClient else {
                throw SignerError.noActiveRemoteSigner
            }
            return try await client.nip44Decrypt(peerPubkeyHex: peerPubkey, ciphertext: payload)
        }
        guard let priv = Hex.decode(keypair.privkey), priv.count == 32,
              let peer = Hex.decode(peerPubkey), peer.count == 32 else {
            throw SignerError.localKeyMissing
        }
        let convo = try Nip44.getConversationKey(privkey32: priv, peerXonlyPubkey32: peer)
        return try Nip44.decrypt(payload: payload, conversationKey: convo)
    }
}

extension Keypair {
    /// True for accounts where signing is delegated to a NIP-46 remote signer.
    /// Identified by an empty private key string in the persisted record and
    /// the absence of the watch-only sentinel.
    var isRemote: Bool { privkey.isEmpty && !isWatchOnly }

    /// True for accounts logged in via npub/nprofile QR scan — read-only, no
    /// signing capability of any kind.
    var isWatchOnly: Bool { NostrKey.isWatchOnly(pubkey: pubkey) }
}
