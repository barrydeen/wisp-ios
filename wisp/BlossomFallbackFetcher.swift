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
    nonisolated(unsafe) static var sessionOverride: URLSession?
    static var session: URLSession { sessionOverride ?? .shared }
    #else
    static var session: URLSession { .shared }
    #endif

    /// Maximum concurrent fallback GETs per fetch call.
    /// Uses `BlossomClient.maxConcurrentOperations` for a consistent cap across
    /// all Blossom network surfaces (uploads, mirrors, fallback fetches).
    private static let maxConcurrentFetches = BlossomClient.maxConcurrentOperations

    /// Prevents duplicate fetches from racing for the same (hash, author) pair.
    /// Holds the cooldown cache under a lock so concurrent callers see consistent
    /// state. Concurrency dedup is left to URLSession's URLCache — returning nil
    /// here would cause all concurrent image cells to permanently show failure.
    private static let cooldownLock = NSLock()

    /// Cooldown cache to prevent repeated fallback attempts for the same (hash + author).
    /// Key: "<hash>|<authorPubkey>", Value: timestamp of last *failed* attempt. TTL: 5 minutes.
    /// Capped at 512 entries to prevent unbounded memory growth in long sessions.
    ///
    /// Keyed by (hash, authorPubkey) rather than hash alone so that two authors posting
    /// the same content-addressed image with different server lists get independent attempts.
    /// Recorded ONLY on failure so that a transient network error during the first attempt
    /// does not permanently suppress a retry that might succeed after connectivity recovers.
    private static let cooldownCache: NSCache<NSString, NSDate> = {
        let cache = NSCache<NSString, NSDate>()
        cache.countLimit = 512
        return cache
    }()

    private static let cooldownTTLSeconds: TimeInterval = 300  // 5 minutes

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

        // Atomically check cooldown AND register in-flight under the same lock.
        // Two concurrent callers for the same (hash, author) pair both proceed
        // and run their own network fetch — URLSession's URLCache coalesces
        // identical concurrent requests, so we don't pay a 2× bandwidth cost.
        // Returning nil to the second caller (the original in-flight de-dup)
        // is incorrect because RetryingAsyncImage treats nil as permanent
        // failure: cells that arrive after the first cell started fallback
        // would show failure placeholders forever, even though the first cell
        // might successfully populate the decoded cache.
        let cooldownKey = "\(expectedHash)|\(authorPubkey)" as NSString
        cooldownLock.lock()
        let inCooldown: Bool = {
            guard let lastFailedAt = cooldownCache.object(forKey: cooldownKey) as? Date else { return false }
            return Date().timeIntervalSince(lastFailedAt) < cooldownTTLSeconds
        }()
        if inCooldown {
            cooldownLock.unlock()
            os_log(.debug, "BlossomFallbackFetcher: skipping fallback for %{private}@ (cooldown active)", expectedHash)
            return nil
        }
        cooldownLock.unlock()

        // Use cached list — no relay query. For the current user, these are populated
        // by compose/upload flows. For arbitrary content authors (not yet prefetched),
        // this returns the default primal.net server.
        // TODO: Prefetch kind-10063 for content authors during feed load.
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

        if let data = result { return data }

        // All servers returned `.skip`. Record cooldown only if at least one
        // failure was a network-level failure (4xx/5xx/timeout). If every
        // failure was an integrity mismatch, another fetch attempt on the
        // same servers is likely to hit the same corrupt copy — cooldown
        // would just delay a useful retry.
        if !integrityTracker.allWereIntegrity() {
            cooldownLock.lock()
            cooldownCache.setObject(NSDate(), forKey: cooldownKey)
            cooldownLock.unlock()
        }

        return nil
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
            os_log(.fault, "BlossomFallbackFetcher: SHA-256 mismatch. Expected %{private}@, got %{private}@", hash, computedHash)
            throw FetchError.integrityMismatch
        }

        return data
    }

    private static func fileExtension(from url: URL) -> String {
        return url.pathExtension.lowercased()
    }
}
