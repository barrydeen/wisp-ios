import Foundation
import Observation

/// In-memory + UserDefaults cache of NIP-A3 payment target lists (kind 10133),
/// keyed by pubkey, plus the fetch/publish paths for them.
///
/// Ported from Dark Wisp Android's `PaymentTargetRepository` (cache) and the
/// `FeedViewModel.fetchPaymentTargets` / `WalletViewModel.publishPaymentTargets`
/// halves of the feature.
///
/// `version` is bumped on every cache mutation so SwiftUI views observing this
/// singleton repaint when a late-arriving kind-10133 lands.
@Observable
@MainActor
final class PaymentTargetRepository {
    static let shared = PaymentTargetRepository()
    private init() {}

    private struct Entry {
        let targets: [NipA3.PaymentTarget]
        let updatedAt: Int
    }

    /// Bumped on every cache update. Views that only read through the `targets(for:)`
    /// lookup have nothing else to observe, so they read this to establish a
    /// dependency on the cache as a whole.
    private(set) var version: Int = 0

    // The cache itself is deliberately NOT observed — `version` is the single
    // observable signal, so a cache hydration or an LRU touch doesn't invalidate
    // every view that ever read a target list.
    @ObservationIgnored private var cache: [String: Entry] = [:]
    /// Insertion/refresh order for the bound below. Oldest first.
    @ObservationIgnored private var lru: [String] = []
    /// Pubkeys whose on-demand fetch already ran this session — a miss is cached
    /// as "asked, nothing there" so a profile without targets isn't re-queried on
    /// every visit.
    @ObservationIgnored private var fetchAttempted = Set<String>()
    @ObservationIgnored private var inflight: [String: Task<[NipA3.PaymentTarget], Never>] = [:]

    /// Matches Android's `LruCache(2000)`. Payment target lists are tiny, but the
    /// keyspace is every author the user ever scrolls past.
    private static let maxEntries = 2000

    private static let indexerRelays = RelayDefaults.indexers

    // MARK: - Read

    /// nil = never fetched; `[]` = fetched and known to have none.
    func targets(for pubkey: String) -> [NipA3.PaymentTarget]? {
        if let entry = cache[pubkey] {
            touch(pubkey)
            return entry.targets
        }
        // Cold in-memory cache: hydrate from disk. Nothing changed, so this
        // doesn't bump `version`.
        guard let entry = loadFromDefaults(pubkey) else { return nil }
        cache[pubkey] = entry
        touch(pubkey)
        evictIfNeeded()
        return entry.targets
    }

    func hasEntry(_ pubkey: String) -> Bool { targets(for: pubkey) != nil }

    // MARK: - Ingest

    /// Update the cache from a kind-10133 event. Newer `createdAt` wins.
    @discardableResult
    func ingest(_ event: NostrEvent) -> Bool {
        guard event.kind == NipA3.kind else { return false }
        if let existing = cache[event.pubkey] ?? loadFromDefaults(event.pubkey),
           event.createdAt <= existing.updatedAt {
            return false
        }
        // Unlike relay lists, an empty result must be stored: an empty kind 10133
        // means the user cleared their targets, and dropping it would pin stale ones.
        store(event.pubkey, Entry(targets: NipA3.parse(event), updatedAt: event.createdAt))
        return true
    }

    // MARK: - Fetch

    /// The author's payment targets, fetching their kind-10133 event on demand
    /// (their write relays + indexers) the first time it's needed this session.
    /// Returns the cached list immediately on a hit.
    func fetch(pubkey: String) async -> [NipA3.PaymentTarget] {
        if let cached = targets(for: pubkey) { return cached }
        if let task = inflight[pubkey] { return await task.value }
        guard fetchAttempted.insert(pubkey).inserted else { return [] }

        let task = Task<[NipA3.PaymentTarget], Never> { [weak self] in
            guard let self else { return [] }
            let writeRelays = await RelayListRepository.shared.getWriteRelays(pubkey)
            var relays = Self.indexerRelays
            for url in writeRelays where !relays.contains(url) { relays.append(url) }
            let events = await RelayPool.query(
                relays: relays,
                filter: NostrFilter(kinds: [NipA3.kind], authors: [pubkey], limit: 1),
                timeout: 6
            )
            let best = events
                .filter { $0.kind == NipA3.kind && $0.pubkey == pubkey }
                .max(by: { $0.createdAt < $1.createdAt })
            if let best {
                self.ingest(best)
            }
            return self.targets(for: pubkey) ?? []
        }
        inflight[pubkey] = task
        let result = await task.value
        inflight[pubkey] = nil
        return result
    }

