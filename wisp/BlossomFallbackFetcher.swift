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

    /// Cooldown cache to prevent repeated fallback attempts for the same hash.
    /// Key: hash, Value: timestamp of last attempt. TTL: 5 minutes.
    /// Capped at 512 entries to prevent unbounded memory growth in long sessions.
    private static let cooldownCache: NSCache<NSString, NSDate> = {
        let cache = NSCache<NSString, NSDate>()
        cache.countLimit = 512
        return cache
    }()

    private static let cooldownTTLSeconds: TimeInterval = 300  // 5 minutes

    /// Attempts to fetch and verify a blob from the author's Blossom servers.
    /// Uses the cached kind-10063 list (set during feed load / prefetch) rather than
    /// triggering a relay query per failure — avoids the N+1 relay pattern when
    /// several images fail in a single feed.
    /// - Parameters:
    ///   - url: The originally failed URL (used to extract the hash and optionally extension).
    ///   - authorPubkey: The pubkey of the event author, to look up their kind-10063 server list.
    /// - Returns: The verified `Data` if successful, or nil if all servers reject/skip.
    static func fetch(url: URL, authorPubkey: String) async -> Data? {
        guard let expectedHash = ContentParser.sha256Hash(fromUrl: url.absoluteString) else {
            return nil
        }

        // Check cooldown cache — skip if this hash was recently attempted.
        let hashKey = expectedHash as NSString
        if let lastAttempt = cooldownCache.object(forKey: hashKey) {
            let elapsed = Date().timeIntervalSince(lastAttempt as Date)
            if elapsed < cooldownTTLSeconds {
                os_log(.debug, "BlossomFallbackFetcher: skipping fallback for %{private}@ (cooldown: %.0fs remaining)", expectedHash, cooldownTTLSeconds - elapsed)
                return nil
            }
        }

        // Mark this attempt in the cooldown cache.
        cooldownCache.setObject(NSDate(), forKey: hashKey)

        // Use cached list — no relay query. For the current user, these are populated
        // by compose/upload flows. For arbitrary content authors (not yet prefetched),
        // this returns the default primal.net server.
        // TODO: Prefetch kind-10063 for content authors during feed load.
        let servers = BlossomServerList.cached(for: authorPubkey)
        let ext = fileExtension(from: url)

        // Short circuit: if no servers available, bail out early. This also means
        // the task group has no tasks, which returns nil immediately — but we log
        // it explicitly for observability.
        guard !servers.isEmpty else {
            os_log(.debug, "BlossomFallbackFetcher: no servers available for author %{private}@", authorPubkey)
            return nil
        }

        return await withTaskGroup(of: Data?.self) { group in
            for server in servers {
                let normalized = BlossomClient.normalizeServerURL(server)
                let path = ext.isEmpty ? "/\(expectedHash)" : "/\(expectedHash).\(ext)"
                guard let fetchURL = URL(string: normalized + path) else { continue }

                group.addTask {
                    return try? await fetchOncePublic(url: fetchURL, hash: expectedHash)
                }
            }

            for await result in group {
                if let data = result {
                    group.cancelAll()
                    return data
                }
            }
            return nil
        }
    }

    /// Unauthenticated public GET. Returns data if 2xx AND SHA-256 matches.
    /// Throws `URLError` on non-2xx (including 401 auth rejection — we intentionally
    /// do not retry with auth to avoid deanonymizing the reader to author-controlled servers).
    /// (Fix #9: clean error propagation with specific URL errors.)
    private static func fetchOncePublic(url: URL, hash: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.cannotParseResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            // 401/403 are auth-required / forbidden — we intentionally don't retry with
            // auth. The caller returns nil from this task, the task group falls through
            // to the next server.
            throw URLError(.badServerResponse)
        }

        let computedHash = BlossomClient.sha256Hex(data)
        guard computedHash == hash else {
            os_log(.fault, "BlossomFallbackFetcher: SHA-256 mismatch. Expected %{private}@, got %{private}@", hash, computedHash)
            throw URLError(.cannotDecodeContentData)
        }

        return data
    }

    private static func fileExtension(from url: URL) -> String {
        return url.pathExtension.lowercased()
    }
}
