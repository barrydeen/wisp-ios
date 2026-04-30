import Foundation

@MainActor
final class ProfileRepository {
    static let shared = ProfileRepository()

    private var cache: [String: ProfileData] = [:]
    private var timestamps: [String: Int] = [:]

    /// Per-pubkey inflight ensure task. Stops a wave of row renders from kicking
    /// off N parallel indexer queries for the same pubkey — every caller awaits
    /// the same task. Mirrors Jumble's `DataLoader` and Primal's per-subid
    /// coalescing.
    private var inflight: [String: Task<ProfileData?, Never>] = [:]

    private static let indexerRelays = [
        "wss://indexer.nostrarchives.com",
        "wss://indexer.coracle.social",
        "wss://relay.damus.io",
        "wss://relay.primal.net"
    ]

    func get(_ pubkey: String) -> ProfileData? {
        if let cached = cache[pubkey] { return cached }
        return loadFromDefaults(pubkey)
    }

    func getAll(_ pubkeys: [String]) -> [String: ProfileData] {
        var result: [String: ProfileData] = [:]
        for pk in pubkeys {
            if let p = get(pk) { result[pk] = p }
        }
        return result
    }

    /// Ensure every requested pubkey is in the cache, kicking a single batched
    /// indexer query for any that aren't. Returns the merged dict (cached +
    /// freshly fetched). Pubkeys whose kind-0 didn't resolve are absent from
    /// the result. Safe to call repeatedly — concurrent callers asking for the
    /// same missing pubkey share a single inflight fetch.
    @discardableResult
    func ensure(_ pubkeys: [String]) async -> [String: ProfileData] {
        var result: [String: ProfileData] = [:]
        var missing: [String] = []
        var awaiting: [String] = []
        for pk in pubkeys {
            if let cached = get(pk) {
                result[pk] = cached
            } else if inflight[pk] != nil {
                awaiting.append(pk)
            } else {
                missing.append(pk)
            }
        }

        if !missing.isEmpty {
            let fetchTask = Task { [weak self] () -> [String: ProfileData] in
                guard let self else { return [:] }
                return await self.runFetch(pubkeys: missing)
            }
            // Register a per-pubkey continuation task so concurrent callers asking
            // for the same key just await the shared fetch.
            for pk in missing {
                inflight[pk] = Task { [weak self] in
                    let dict = await fetchTask.value
                    self?.inflight[pk] = nil
                    return dict[pk]
                }
            }
            let dict = await fetchTask.value
            for pk in missing {
                if let p = dict[pk] { result[pk] = p }
            }
        }

        for pk in awaiting {
            if let task = inflight[pk], let p = await task.value {
                result[pk] = p
            }
        }

        return result
    }

    private func runFetch(pubkeys: [String]) async -> [String: ProfileData] {
        var out: [String: ProfileData] = [:]
        for batch in pubkeys.chunked(into: 150) {
            let events = await RelayPool.query(
                relays: Self.indexerRelays,
                filter: NostrFilter(kinds: [0], authors: batch),
                timeout: 8
            )
            var bestByAuthor: [String: NostrEvent] = [:]
            for event in events where event.kind == 0 {
                if let existing = bestByAuthor[event.pubkey], event.createdAt <= existing.createdAt { continue }
                bestByAuthor[event.pubkey] = event
            }
            for (_, event) in bestByAuthor {
                if let profile = updateFromEvent(event) {
                    out[event.pubkey] = profile
                }
            }
        }
        return out
    }

    @discardableResult
    func updateFromEvent(_ event: NostrEvent) -> ProfileData? {
        guard event.kind == 0 else { return nil }
        if let existing = timestamps[event.pubkey], event.createdAt < existing {
            return cache[event.pubkey]
        }
        guard let data = event.content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let emojiMap = ContentParser.parseEmojiTags(event.tags)
        let profile = ProfileData(pubkey: event.pubkey, json: json, emojiMap: emojiMap)
        cache[event.pubkey] = profile
        timestamps[event.pubkey] = event.createdAt
        saveToDefaults(event.pubkey, profile, event.createdAt)
        // Aggressively pull the avatar bytes so any subsequent CachedAvatarView
        // renders from cache without a network round-trip. Also pre-load any
        // custom-emoji images declared by this profile so `EmojiText` doesn't
        // flash shortcodes when the name first appears.
        if let pic = profile.picture {
            Task { await AvatarPrefetcher.shared.enqueue(pic) }
        }
        for url in emojiMap.values {
            EmojiImageCache.shared.ensureLoaded(url)
        }
        return profile
    }

    // MARK: - Private

    private static let emojiKeySuffix = "_emoji"

    private func saveToDefaults(_ pubkey: String, _ profile: ProfileData, _ timestamp: Int) {
        let dict: [String: String] = [
            "name": profile.name,
            "display_name": profile.displayName,
            "picture": profile.picture,
            "banner": profile.banner,
            "about": profile.about,
            "nip05": profile.nip05,
            "lud16": profile.lud16
        ].compactMapValues { $0 }
        UserDefaults.standard.set(dict, forKey: "profile_\(pubkey)")
        UserDefaults.standard.set(timestamp, forKey: "profile_ts_\(pubkey)")
        if !profile.emojiMap.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: profile.emojiMap) {
            UserDefaults.standard.set(data, forKey: "profile_\(pubkey)\(Self.emojiKeySuffix)")
        } else {
            UserDefaults.standard.removeObject(forKey: "profile_\(pubkey)\(Self.emojiKeySuffix)")
        }
    }

    /// Reads the persisted profile for `pubkey` directly from UserDefaults,
    /// bypassing the in-memory cache. Use this when you need the stored profile
    /// for an account that isn't the active session (e.g. account switcher rows).
    func persistedProfile(for pubkey: String) -> ProfileData? {
        loadFromDefaults(pubkey)
    }

    private func loadFromDefaults(_ pubkey: String) -> ProfileData? {
        guard let dict = UserDefaults.standard.dictionary(forKey: "profile_\(pubkey)") as? [String: Any],
              !dict.isEmpty else { return nil }
        var emojiMap: [String: String] = [:]
        if let data = UserDefaults.standard.data(forKey: "profile_\(pubkey)\(Self.emojiKeySuffix)"),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            emojiMap = parsed
        }
        let profile = ProfileData(pubkey: pubkey, json: dict, emojiMap: emojiMap)
        let ts = UserDefaults.standard.integer(forKey: "profile_ts_\(pubkey)")
        cache[pubkey] = profile
        if ts > 0 { timestamps[pubkey] = ts }
        return profile
    }
}
