import Foundation
import Security

struct Keypair: Equatable {
    let privkey: String
    let pubkey: String
}

enum NostrKey {

    /// In-memory mirror of the "active" Keychain entry. Hot-path callers like
    /// `PostCardView`'s `myPubkey` and `EngagementRepository`'s author check
    /// previously hit `SecItemCopyMatching` on every render; one keychain
    /// round-trip is ~10–50 ms cold. Invalidated on `save`, `switchAccount`,
    /// `delete`, and `saveToKeychain(account: "active")`.
    private nonisolated(unsafe) static var _cachedActive: Keypair?
    private static let cacheLock = NSLock()

    private static func cachedActive() -> Keypair? {
        cacheLock.lock()
        let v = _cachedActive
        cacheLock.unlock()
        return v
    }

    private static func setCachedActive(_ keypair: Keypair?) {
        cacheLock.lock()
        _cachedActive = keypair
        cacheLock.unlock()
    }

    static func parseNsec(_ input: String) -> Keypair? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.lowercased().hasPrefix("nsec1") {
            guard let (hrp, data) = Bech32.decode(trimmed),
                  hrp == "nsec", data.count == 32 else { return nil }
            guard let pub = Secp256k1.publicKey(from: data) else { return nil }
            return Keypair(privkey: Hex.encode(data), pubkey: Hex.encode(pub))
        }

        if trimmed.count == 64, let data = Hex.decode(trimmed), data.count == 32 {
            guard let pub = Secp256k1.publicKey(from: data) else { return nil }
            return Keypair(privkey: Hex.encode(data), pubkey: Hex.encode(pub))
        }

        return nil
    }

    // MARK: - Keychain

    private static let service = "com.wisp.nostr"

    static func save(_ keypair: Keypair) {
        saveToKeychain(keypair, account: "active")
        saveToKeychain(keypair, account: "account_\(keypair.pubkey)")
        addToAccountList(keypair.pubkey)
        setCachedActive(keypair)
    }

    /// Save a remote-signer (NIP-46) account. The private key is stored as an
    /// empty string sentinel — `Keypair.isRemote` (defined in `Signer.swift`)
    /// reads that as the marker for "signing is delegated, look up
    /// `Nip46Manager.shared.activeClient`". The actual session lives in
    /// `Nip46SessionStore`.
    static func saveRemote(pubkey: String) {
        let kp = Keypair(privkey: "", pubkey: pubkey)
        save(kp)
    }

    static func load() -> Keypair? {
        if let cached = cachedActive() { return cached }
        guard let kp = loadFromKeychain(account: "active") else { return nil }
        setCachedActive(kp)
        return kp
    }

    static func loadAccount(pubkey: String) -> Keypair? {
        loadFromKeychain(account: "account_\(pubkey)")
    }

    static func switchAccount(pubkey: String) -> Keypair? {
        guard let keypair = loadAccount(pubkey: pubkey) else { return nil }
        saveToKeychain(keypair, account: "active")
        setCachedActive(keypair)
        return keypair
    }

    static func accounts() -> [String] {
        UserDefaults.standard.stringArray(forKey: "wisp_accounts") ?? []
    }

    static func delete() {
        deleteFromKeychain(account: "active")
        setCachedActive(nil)
    }

    static func deleteAccount(pubkey: String) {
        deleteFromKeychain(account: "account_\(pubkey)")
        if cachedActive()?.pubkey == pubkey {
            setCachedActive(nil)
        }
        Nip46SessionStore.delete(pubkey: pubkey)
        var list = accounts()
        list.removeAll { $0 == pubkey }
        UserDefaults.standard.set(list, forKey: "wisp_accounts")
        let keys = [
            "onboarding_done_\(pubkey)",
            "follow_pubkeys_\(pubkey)",
            "relay_scoreboard_v1_\(pubkey)",
            "latest_feed_ts_\(pubkey)",
            // Safety: mute lists, blocked users, muted threads, mute event timestamp
            "muted_words_\(pubkey)",
            "blocked_pubkeys_\(pubkey)",
            "muted_threads_\(pubkey)",
            "mute_list_updated_at_\(pubkey)",
            // Safety: filter prefs and spam safelist
            "spam_filter_enabled_\(pubkey)",
            "wot_filter_enabled_\(pubkey)",
            "spam_safelist_\(pubkey)",
            // Safety: cached extended-network qualified set
            "wot_qualified_\(pubkey)"
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        FollowsCache.shared.invalidate(pubkey: pubkey)
    }

    static func isOnboardingComplete(pubkey: String) -> Bool {
        UserDefaults.standard.bool(forKey: "onboarding_done_\(pubkey)")
    }

    static func markOnboardingComplete(pubkey: String) {
        UserDefaults.standard.set(true, forKey: "onboarding_done_\(pubkey)")
    }

    // MARK: - Private

    private static func saveToKeychain(_ keypair: Keypair, account: String) {
        guard let data = "\(keypair.privkey):\(keypair.pubkey)".data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func loadFromKeychain(account: String) -> Keypair? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        // `omittingEmptySubsequences: false` is load-bearing here — remote
        // signer accounts are persisted with an empty privkey (the
        // `Keypair.isRemote` sentinel set by `saveRemote`), so the stored
        // data is `":<pubkey>"`. The default `split` drops that leading
        // empty substring, returns 1 part, and we'd hand back nil — making
        // every NIP-46 account unswitchable from the sidebar picker.
        let parts = str.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        return Keypair(privkey: parts[0], pubkey: parts[1])
    }

    private static func deleteFromKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func registerInAccountList(_ pubkey: String) { addToAccountList(pubkey) }

    private static func addToAccountList(_ pubkey: String) {
        var list = accounts()
        if !list.contains(pubkey) {
            list.append(pubkey)
        }
        UserDefaults.standard.set(list, forKey: "wisp_accounts")
    }
}
