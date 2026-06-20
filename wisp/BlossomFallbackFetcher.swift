import Foundation
import os

/// Fetches a blob from a Blossom server when the primary URL fails, using the
/// author's kind-10063 server list (BUD-03). Verifies the SHA-256 digest of the
/// downloaded data before returning it.
///
/// Privacy design: this fetcher ONLY performs unauthenticated public GETs. We
/// intentionally do not send the user's Nostr auth event to the author's servers,
/// because those servers are chosen by the AUTHOR, not the reader — a malicious
/// author could deanonymize viewers by collecting reader pubkeys from auth attempts.
/// If an author's fallback server requires auth (401), fallback silently skips it.
///
/// Server resolution: uses cached kind-10063 lists for the given authorPubkey.
/// In practice, these caches are populated for the current user's pubkey (via
/// compose/upload flows) but NOT for arbitrary content authors. For unknown authors,
/// this falls back to the default server (primal.net per BlossomServerList.defaultServer).
/// Future enhancement: prefetch kind-10063 for content authors during feed load to
/// enable full BUD-03 multi-server fallback.
enum BlossomFallbackFetcher {

    #if DEBUG
    private static let sessionOverrideLock = NSLock()
    private static var _sessionOverride: URLSession?
    static var sessionOverride: URLSession? {
        get {
            sessionOverrideLock.lock()
            defer { sessionOverrideLock.unlock() }
            return _sessionOverride
        }
        set {
            sessionOverrideLock.lock()
            _sessionOverride = newValue
            sessionOverrideLock.unlock()
        }
    }
    static var session: URLSession {
        sessionOverrideLock.lock()
        let override = _sessionOverride
        sessionOverrideLock.unlock()
        return override ?? Self.noRedirectSession
    }
    #else
    static var session: URLSession { Self.noRedirectSession }
    #endif

