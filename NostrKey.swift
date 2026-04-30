import Foundation
import Security

struct Keypair: Equatable {
    let privkey: String
    let pubkey: String
}

enum NostrKey {

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
    }

    static func load() -> Keypair? {
        loadFromKeychain(account: "active")
    }

    static func loadAccount(pubkey: String) -> Keypair? {
        loadFromKeychain(account: "account_\(pubkey)")
    }

    static func switchAccount(pubkey: String) -> Keypair? {
        guard let keypair = loadAccount(pubkey: pubkey) else { return nil }
        saveToKeychain(keypair, account: "active")
        return keypair
    }

    static func accounts() -> [String] {
        UserDefaults.standard.stringArray(forKey: "wisp_accounts") ?? []
    }

    static func delete() {
        deleteFromKeychain(account: "active")
    }

    static func deleteAccount(pubkey: String) {
        deleteFromKeychain(account: "account_\(pubkey)")
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
        let parts = str.split(separator: ":", maxSplits: 1).map(String.init)
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
