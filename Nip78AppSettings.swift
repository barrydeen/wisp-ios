import Foundation
import os.log

private let settingsSyncLog = Logger(subsystem: "wisp", category: "settings-sync")

/// NIP-78 (kind 30078) cross-device sync of the user's non-sensitive UI
/// preferences. The payload is JSON-encoded, NIP-44 self-encrypted (sender
/// + recipient are the same pubkey), and stored as an addressable event
/// under d-tag `wisp-app-settings:v1` so the latest version replaces the
/// previous one via standard NIP-78 semantics.
///
/// Scope: Interface-screen preferences only (Appearance, Media, Posting,
/// Currency). Out of scope: notification sounds, relay auto-auth, and
/// anything that lives outside the Interface screen — see the project
/// memory `project_nip78_settings_completeness.md` for the contract.
///
/// Forward-compat: every field in `AppSettingsPayload` is optional and
/// the struct carries a `version` so future PRs can extend it without
/// breaking round-trip with older clients.
nonisolated enum Nip78AppSettings {
    static let kind = 30078
    static let dTag = "wisp-app-settings:v1"

    /// JSON-serialised payload that round-trips through the encrypted
    /// `content` of the NIP-78 event. All fields optional — missing keys
    /// on the wire mean "this client didn't carry that pref"; existing
    /// fields on the device are left untouched on restore.
    struct AppSettingsPayload: Codable, Equatable {
        // Schema version. Bumped only when an existing field's semantics
        // change incompatibly; pure additions don't require a bump.
        var version: Int? = 1

        // Appearance
        var largeText: Bool?
        var colorScheme: String?
        var themeName: String?
        var accentColorARGB: Int?

        // Media
        var autoLoadMedia: Bool?
        var videoAutoplay: Bool?
        var animateAvatars: Bool?
        var mediaLayoutStyle: String?

        // Posting
        var clientTagEnabled: Bool?
        var postUndoTimerEnabled: Bool?
        var postUndoTimerSeconds: Int?
        var postUndoTimerForReplies: Bool?

        // Currency / zaps
        var fiatModeEnabled: Bool?
        var fiatCurrency: String?
        var zapIconStyle: String?
    }

    /// NIP-44-encrypt the JSON payload to the user's own pubkey and sign
    /// as a kind 30078 event under the `wisp-app-settings:v1` d-tag.
    @MainActor
    static func createPublishEvent(keypair: Keypair, payload: AppSettingsPayload) async throws -> NostrEvent {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(payload), encoding: .utf8) ?? "{}"

        let encrypted = try await Signer.nip44Encrypt(
            keypair: keypair,
            peerPubkey: keypair.pubkey,
            plaintext: json
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

    /// Decrypt + parse a settings event. Returns nil when the content
    /// isn't decryptable or the JSON doesn't parse — callers should treat
    /// nil as "no usable payload here" and skip without surfacing an
    /// error.
    @MainActor
    static func decryptPayload(keypair: Keypair, event: NostrEvent) async -> AppSettingsPayload? {
        do {
            let decrypted = try await Signer.nip44Decrypt(
                keypair: keypair,
                peerPubkey: event.pubkey,
                payload: event.content
            )
            guard let data = decrypted.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(AppSettingsPayload.self, from: data)
        } catch {
            settingsSyncLog.error("decrypt or decode failed for event \(event.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Filter for fetching a user's app-settings event. Kind 30078 is
    /// shared across NIP-78 data classes, so callers MUST filter by
    /// d-tag client-side before treating an event as a settings backup.
    static func filter(pubkey: String) -> NostrFilter {
        NostrFilter(kinds: [kind], authors: [pubkey])
    }

    /// True when an event's d-tag matches this backup namespace. Use to
    /// separate settings events from other NIP-78 data classes (wallet
    /// backups, NWC backups, etc.) returned by the same broad filter.
    static func matches(_ event: NostrEvent) -> Bool {
        event.tags.contains { $0.count >= 2 && $0[0] == "d" && $0[1] == dTag }
    }
}