    /// Re-read the active user's own kind-10133 before editing. It's a replaceable
    /// event, so saving on top of a stale copy would clobber targets added from
    /// another client. Bypasses the once-per-session guard `fetch` applies.
    @discardableResult
    func refreshOwn(pubkey: String) async -> [NipA3.PaymentTarget] {
        var relays = Self.indexerRelays
        for url in RelayRouting.topWriteRelays(for: pubkey) where !relays.contains(url) {
            relays.append(url)
        }
        let events = await RelayPool.query(
            relays: relays,
            filter: NostrFilter(kinds: [NipA3.kind], authors: [pubkey], limit: 1),
            timeout: 6
        )
        fetchAttempted.insert(pubkey)
        if let best = events
            .filter({ $0.kind == NipA3.kind && $0.pubkey == pubkey })
            .max(by: { $0.createdAt < $1.createdAt }) {
            ingest(best)
        }
        return targets(for: pubkey) ?? []
    }

    // MARK: - Publish

    enum PublishError: Error {
        case watchOnly
        case signingFailed
        case noRelayConfirmed
    }

    /// Signs and publishes the kind-10133 event, resolving only once at least one
    /// relay returns an `OK` — so the caller can report a truthful result rather
    /// than claiming success the moment the socket opened.
    func publish(targets: [NipA3.PaymentTarget], keypair: Keypair) async throws {
        guard !keypair.isWatchOnly else { throw PublishError.watchOnly }
        // Replaceable events are resolved by `created_at`; never emit one that
        // isn't strictly newer than the copy we already know about, or relays
        // will keep serving the old list.
        let createdAt = max(NostrClock.now(), lastKnownTimestamp(keypair.pubkey) + 1)
        guard let event = try? await Signer.sign(
            keypair: keypair,
            kind: NipA3.kind,
            tags: NipA3.buildTags(targets),
            content: "",
            createdAt: createdAt
        ) else {
            throw PublishError.signingFailed
        }

        var relays = RelayRouting.topWriteRelays(for: keypair.pubkey)
        for url in Self.indexerRelays where !relays.contains(url) { relays.append(url) }
        let accepted = await RelayPool.publish(event: event, to: relays, timeout: 8)
        guard !accepted.isEmpty else { throw PublishError.noRelayConfirmed }

        ingest(event)
    }

    // MARK: - Lifecycle

    func clear() {
        for pubkey in cache.keys {
            UserDefaults.standard.removeObject(forKey: Self.storageKey(pubkey))
        }
        cache.removeAll()
        lru.removeAll()
        fetchAttempted.removeAll()
        inflight.values.forEach { $0.cancel() }
        inflight.removeAll()
        version &+= 1
    }

    // MARK: - Private

    /// `created_at` of the newest kind-10133 we know of for `pubkey`, checking the
    /// on-disk copy too so a cold in-memory cache can't produce a stale timestamp.
    private func lastKnownTimestamp(_ pubkey: String) -> Int {
        if let entry = cache[pubkey] { return entry.updatedAt }
        return loadFromDefaults(pubkey)?.updatedAt ?? 0
    }

    private func store(_ pubkey: String, _ entry: Entry) {
        cache[pubkey] = entry
        touch(pubkey)
        saveToDefaults(pubkey, entry)
        evictIfNeeded()
        version &+= 1
    }

    private func touch(_ pubkey: String) {
        if let idx = lru.firstIndex(of: pubkey) { lru.remove(at: idx) }
        lru.append(pubkey)
    }

    private func evictIfNeeded() {
        while lru.count > Self.maxEntries {
            let oldest = lru.removeFirst()
            cache.removeValue(forKey: oldest)
            fetchAttempted.remove(oldest)
            UserDefaults.standard.removeObject(forKey: Self.storageKey(oldest))
        }
    }

    private static func storageKey(_ pubkey: String) -> String { "payment_targets_\(pubkey)" }

    private func saveToDefaults(_ pubkey: String, _ entry: Entry) {
        let dict: [String: Any] = [
            "targets": entry.targets.map { [$0.type, $0.authority] },
            "t": entry.updatedAt
        ]
        UserDefaults.standard.set(dict, forKey: Self.storageKey(pubkey))
    }

    private func loadFromDefaults(_ pubkey: String) -> Entry? {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.storageKey(pubkey)) else { return nil }
        let raw = dict["targets"] as? [[String]] ?? []
        let updatedAt = dict["t"] as? Int ?? 0
        let targets = raw.compactMap { pair -> NipA3.PaymentTarget? in
            guard pair.count >= 2, let type = NipA3.normalizeType(pair[0]),
                  NipA3.isValidAuthority(pair[1]) else { return nil }
            return NipA3.PaymentTarget(type: type, authority: pair[1])
        }
        return Entry(targets: targets, updatedAt: updatedAt)
    }
}
