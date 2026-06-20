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

    nonisolated(unsafe) static var session: URLSession = .shared

    /// Maximum concurrent fallback GETs per fetch call.
    /// Matches `BlossomClient.mirrorMaxConcurrent` — consistent cap across all Blossom
    /// network operations to prevent connection/bandwidth bursts during feed scroll.
    private static let maxConcurrentFetches = 3

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

        // Cooldown check — keyed by (hash, authorPubkey) so different authors get
        // independent cooldowns for the same content-addressed blob.
        let cooldownKey = "\(expectedHash)|\(authorPubkey)" as NSString
        if let lastFailedAt = cooldownCache.object(forKey: cooldownKey) {
            let elapsed = Date().timeIntervalSince(lastFailedAt as Date)
            if elapsed < cooldownTTLSeconds {
                os_log(.debug, "BlossomFallbackFetcher: skipping fallback for %{private}@ (cooldown: %.0fs remaining)", expectedHash, cooldownTTLSeconds - elapsed)
                return nil
            }
        }

        // Use cached list — no relay query. For the current user, these are populated
        // by compose/upload flows. For arbitrary content authors (not yet prefetched),
        // this returns the default primal.net server.
        // TODO: Prefetch kind-10063 for content authors during feed load.
        let servers = BlossomServerList.cached(for: authorPubkey)
        let ext = fileExtension(from: url)

        // Cap concurrency to avoid bursting connections when many images fail at once.
        let result = await withTaskGroup(of: Data?.self) { group in
            var launched = 0
            for server in servers {
                guard launched < maxConcurrentFetches else { break }
                let normalized = BlossomClient.normalizeServerURL(server) ?? server
                let path = ext.isEmpty ? "/\(expectedHash)" : "/\(expectedHash).\(ext)"
                guard let fetchURL = URL(string: normalized + path) else { continue }

                group.addTask {
                    return try? await fetchOncePublic(url: fetchURL, hash: expectedHash)
                }
                launched += 1
            }

            for await taskResult in group {
                if let data = taskResult {
                    group.cancelAll()
                    return data as Data?
                }
            }
            return nil as Data?
        }

        if result == nil {
            // Record failure in the cooldown cache so we don't hammer author-controlled
            // servers on every scroll event.
            cooldownCache.setObject(NSDate(), forKey: cooldownKey)
        }

        return result
    }

    /// Unauthenticated public GET. Returns data only if 2xx AND SHA-256 matches.
    /// Non-2xx responses (including 401 auth rejection) throw `URLError.badServerResponse` —
    /// we do not retry with auth to avoid deanonymizing the reader to author-controlled servers.
    private static func fetchOncePublic(url: URL, hash: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15

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
            throw URLError(.cannotDecodeContentData)
        }

        return data
    }

    private static func fileExtension(from url: URL) -> String {
        return url.pathExtension.lowercased()
    }
}
