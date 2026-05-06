import Foundation
import CryptoKit
import os.log

private let backupLog = Logger(subsystem: "wisp", category: "wallet-backup")

/// Wisp-specific (non-standard NIP) protocol: encrypted Spark wallet seed backup
/// stored on relays as a kind 30078 addressable event with NIP-44-encrypted content.
///
/// d-tag format `spark-wallet-backup:<walletId>` matches the Android Wisp + addy
/// cross-app format so backups round-trip across clients. `walletId` is the first
/// 16 hex chars of SHA256(normalizedMnemonic).
nonisolated enum Nip78Backup {
    static let kind = 30078
    private static let dTagPrefix = "spark-wallet-backup"

    static func normalizeMnemonic(_ mnemonic: String) -> String {
        mnemonic
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func computeWalletId(_ mnemonic: String) -> String {
        let normalized = normalizeMnemonic(mnemonic)
        let hash = SHA256.hash(data: Data(normalized.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    static func buildBackupDTag(walletId: String) -> String {
        "\(dTagPrefix):\(walletId)"
    }

    /// NIP-44-encrypt the mnemonic to the user's own pubkey and sign as a kind 30078 event.
    /// Routes through the `Signer` facade so remote (NIP-46) accounts dispatch the encrypt
    /// + sign over their RPC channel instead of touching a local privkey that doesn't exist.
    static func createBackupEvent(keypair: Keypair, mnemonic: String) async throws -> NostrEvent {
        let normalized = normalizeMnemonic(mnemonic)
        let dTag = buildBackupDTag(walletId: computeWalletId(normalized))

        let encrypted = try await Signer.nip44Encrypt(
            keypair: keypair,
            peerPubkey: keypair.pubkey,
            plaintext: normalized
        )

        var tags: [[String]] = [
            ["d", dTag],
            ["encryption", "nip44"]
        ]
        if let clientTag = NostrEvent.clientTagIfEnabled() {
            tags.append(clientTag)
        }

        return try await Signer.sign(
            keypair: keypair,
            kind: kind,
            tags: tags,
            content: encrypted
        )
    }

    /// Decrypt a backup event and return the mnemonic if it parses as a valid BIP-39 word count.
    /// Same Signer-facade routing as `createBackupEvent` so this works for remote signers.
    /// Returns `.success(nil)` when the event itself is a tombstone (deleted backup) or the
    /// decrypt produced text that doesn't match a BIP-39 word count — both cases are
    /// "skip this entry, but don't blame the signer." Returns `.failure(...)` when the
    /// decrypt RPC actually errored, so the caller can distinguish "no usable backup
    /// here" from "the signer rejected nip44_decrypt and every event will fail."
    enum DecryptOutcome {
        case ok(String)
        case skip
        case failed(Error)
    }

    static func decryptBackup(keypair: Keypair, event: NostrEvent) async -> DecryptOutcome {
        if isDeletedBackup(event) { return .skip }
        do {
            let decrypted = try await Signer.nip44Decrypt(
                keypair: keypair,
                peerPubkey: event.pubkey,
                payload: event.content
            )
            let trimmed = decrypted.trimmingCharacters(in: .whitespacesAndNewlines)
            let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
            if [12, 15, 18, 21, 24].contains(wordCount) {
                return .ok(trimmed)
            }
            backupLog.warning("decrypt produced non-BIP39 text (\(wordCount) words) for event \(event.id, privacy: .public)")
            return .skip
        } catch {
            backupLog.error("decrypt failed for event \(event.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failed(error)
        }
    }

    static func isDeletedBackup(_ event: NostrEvent) -> Bool {
        if event.content.isEmpty { return true }
        return event.tags.contains { $0.count >= 2 && $0[0] == "deleted" && $0[1] == "true" }
    }

    static func extractDTag(_ event: NostrEvent) -> String? {
        event.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1]
    }

    static func extractWalletId(_ event: NostrEvent) -> String? {
        guard let dTag = extractDTag(event) else { return nil }
        guard dTag.hasPrefix("\(dTagPrefix):") else { return nil }
        return String(dTag.dropFirst(dTagPrefix.count + 1))
    }

    /// Build the all-backups filter for an author. NIP-01 has no d-tag prefix filter;
    /// callers must filter `dTagPrefix` client-side.
    static func backupFilter(pubkey: String) -> NostrFilter {
        NostrFilter(kinds: [kind], authors: [pubkey])
    }

    /// Tombstone a backup: kind 30078 with empty content + ["deleted","true"] tag at the same d-tag.
    static func createDeleteEvent(privkey32: Data, pubkeyHex: String, mnemonic: String) throws -> NostrEvent {
        let walletId = computeWalletId(mnemonic)
        let dTag = buildBackupDTag(walletId: walletId)
        return try NostrEvent.sign(
            privkey32: privkey32,
            pubkey: pubkeyHex,
            kind: kind,
            createdAt: Int(Date().timeIntervalSince1970),
            tags: [["d", dTag], ["deleted", "true"]],
            content: ""
        )
    }
}

/// Result of searching relays for spark-wallet backups.
enum BackupSearchResult {
    case notFound
    case single(BackupEntry)
    case multiple([BackupEntry])
}

struct BackupEntry: Identifiable {
    var id: String { walletId ?? mnemonic }
    let mnemonic: String
    let walletId: String?
    let createdAt: Int
}
