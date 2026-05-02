import Foundation

/// Process-wide memoized accessor for the per-account follow list.
///
/// Without this, every view model that touches follows
/// (`FeedViewModel`, `NotificationsViewModel`, `ThreadViewModel`,
/// `ProfileViewModel`, `SocialGraphRepository`, `MentionSearch`,
/// `FollowSender`, `SearchViewModel`, `ExtendedNetworkRepository`,
/// `AddToPeopleListPickerSheet`) goes back to UserDefaults on cold start.
/// For a 500+-follow user that's 10× plist deserializations of the same
/// 500-string array. Cache once per pubkey; UserDefaults reads only happen
/// on first access or after `update`.
///
/// Thread-safe via an internal lock so non-MainActor callers (actor
/// `ExtendedNetworkRepository`, async `FollowSender`) can use it directly.
nonisolated final class FollowsCache: @unchecked Sendable {
    nonisolated static let shared = FollowsCache()

    private let lock = NSLock()
    private var byPubkey: [String: [String]] = [:]
    private var setByPubkey: [String: Set<String>] = [:]

    private init() {}

    nonisolated private static func key(for pubkey: String) -> String {
        "follow_pubkeys_\(pubkey)"
    }

    /// Returns the follow array for `pubkey`, loading from UserDefaults on
    /// first access. The returned array preserves insertion order.
    nonisolated func follows(for pubkey: String) -> [String] {
        lock.lock()
        if let cached = byPubkey[pubkey] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let arr = UserDefaults.standard.stringArray(forKey: Self.key(for: pubkey)) ?? []
        let set = Set(arr)
        lock.lock()
        byPubkey[pubkey] = arr
        setByPubkey[pubkey] = set
        lock.unlock()
        return arr
    }

    /// Set-form for membership tests. Same caching, no extra UserDefaults hit.
    nonisolated func followsSet(for pubkey: String) -> Set<String> {
        lock.lock()
        if let cached = setByPubkey[pubkey] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        _ = follows(for: pubkey)
        lock.lock()
        let s = setByPubkey[pubkey] ?? []
        lock.unlock()
        return s
    }

    /// Persist a new follow list. Updates the in-memory cache *and*
    /// UserDefaults so callers reading via the legacy key still see the
    /// fresh value.
    nonisolated func update(pubkey: String, follows: [String]) {
        let set = Set(follows)
        lock.lock()
        byPubkey[pubkey] = follows
        setByPubkey[pubkey] = set
        lock.unlock()
        UserDefaults.standard.set(follows, forKey: Self.key(for: pubkey))
    }

    /// Drop the cache entry for `pubkey`. Called from `NostrKey.deleteAccount`.
    nonisolated func invalidate(pubkey: String) {
        lock.lock()
        byPubkey.removeValue(forKey: pubkey)
        setByPubkey.removeValue(forKey: pubkey)
        lock.unlock()
    }
}
