import Foundation
import Security

/// Thrown when the iCloud Keychain backup operation fails for an
/// identity/availability reason (iCloud signed out) or for an unhandled
/// Keychain `OSStatus`. Parallel to `DriveAuthorizationExpiredError` from
/// the Google flow.
struct KeychainBackupError: Error {
    enum Kind {
        case iCloudUnavailable
        case underlying(OSStatus)
    }
    let kind: Kind
    let op: String
}

/// iCloud-Keychain-backed equivalent of `DriveBackupService`. Each backup
/// is one generic-password Keychain item with `kSecAttrSynchronizable = true`,
/// which iOS syncs across the user's Apple devices via the end-to-end
/// encrypted iCloud Keychain "circle of trust." Apple itself cannot decrypt
/// these items — even after the PIN-bound NIP-44 layer we already apply on
/// top.
///
/// Storage layout:
///   - Service: `"com.wisp.apple-backup"` (distinct from `NostrKey`'s
///     `"com.wisp.nostr"` so account enumeration doesn't bleed across).
///   - Account: `"wisp_bk_<UUID>"` — opaque per-backup identifier, mirrors
///     the Drive filename convention (`wisp_bk_<uuid>.bin`) so the cloud
///     provider can't infer the user's npub from the item name.
///   - Value: UTF-8 bytes of the base64-encoded NIP-44 v2 ciphertext.
///   - Accessibility: `kSecAttrAccessibleAfterFirstUnlock` — required for
///     sync. `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (which
///     `NostrKey` uses for the active nsec) blocks iCloud Keychain sync.
struct KeychainBackupService {
    struct BackupFile: Equatable {
        let backupID: String
        let payload: String
    }

    private static let service = "com.wisp.apple-backup"
    private static let prefix = "wisp_bk_"

    func listBackups() async throws -> [BackupFile] {
        try ensureICloudAvailable(op: "list")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainBackupError(kind: .underlying(status), op: "list")
        }

        var files: [(file: BackupFile, createdAt: Date)] = []
        files.reserveCapacity(items.count)
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(Self.prefix),
                  let data = item[kSecValueData as String] as? Data,
                  let payload = String(data: data, encoding: .utf8) else { continue }
            let createdAt = item[kSecAttrCreationDate as String] as? Date ?? .distantPast
            files.append((BackupFile(backupID: account, payload: payload), createdAt))
        }
        // Newest first, matching `DriveBackupService` and Google flow UX.
        return files.sorted { $0.createdAt > $1.createdAt }.map { $0.file }
    }

    /// Creates a new keychain item with a fresh UUID account name. Each call
    /// writes a distinct item — no replace path, matching the Drive
    /// convention.
    func uploadBackup(payload: String) async throws {
        try ensureICloudAvailable(op: "upload")
        let account = Self.prefix + UUID().uuidString.lowercased()
        guard let data = payload.data(using: .utf8) else {
            throw KeychainBackupError(kind: .underlying(errSecParam), op: "upload")
        }
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainBackupError(kind: .underlying(status), op: "upload")
        }
    }

    func deleteBackup(backupID: String) async throws {
        try ensureICloudAvailable(op: "delete")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: backupID,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainBackupError(kind: .underlying(status), op: "delete")
        }
    }

    /// iCloud-signed-in check via `ubiquityIdentityToken`. This is the
    /// closest public-API proxy for "iCloud Keychain is available" — there
    /// is no separate query for the Keychain sub-setting. If iCloud overall
    /// is signed in but iCloud Keychain specifically is off, the `SecItemAdd`
    /// still succeeds locally and sync simply doesn't happen — acceptable
    /// degradation.
    private func ensureICloudAvailable(op: String) throws {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            throw KeychainBackupError(kind: .iCloudUnavailable, op: op)
        }
    }
}
