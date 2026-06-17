import Foundation
import os

/// Fetches a blob from a Blossom server when the primary URL fails, using the
/// author's kind-10063 server list (BUD-03). Verifies the SHA-256 digest of the
/// downloaded data before returning it.
enum BlossomFallbackFetcher {

    /// Cooldown cache to prevent repeated fallback attempts for the same hash.
    /// Key: hash, Value: timestamp of last attempt. TTL: 5 minutes.
    private static let cooldownCache = NSCache<NSString, NSDate>()

    private static let cooldownTTLSeconds: TimeInterval = 300  // 5 minutes

    /// Attempts to fetch and verify a blob from the author's Blossom servers.
    /// Uses the cached kind-10063 list (set during feed load / prefetch) rather than
    /// triggering a relay query per failure — avoids the N+1 relay pattern when
    /// several images fail in a single feed.
    /// - Parameters:
    ///   - url: The originally failed URL (used to extract the hash and optionally extension).
    ///   - authorPubkey: The pubkey of the event author, to look up their kind-10063 server list.
    /// - Returns: The verified `Data` if successful, or nil if all servers fail or verification fails.
    static func fetch(url: URL, authorPubkey: String) async -> Data? {
        guard let expectedHash = ContentParser.sha256Hash(fromUrl: url.absoluteString) else {
            return nil
        }

        // Check cooldown cache — skip if this hash was recently attempted.
        let hashKey = expectedHash as NSString
        if let lastAttempt = cooldownCache.object(forKey: hashKey) {
            let elapsed = Date().timeIntervalSince(lastAttempt as Date)
            if elapsed < cooldownTTLSeconds {
                os_log(.debug, "BlossomFallbackFetcher: skipping fallback for %{public}@ (cooldown: %.0fs remaining)", expectedHash, cooldownTTLSeconds - elapsed)
                return nil
            }
        }

        // Mark this attempt in the cooldown cache.
        cooldownCache.setObject(NSDate(), forKey: hashKey)

        // Use cached list — no relay query. The refresh is performed by
        // MediaLookaheadPrefetcher / feed prefetch during scroll, not per-image.
        let servers = BlossomServerList.cached(for: authorPubkey)
        let ext = fileExtension(from: url)

        // Pre-compute auth header once for all servers in the task group.
        let keypair = NostrKey.load()
        let bud11Auth: String? = if let kp = keypair {
            await BlossomClient.makeAuthHeader(keypair: kp, action: "get", sha256Hex: expectedHash)
        } else {
            nil
        }
        let legacyAuth: String? = if let b = bud11Auth { BlossomClient.convertToLegacyBase64Auth(b) } else { nil }

        return await withTaskGroup(of: Data?.self) { group in
            for server in servers {
                let normalized = BlossomClient.normalizeServerURL(server)
                let path = ext.isEmpty ? "/\(expectedHash)" : "/\(expectedHash).\(ext)"
                guard let fetchURL = URL(string: normalized + path) else { continue }

                group.addTask {
                    return try? await fetchOnce(
                        url: fetchURL,
                        hash: expectedHash,
                        bud11Auth: bud11Auth,
                        legacyAuth: legacyAuth
                    )
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

    private static func fetchOnce(url: URL, hash: String, bud11Auth: String?, legacyAuth: String?) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15

        // First attempt without auth (public blob).
        var requestData: Data
        var lastResponse: URLResponse

        do {
            (requestData, lastResponse) = try await URLSession.shared.data(for: req)
        } catch {
            throw URLError(.badServerResponse)
        }
        guard let http = lastResponse as? HTTPURLResponse else { throw URLError(.cannotParseResponse) }

        // On 401, retry with BUD-11 Base64URL auth, then legacy Base64 if server rejects BUD-11.
        if http.statusCode == 401, let auth = bud11Auth {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
            do {
                (requestData, lastResponse) = try await URLSession.shared.data(for: req)
            } catch {
                throw URLError(.badServerResponse)
            }
            guard let retryHttp = lastResponse as? HTTPURLResponse else { throw URLError(.cannotParseResponse) }

            if retryHttp.statusCode == 401, let legacy = legacyAuth {
                req.setValue(legacy, forHTTPHeaderField: "Authorization")
                do {
                    (requestData, lastResponse) = try await URLSession.shared.data(for: req)
                } catch {
                    throw URLError(.badServerResponse)
                }
            }
        }

        guard let finalHttp = lastResponse as? HTTPURLResponse, (200..<300).contains(finalHttp.statusCode) else {
            throw URLError(.badServerResponse)
        }

        // Verify SHA-256 (BUD-03) before returning data.
        let computedHash = BlossomClient.sha256Hex(requestData)
        guard computedHash == hash else {
            os_log(.fault, "BlossomFallbackFetcher: SHA-256 mismatch. Expected %@, got %@", hash, computedHash)
            throw URLError(.cannotDecodeContentData)
        }

        return requestData
    }

    private static func fileExtension(from url: URL) -> String {
        return url.pathExtension.lowercased()
    }
}
