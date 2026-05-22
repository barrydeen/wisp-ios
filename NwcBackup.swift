import Foundation
import os.log

private let nwcBackupLog = Logger(subsystem: "wisp", category: "wallet-backup")

/// Wisp-specific (non-standard NIP) protocol: encrypted NWC connection-string
/// backup stored on relays as a kind 30078 addressable event with
/// NIP-44-encrypted content.
///
/// The flat d-tag `nwc-wallet-backup` keeps a single replaceable backup per
/// account — reconnecting or switching wallets overwrites it. The Android
/// Wisp client uses the same d-tag and `nip44` content encoding so the
/// connection round-trips across platforms.
nonisolated enum NwcBackup {
    static let kind = 30078
    static let dTag = "nwc-wallet-backup"

    /// NIP-44-encrypt the NWC URI to the user's own pubkey and sign as a kind
    /// 30078 event. Routes through the `Signer` facade so remote (NIP-46)
    /// accounts dispatch the encrypt + sign over their RPC channel.
    static func createBackupEvent(keypair: Keypair, uri: String) async throws -> NostrEvent {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)

        let encrypted = try await Signer.nip44Encrypt(
            keypair: keypair,
            peerPubkey: keypair.pubkey,
            plaintext: trimmed
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

    enum DecryptOutcome {
        case ok(String)
        case skip
        case failed(Error)
    }

    /// Decrypt a backup event and return the NWC URI if the plaintext looks
    /// like one. `.skip` covers tombstones and decrypts that don't yield an
    /// NWC string; `.failed` is reserved for an actual decrypt error so the
    /// caller can tell "no usable backup" from "the signer refused to decrypt".
    static func decryptBackup(keypair: Keypair, event: NostrEvent) async -> DecryptOutcome {
        if isDeletedBackup(event) { return .skip }
        do {
            let decrypted = try await Signer.nip44Decrypt(
                keypair: keypair,
                peerPubkey: event.pubkey,
                payload: event.content
            )
            let trimmed = decrypted.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("nostr+walletconnect://") else {
                nwcBackupLog.warning("decrypt produced non-NWC text for event \(event.id, privacy: .public)")
                return .skip
            }
            return .ok(trimmed)
        } catch {
            nwcBackupLog.error("decrypt failed for event \(event.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

    /// Filter for the account's NWC backup. The flat d-tag lets relays match
    /// `#d` server-side, so unlike the Spark backup no client-side prefix
    /// filtering is needed.
    static func backupFilter(pubkey: String) -> NostrFilter {
        NostrFilter(kinds: [kind], authors: [pubkey], dTags: [dTag])
    }
}
