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
    /// `created_at` of the kind-3 that produced the stored follow set, per
    /// pubkey. Used by `reconcile` to refuse a stale relay copy. 0 means
    /// "unknown" — e.g. a set persisted before this field existed; in that
    /// case any relay copy is allowed to replace it.
    private var createdAtByPubkey: [String: Int] = [:]

    private init() {}

    nonisolated private static func key(for pubkey: String) -> String {
        "follow_pubkeys_\(pubkey)"
    }

    nonisolated private static func createdAtKey(for pubkey: String) -> String {
        "follow_pubkeys_ts_\(pubkey)"
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

    /// `created_at` of the kind-3 that produced the stored follow set, or 0 if
    /// unknown. Loads from UserDefaults on first access (mirrors `follows`).
    nonisolated func storedCreatedAt(for pubkey: String) -> Int {
        lock.lock()
        if let cached = createdAtByPubkey[pubkey] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let ts = UserDefaults.standard.integer(forKey: Self.createdAtKey(for: pubkey))
        lock.lock()
        createdAtByPubkey[pubkey] = ts
        lock.unlock()
        return ts
    }

    /// Persist a new follow list. Updates the in-memory cache *and*
    /// UserDefaults so callers reading via the legacy key still see the
    /// fresh value. `createdAt` is the `created_at` of the kind-3 this set
    /// came from (the just-published event for local edits) — stored so
    /// `reconcile` can tell a fresher relay copy from a stale one.
    nonisolated func update(pubkey: String, follows: [String], createdAt: Int) {
        let set = Set(follows)
        lock.lock()
        byPubkey[pubkey] = follows
        setByPubkey[pubkey] = set
        createdAtByPubkey[pubkey] = createdAt
        lock.unlock()
        UserDefaults.standard.set(follows, forKey: Self.key(for: pubkey))
        UserDefaults.standard.set(createdAt, forKey: Self.createdAtKey(for: pubkey))
        // Notify avatar follow-status badges (and anything else tracking the
        // follow set) to re-query. `update` is `nonisolated` and may run off
        // the main thread; post on the main actor so observers (which mutate
        // SwiftUI state) fire on main, and because the `Notification.Name`
        // extension is main-actor isolated under default isolation.
        Task { @MainActor in
            NotificationCenter.default.post(name: .followsDidChange, object: nil)
        }
    }

    /// Adopt a follow set fetched from relays ONLY if its kind-3 is strictly
    /// newer than the one that produced the currently-stored set. This is the
    /// reconciliation the local cache previously lacked: the cache was only
    /// ever written at onboarding and on in-app follow/unfollow, so a follow
    /// list edited in another client (e.g. trimmed via an external tool) was
    /// never reflected locally — and the next in-app edit republished the
    /// stale set, clobbering the change. Gating on `created_at` lets an
    /// out-of-band change (which carries a newer timestamp) replace the frozen
    /// snapshot while refusing a stale relay copy that would undo a fresher
    /// local edit. Returns true if it replaced the stored set.
    @discardableResult
    nonisolated func reconcile(pubkey: String, follows: [String], createdAt: Int) -> Bool {
        guard createdAt > storedCreatedAt(for: pubkey) else { return false }
        update(pubkey: pubkey, follows: follows, createdAt: createdAt)
        return true
    }

    /// Drop the cache entry for `pubkey`. Called from `NostrKey.deleteAccount`.
    nonisolated func invalidate(pubkey: String) {
        lock.lock()
        byPubkey.removeValue(forKey: pubkey)
        setByPubkey.removeValue(forKey: pubkey)
        createdAtByPubkey.removeValue(forKey: pubkey)
        lock.unlock()
    }
}
