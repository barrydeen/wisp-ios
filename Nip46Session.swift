import Foundation
import Security

/// Persisted state for a NIP-46 remote-signing session.
///
/// We need to remember the ephemeral app keys, the signer's pubkey, the relays
/// we communicate over, and the user's actual pubkey (learned via
/// `get_public_key` after the handshake). On app launch, this struct is loaded
/// and rehydrated into a live `Nip46Client` (see `Nip46Manager.restore`).
///
/// Stored in two places:
///   - **Keychain** (`com.wisp.nip46`, account `<userPubkey>`): the JSON blob
///     in full. The app secret key is sensitive, so the whole record lives in
///     the secure store and is excluded from iCloud backups via
///     `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
///   - **UserDefaults** (`nip46_account_pubkeys`): a non-sensitive list of
///     pubkeys that have a saved session, so the UI can enumerate them
///     without unlocking the keychain.
struct Nip46Session: Codable, Equatable {
    /// User's real Nostr pubkey (hex), as reported by `get_public_key`.
    let userPubkey: String
    /// Ephemeral app private key (hex). Used to encrypt RPCs and sign the
    /// kind-24133 transport events. NOT the user's nostr key.
    let appPrivkeyHex: String
    /// App public key (hex), derived from `appPrivkeyHex`. Cached so we don't
    /// re-derive on every restore.
    let appPubkey: String
    /// Remote signer's pubkey (hex). The signer is identified by this; it may
    /// or may not equal `userPubkey` depending on the signer impl.
    let signerPubkey: String
    /// Relay URLs the session communicates over.
    let relays: [String]
    /// Original bunker:// URI (for display + reconnection if signer relays change).
    let bunkerURI: String
    /// Unix timestamp when the session was first established.
    let createdAt: Int
}

enum Nip46SessionStore {

    private static let service = "com.wisp.nip46"
    private static let pubkeysKey = "nip46_account_pubkeys"

    // MARK: - List

    /// All pubkeys with a saved NIP-46 session.
    static func savedPubkeys() -> [String] {
        UserDefaults.standard.stringArray(forKey: pubkeysKey) ?? []
    }

    static func isRemoteAccount(pubkey: String) -> Bool {
        savedPubkeys().contains(pubkey)
    }

    // MARK: - Save / Load / Delete

    static func save(_ session: Nip46Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: session.userPubkey
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)

        var list = savedPubkeys()
        if !list.contains(session.userPubkey) {
            list.append(session.userPubkey)
            UserDefaults.standard.set(list, forKey: pubkeysKey)
        }
    }

    static func load(pubkey: String) -> Nip46Session? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: pubkey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let session = try? JSONDecoder().decode(Nip46Session.self, from: data) else {
            return nil
        }
        return session
    }

    static func delete(pubkey: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: pubkey
        ]
        SecItemDelete(query as CFDictionary)
        var list = savedPubkeys()
        list.removeAll { $0 == pubkey }
        UserDefaults.standard.set(list, forKey: pubkeysKey)
    }
}
