import Foundation

/// Where in the event ingest path the check is being performed. Different surfaces want
/// slightly different rules — e.g. DMs bypass word filtering because rumors are
/// e2e-encrypted and we don't second-guess what the sender chose to send.
enum SafetyContext: Sendable, Equatable {
    case feed
    case notifications
    case thread(rootId: String)
    case messages
}

/// Immutable snapshot of every filter input. Reads happen via a single pointer load on the
/// hot path; the snapshot is replaced atomically when a setting changes.
final class SafetyFilterSnapshot: @unchecked Sendable {
    let mutedWords: Set<String>           // already lowercased
    let blockedPubkeys: Set<String>
    let mutedThreads: Set<String>
    let wotEnabled: Bool
    let qualifiedNetwork: Set<String>     // empty when WoT off or never computed
    let userPubkey: String                // empty before bind

    init(mutedWords: Set<String>, blockedPubkeys: Set<String>, mutedThreads: Set<String>,
         wotEnabled: Bool, qualifiedNetwork: Set<String>, userPubkey: String) {
        self.mutedWords = mutedWords
        self.blockedPubkeys = blockedPubkeys
        self.mutedThreads = mutedThreads
        self.wotEnabled = wotEnabled
        self.qualifiedNetwork = qualifiedNetwork
        self.userPubkey = userPubkey
    }

    static let empty = SafetyFilterSnapshot(
        mutedWords: [], blockedPubkeys: [], mutedThreads: [],
        wotEnabled: false, qualifiedNetwork: [], userPubkey: ""
    )
}

/// Global event-ingestion filter. View models call `shouldDrop` on every event from every
/// live subscription. The call is lockless: it reads `_current` (a class reference) and runs
/// a few Set lookups + at most one substring sweep. Mutation goes through `rebuildSnapshot`,
/// which gathers data from the MainActor repos and the WoT actor, then atomically swaps in
/// a fresh snapshot. Brief staleness during a swap (one runloop tick) is acceptable for a
/// safety filter; the hot path never blocks.
final class SafetyFilter: @unchecked Sendable {
    static let shared = SafetyFilter()

    /// WoT bypasses these kinds so toggling it on doesn't hide profiles, follow lists, DMs,
    /// gift wraps, or NIP-17 inbox metadata. Mirrors the Android `WOT_EXEMPT_KINDS` set.
    static let wotExemptKinds: Set<Int> = [0, 3, 4, 10002, 10006, 10007, 10050, 1059, 13, 14]

    private let writeLock = NSLock()
    nonisolated(unsafe) private var _current: SafetyFilterSnapshot = .empty

    /// Bounded LRU of lowercased event content keyed by event id. The hot path
    /// `containsMutedWord` previously called `event.content.lowercased()` on
    /// every check, allocating a fresh String even when re-checking the same
    /// event after a mute-list rebuild. 1024 entries × ~1 KB avg → ~1 MB cap.
    private let lowercaseCache = LowercaseCache(capacity: 1024)

    private init() {}

    var snapshot: SafetyFilterSnapshot { _current }

    /// Hot path. Single pointer read of `_current`; no actor hop, no lock.
    func shouldDrop(event: NostrEvent, context: SafetyContext) -> Bool {
        let s = _current

        if !s.blockedPubkeys.isEmpty, s.blockedPubkeys.contains(event.pubkey) {
            return true
        }

        // Kind-6 reposts wrap an inner kind-1 from another author. If the
        // reposter isn't muted but the *original* author is, the wrap would
        // otherwise let the muted author's content leak through. Parse the
        // inner pubkey out of the JSON content and apply the same block check.
        if event.kind == 6, !s.blockedPubkeys.isEmpty,
           let innerPubkey = Self.repostInnerPubkey(event),
           s.blockedPubkeys.contains(innerPubkey) {
            return true
        }

        let allowsWordCheck: Bool = {
            switch context {
            case .feed, .notifications: return true
            case .thread, .messages: return false
            }
        }()
        if allowsWordCheck, !s.mutedWords.isEmpty,
           containsMutedWord(eventId: event.id, content: event.content, words: s.mutedWords) {
            return true
        }

        if !s.mutedThreads.isEmpty {
            switch context {
            case .feed, .notifications:
                // Drop any reply anchored to a muted root.
                for tag in event.tags where tag.count >= 2 && tag[0] == "e" {
                    if s.mutedThreads.contains(tag[1]) { return true }
                }
            case .thread, .messages:
                break
            }
        }

        if s.wotEnabled,
           !Self.wotExemptKinds.contains(event.kind),
           !s.qualifiedNetwork.isEmpty,
           event.pubkey != s.userPubkey,
           !s.qualifiedNetwork.contains(event.pubkey) {
            return true
        }

        return false
    }

    /// Install a freshly-built snapshot. Lockfree readers pick up the new pointer on their
    /// next read; old snapshots remain valid for any in-flight read.
    func install(_ snap: SafetyFilterSnapshot) {
        writeLock.lock()
        _current = snap
        writeLock.unlock()
    }

    /// Rebuild the snapshot from the active sources. Called on login, after every mute /
    /// safelist edit, and after every WoT recompute.
    func rebuildSnapshot() async {
        let mutes: (words: Set<String>, pubkeys: Set<String>, threads: Set<String>) =
            await MainActor.run {
                let m = MuteRepository.shared
                return (m.mutedWords, m.blockedPubkeys, m.mutedThreads)
            }
        let prefs: (wot: Bool, pubkey: String) = await MainActor.run {
            let p = SafetyPreferences.shared
            return (p.wotFilterEnabled, p.activePubkey ?? "")
        }
        let qualified = await ExtendedNetworkRepository.shared.qualifiedSet()

        install(SafetyFilterSnapshot(
            mutedWords: mutes.words,
            blockedPubkeys: mutes.pubkeys,
            mutedThreads: mutes.threads,
            wotEnabled: prefs.wot,
            qualifiedNetwork: qualified,
            userPubkey: prefs.pubkey
        ))
    }

    // MARK: - Private

    private func containsMutedWord(eventId: String, content: String, words: Set<String>) -> Bool {
        let lower = lowercaseCache.get(key: eventId, fallback: content)
        for w in words where lower.contains(w) { return true }
        return false
    }

    /// Pull the original author's pubkey out of a kind-6 repost. Prefers the
    /// embedded event JSON in `content`; falls back to the `p` tag when the
    /// reposter omits the embedded event (common with non-damus clients).
    /// Static so the lockfree hot path can call it without an actor hop.
    private static func repostInnerPubkey(_ event: NostrEvent) -> String? {
        if !event.content.isEmpty,
           let data = event.content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pk = json["pubkey"] as? String, !pk.isEmpty {
            return pk
        }
        return event.tags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1]
    }
}

/// Bounded FIFO of lowercased strings keyed by event id. Lookups are O(1);
/// the eviction list lets us cap memory without an OS-managed NSCache (which
/// can be aggressive under simulator-low-memory scenarios).
private final class LowercaseCache: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var byKey: [String: String] = [:]
    private var order: [String] = []

    init(capacity: Int) {
        self.capacity = capacity
        self.byKey.reserveCapacity(capacity)
        self.order.reserveCapacity(capacity)
    }

    func get(key: String, fallback: @autoclosure () -> String) -> String {
        lock.lock()
        if let cached = byKey[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let lower = fallback().lowercased()
        lock.lock()
        if byKey[key] == nil {
            byKey[key] = lower
            order.append(key)
            while order.count > capacity {
                let evict = order.removeFirst()
                byKey.removeValue(forKey: evict)
            }
        }
        lock.unlock()
        return lower
    }
}