    /// Dedicated session that refuses HTTP redirects (BUD-03 privacy invariant).
    /// A 301/302 from an author's server must NOT silently switch hosts to an
    /// arbitrary attacker-controlled URL — the bytes are verified against SHA-256
    /// anyway, but a redirect-aware fetch leaks the reader's IP + target hash
    /// to whatever host the redirect points at.
    nonisolated(unsafe) private static let noRedirectSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config, delegate: RedirectBlocker.shared, delegateQueue: nil)
        return session
    }()

    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        static let shared = RedirectBlocker()
        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// Maximum concurrent fallback GETs per fetch call.
    /// Uses `BlossomClient.maxConcurrentOperations` for a consistent cap across
    /// all Blossom network surfaces (uploads, mirrors, fallback fetches).
    private static let maxConcurrentFetches = BlossomClient.maxConcurrentOperations

    /// Prevents duplicate fetches from racing for the same (hash, author) pair.
    /// Holds the cooldown cache and in-flight registry under the same lock so
    /// concurrent callers see consistent state.
    private static let cooldownLock = NSLock()

    /// Cooldown cache to prevent repeated fallback attempts for the same (hash + author).
    /// Key: "<hash>|<authorPubkey>", Value: timestamp of last *failed* attempt. TTL: 5 minutes.
    /// Capped at 512 entries to prevent unbounded memory growth in long sessions.
    ///
    /// Keyed by (hash, authorPubkey) rather than hash alone so that two authors posting
    /// the same content-addressed image with different server lists get independent attempts.
    /// Recorded ONLY on failure so that a transient network error during the first attempt
    /// does not permanently suppress a retry that might succeed after connectivity recovers.
    ///
    /// Stored in a plain locked dictionary instead of NSCache: NSCache may evict
    /// entries under memory pressure without notifying us, which would let a
    /// second caller retry a "failed" blob mid-cooldown and double the network
    /// load on the original author's servers.
    private static var cooldownCache: [String: Date] = [:]

    /// In-flight fetches keyed by "<hash>|<authorPubkey>". When two callers ask
    /// for the same (hash, author) at the same time, the second awaits the first's
    /// `Data?` result instead of issuing a parallel network request. Avoids the
    /// 2× bandwidth and 2× server load that NSCache-based dedup couldn't prevent.
    /// Held under `cooldownLock` so registration, lookup, and completion are atomic.
    private static var inFlight: [String: InFlightRegistry] = [:]

    private static let cooldownTTLSeconds: TimeInterval = 300  // 5 minutes
    private static let cooldownMaxEntries = 512

    #if DEBUG
    /// Test-only: clear all cooldown and in-flight state so tests start clean.
    static func resetCooldownForTesting() {
        cooldownLock.lock()
        cooldownCache.removeAll()
        inFlight.removeAll()
        cooldownLock.unlock()
    }
    #endif

    private enum FetchError: Error {
        /// Returned when the downloaded bytes do not match the expected SHA-256.
        /// Distinct from Foundation's `cannotDecodeContentData` to avoid semantic confusion.
        case integrityMismatch
    }

    /// Attempts to fetch and verify a blob from the author's Blossom servers.
    /// Uses the cached kind-10063 list to avoid triggering relay queries per failure.
    /// - Parameters:
    ///   - url: The originally failed URL (used to extract the hash and optionally extension).
    ///   - authorPubkey: The pubkey of the event author, to look up their kind-10063 server list.
    /// - Returns: The verified `Data` if successful, or nil if all servers reject/skip.
    static func fetch(url: URL, authorPubkey: String) async -> Data? {
        guard let expectedHash = ContentParser.sha256Hash(fromUrl: url.absoluteString) else {
            return nil
        }

        // Privacy + correctness gate: only attempt fallback for authors we have an
        // explicit kind-10063 list for. Without it, we can't know which servers
        // to try — sending requests to default community servers exposes the
        // reader's IP + target hash to hosts unrelated to the author, and may
        // never find the blob. Prefetching kind-10063 for content authors is
        // tracked separately (see `cached(for:)` callers for refresh paths).
        guard BlossomServerList.hasStoredServers(for: authorPubkey) else {
            return nil
        }

        let cooldownKey = "\(expectedHash)|\(authorPubkey)"

        // Cooldown check + in-flight dedup under one lock so the two states are
        // always consistent across concurrent callers.
        cooldownLock.lock()
        let inCooldown: Bool = {
            guard let lastFailedAt = cooldownCache[cooldownKey] else { return false }
            return Date().timeIntervalSince(lastFailedAt) < cooldownTTLSeconds
        }()
        if inCooldown {
            cooldownLock.unlock()
            os_log(.debug, "BlossomFallbackFetcher: skipping fallback for %{private}@ (cooldown active)", expectedHash)
            return nil
        }
        if let existing = inFlight[cooldownKey] {
            // Second caller: park until the first finishes. Returning the
            // first's Data? (including nil) keeps every concurrent caller
            // informed without launching a parallel network request.
            cooldownLock.unlock()
            return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                existing.addAwaiter(continuation)
            }
        }
        // First caller: register ourselves as the in-flight owner. `awaiters`
        // holds every concurrent caller that arrived after us; they'll be
        // resumed with the same `Data?` result we produce.
        let registry = InFlightRegistry()
        inFlight[cooldownKey] = registry
        cooldownLock.unlock()

        // Use cached list — no relay query. These are populated for users who
        // have run compose/upload flows at least once (kind-10063 cached locally)
        // or whose kind-10063 was prefetched by an out-of-band path.
        let servers = BlossomServerList.cached(for: authorPubkey)
        let ext = fileExtension(from: url)

        // Build fetch targets for all valid servers.
        let targets: [URL] = servers.compactMap { server in
            guard let normalized = BlossomClient.normalizeServerURL(server) else { return nil }
            let path = ext.isEmpty ? "/\(expectedHash)" : "/\(expectedHash).\(ext)"
            return URL(string: normalized + path)
        }

        // Fan-out all servers in parallel with a `maxConcurrentFetches` cap. First
        // success cancels the remaining tasks, so first-success latency is bounded
        // by `timeoutInterval` regardless of how many servers are configured.
        // Integrity mismatches return `.skip` so other servers get a chance.
        let integrityTracker = IntegrityTracker()
        let result = await BlossomClient.chunkedFirstSuccess(
            items: targets,
            chunkSize: maxConcurrentFetches
        ) { fetchURL -> BlossomClient.ChunkedOutcome<Data> in
            do {
                let data = try await fetchOncePublic(url: fetchURL, hash: expectedHash)
                return .success(data)
            } catch FetchError.integrityMismatch {
                // Hash mismatch: a different server may have the correct blob.
                integrityTracker.recordIntegrity()
                return .skip
            } catch {
                // Network-level failure: 4xx/5xx, timeout, DNS, etc.
                integrityTracker.recordFailure()
                return .skip
            }
        }

        // Propagate the result to any waiters that parked on this fetch before
        // clearing the in-flight registry entry.
        cooldownLock.lock()
        let awaiters = inFlight.removeValue(forKey: cooldownKey)?.drainAwaiters() ?? []
        cooldownLock.unlock()
        registry.resumeAll(awaiters, with: result)

        if let data = result { return data }

        // All servers returned `.skip`. Record cooldown only if at least one
        // failure was a network-level failure (4xx/5xx/timeout). If every
        // failure was an integrity mismatch, another fetch attempt on the
        // same servers is likely to hit the same corrupt copy — cooldown
        // would just delay a useful retry.
        if !integrityTracker.allWereIntegrity() {
            cooldownLock.lock()
            pruneCooldownCacheLocked(now: Date())
            cooldownCache[cooldownKey] = Date()
            cooldownLock.unlock()
        }

        return nil
    }

    /// Holds awaiters that arrived while a fetch was already in flight. The
    /// first caller drains the awaiters via `drainAwaiters()` after the fetch
    /// completes; each awaiter is then resumed via `resumeAll`.
    private final class InFlightRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var awaiters: [CheckedContinuation<Data?, Never>] = []

        func addAwaiter(_ continuation: CheckedContinuation<Data?, Never>) {
            lock.lock(); awaiters.append(continuation); lock.unlock()
        }
        func drainAwaiters() -> [CheckedContinuation<Data?, Never>] {
            lock.lock(); defer { lock.unlock() }
            let copy = awaiters
            awaiters.removeAll()
            return copy
        }
        func resumeAll(_ awaiters: [CheckedContinuation<Data?, Never>], with value: Data?) {
            for c in awaiters { c.resume(returning: value) }
        }
    }

    /// Drop expired entries first; if still over capacity, drop the oldest by
    /// insertion order (dict preserves insertion order in Swift). Caller must
    /// hold `cooldownLock`.
    private static func pruneCooldownCacheLocked(now: Date) {
        cooldownCache = cooldownCache.filter { now.timeIntervalSince($0.value) < cooldownTTLSeconds }
        if cooldownCache.count >= cooldownMaxEntries {
            let overflow = cooldownCache.count - cooldownMaxEntries + 1
            for key in cooldownCache.keys.prefix(overflow) {
                cooldownCache.removeValue(forKey: key)
            }
        }
    }

    /// Sendable wrapper that tracks whether any fetch task reported an integrity
    /// mismatch (vs a network-level failure). Used to decide whether a
    /// fully-failed fetch should record a cooldown entry.
    private final class IntegrityTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var integrityCount = 0

        func recordIntegrity() {
            lock.lock(); integrityCount += 1; count += 1; lock.unlock()
        }
        func recordFailure() {
            lock.lock(); count += 1; lock.unlock()
        }
        /// True if at least one failure was recorded AND every recorded
        /// failure was an integrity mismatch. Used to gate the cooldown write.
        func allWereIntegrity() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return count > 0 && integrityCount == count
        }
    }

    /// Unauthenticated public GET. Returns data only if 2xx AND SHA-256 matches.
    /// Non-2xx responses (including 401 auth rejection) throw `URLError.badServerResponse` —
    /// we do not retry with auth to avoid deanonymizing the reader to author-controlled servers.
    private static func fetchOncePublic(url: URL, hash: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        // Privacy invariant: fallback GETs must never carry an Authorization header.
        // Strip defensively in release builds as well as asserting in debug.
        req.setValue(nil, forHTTPHeaderField: "Authorization")
        assert(req.allHTTPHeaderFields?["Authorization"] == nil,
               "Privacy invariant: fallback GET must never carry an Authorization header")

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.cannotParseResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let computedHash = BlossomClient.sha256Hex(data)
        guard computedHash == hash else {
            os_log(.error, "BlossomFallbackFetcher: SHA-256 mismatch. Expected %{private}@, got %{private}@", hash, computedHash)
            throw FetchError.integrityMismatch
        }

        return data
    }

    private static func fileExtension(from url: URL) -> String {
        return url.pathExtension.lowercased()
    }
}
