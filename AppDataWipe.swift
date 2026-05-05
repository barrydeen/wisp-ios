import Foundation
import Security

/// One-shot total-wipe helper, called from MainView's logout path. Leaves the
/// app in the same state as a fresh install: no keypair, no UserDefaults, no
/// keychain items, no on-disk caches, no in-memory singletons.
///
/// Order matters here: live state (sockets, in-memory caches) is torn down
/// first so nothing tries to write back to ObjectBox / UserDefaults while we're
/// emptying them. Then we wipe persisted state from biggest blast-radius (the
/// keychain catch-all) down to per-pubkey UserDefaults entries.
///
/// We deliberately do NOT delete the ObjectBox store directory — the singleton
/// holds a force-unwrapped `Store!` initialized in `wispApp.init`, and there is
/// no clean way to tear it down + re-init mid-process. Emptying every box has
/// the same observable effect from the user's perspective.
@MainActor
enum AppDataWipe {

    static func wipeEverything() async {
        // 1. Quiesce live workers so they stop touching state we're about to delete.
        RelayPool.authSigner = nil
        RelayPool.authApprovalCheck = nil
        await GroupRelayPool.shared.shutdownAll()
        // Tear down the active NIP-46 client. Without this its three per-relay
        // sockets stay alive in the background, hammer the same relays with
        // exponential-backoff reconnects, and starve the next login attempt
        // of relay connections (the `get_public_key` response never lands).
        await Nip46Manager.shared.clearActive()

        // 2. In-memory singletons — match the existing logout flow plus the wallet store.
        EngagementRepository.shared.clear()
        PollTallyRepository.shared.clear()
        EmojiRepository.shared.clear()
        NoteSourceTracker.shared.clear()
        LiveStreamRepository.shared.clear()
        LivePlayerStore.shared.releaseAll()
        MuteRepository.shared.unbind()
        SafetyPreferences.shared.unbind()

        // 3. Empty the ObjectBox boxes. Both stores are actors; awaits serialise
        //    against any in-flight persists from the same isolation domain.
        await EventStore.shared.removeAll()
        await GroupStore.shared.removeAll()

        await ExtendedNetworkRepository.shared.unbind()
        await SafetyFilter.shared.rebuildSnapshot()
        await SpamScorer.shared.clearCache()

        // 4. On-disk state under Application Support (per-account SQLite + Spark wallet
        //    storage) and the wisp-prefixed cache directories.
        wipeFilesystem()

        // 5. Keychain. A single SecItemDelete on the service nukes every account
        //    we own — `active`, `account_<pubkey>`, `nwc_<pubkey>`, `spark_seed_<pubkey>`.
        wipeKeychain()

        // 6. UserDefaults. removePersistentDomain wipes everything in the standard
        //    suite for this bundle id; no per-key allow-list to maintain.
        wipeUserDefaults()

        // 7. URLCache for any image/data fetches that bypassed our own caches.
        URLCache.shared.removeAllCachedResponses()
    }

    // MARK: - Filesystem

    private static func wipeFilesystem() {
        let fm = FileManager.default

        // Application Support/wisp/{social_graph_*.db, spark_data/}.
        // Leave the objectbox/ subdir alone — its store handle is still live.
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let wispDir = support.appendingPathComponent("wisp", isDirectory: true)
            if let entries = try? fm.contentsOfDirectory(at: wispDir, includingPropertiesForKeys: nil) {
                for entry in entries {
                    let name = entry.lastPathComponent
                    if name == "objectbox" { continue }
                    try? fm.removeItem(at: entry)
                }
            }
        }

        // Caches/{wisp_avatars, wisp_emojis}. Image data, no other implications.
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? fm.removeItem(at: caches.appendingPathComponent("wisp_avatars", isDirectory: true))
            try? fm.removeItem(at: caches.appendingPathComponent("wisp_emojis", isDirectory: true))
        }
    }

    // MARK: - Keychain

    private static func wipeKeychain() {
        // Service-level wipe: matches NostrKey.service ("com.wisp.nostr") which
        // WalletKeychain also uses, so this catches NostrKey + NWC URI + Spark seed.
        for service in ["com.wisp.nostr", "com.wisp.nip46"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    // MARK: - UserDefaults

    private static func wipeUserDefaults() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: bundleId)
        // App-group / shared suites are also wiped if they were registered — none
        // exist in this codebase today, but if they're added later they should
        // join this list.
    }
}
