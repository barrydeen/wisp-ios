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
    let qualifiedNetwork: Set<String>     // empty when WoT off or never computed — with
                                          // wotEnabled that means FAIL CLOSED (drop all)
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

        // Web of Trust — FAIL CLOSED: while the filter is on, any non-exempt
        // event whose author can't be positively qualified is dropped, even
        // when `qualifiedNetwork` is empty (never computed / cache lost). The
        // settings toggle force-starts a graph compute and the login path
        // auto-recomputes a stale one, so the empty-set state is brief — and a
        // safety filter that hides graphic content must hide *everything*
        // rather than silently no-op while that compute runs.
        if s.wotEnabled, !Self.wotExemptKinds.contains(event.kind) {
            switch event.kind {
            case 9735:
                // Zap receipts are signed by the LN service, not the zapper —
                // judging `event.pubkey` here would drop every zap (or none)
                // regardless of who sent it. `NotificationRepository.ingest`
                // enforces WoT on the classified item's resolved zap-request
                // signer instead.
                break
            case 6:
                // Reposts must qualify on BOTH authors: the reposter and the
                // wrapped original author — otherwise a qualified reposter
                // leaks a stranger's content. An unparseable inner author
                // fails closed. JSON parse cost is paid only for kind-6 with
                // WoT on, same profile as the block check above.
                if !wotQualifies(event.pubkey, s) { return true }
                guard let inner = Self.repostInnerPubkey(event),
                      wotQualifies(inner, s) else { return true }
            default:
                if !wotQualifies(event.pubkey, s) { return true }
            }
        }

        return false
    }

    /// Whether `pubkey`'s content may render under the current snapshot's WoT
    /// rules. True when WoT is off, for the user themself, and for qualified-
    /// network members. Single `_current` load — safe from any actor, cheap
    /// enough for render gates and in-memory purges.
    func isWotQualified(_ pubkey: String) -> Bool {
        let s = _current
        return !s.wotEnabled || wotQualifies(pubkey, s)
    }

    private func wotQualifies(_ pubkey: String, _ s: SafetyFilterSnapshot) -> Bool {
        pubkey == s.userPubkey || s.qualifiedNetwork.contains(pubkey)
    }

    /// Block-list-only gate used by the persistence chokepoint (`EventStore.persist`)
    /// to drop blocked authors' content *before it ever reaches disk*. Unlike
    /// `shouldDrop`, it deliberately ignores word / thread / WoT filters — those are
    /// reversible, context-dependent preferences and must never permanently evict an
    /// event from on-disk storage. Matches the direct author OR the inner author of a
    /// kind-6 repost. Lockless `_current` read; safe to call from any actor.
    func isHardBlocked(event: NostrEvent) -> Bool {
        let s = _current
        guard !s.blockedPubkeys.isEmpty else { return false }
        if s.blockedPubkeys.contains(event.pubkey) { return true }
        if event.kind == 6,
           let innerPubkey = Self.repostInnerPubkey(event),
           s.blockedPubkeys.contains(innerPubkey) {
            return true
        }
        return false
    }

    /// Install a freshly-built snapshot. Lockfree readers pick up the new pointer on their
    /// next read; old snapshots remain valid for any in-flight read.
    ///
    /// Posts `.safetyFilterChanged` so surfaces holding already-ingested events
    /// (notifications list, open thread tree, feed window) re-filter their
    /// in-memory state immediately — without it, content that newly fails the
    /// WoT filter would stay visible until relaunch. Posted only on install
    /// (rare: login, mute edit, WoT toggle/recompute), never on the read path.
    func install(_ snap: SafetyFilterSnapshot) {
        writeLock.lock()
        _current = snap
        writeLock.unlock()
        NotificationCenter.default.post(name: .safetyFilterChanged, object: nil)
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
    /// Static so the lockfree hot path can call it without an actor hop. Internal
    /// (not private) so `EventStore.removeByAuthor` can reuse it to purge reposts
    /// of a blocked author from disk.
    static func repostInnerPubkey(_ event: NostrEvent) -> String? {
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
extension Notification.Name {
    /// Posted by `SafetyFilter.install` after every snapshot swap. Sibling of
    /// `.userBlocked` (MuteRepository): that one announces a specific block-list
    /// edit; this one announces "the filter rules changed, re-filter what you
    /// hold" — the only mid-session propagation path for WoT toggle/recompute.
    static let safetyFilterChanged = Notification.Name("WispSafetyFilterChanged")
}

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
