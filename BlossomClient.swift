import Foundation
import CryptoKit
import os

enum BlossomError: Error {
    case authFailed
    case authRejected(statusCode: Int)
    case allServersFailed(String?)
    case invalidResponse
}

struct BlossomUploadResult {
    let url: String
    let sha256Hex: String
    let mime: String
    let size: Int
}

enum BlossomClient {
    static let kindAuth = 24242

    static func normalizeServerURL(_ server: String) -> String {
        var result = server
        while result.hasSuffix("/") {
            result = String(result.dropLast())
        }
        return result
    }

    /// Returns `true` if two hosts share the same registrable (base) domain.
    /// A simple last-two-label heuristic (no public-suffix list); good enough
    /// for the Blossom CDN scenario (e.g. `cdn.azzamo.media` and
    /// `blossom.azzamo.media` both reduce to base `azzamo.media`).
    ///
    /// False positives are possible with `.co.uk`-style multi-level TLDs, but
    /// that is acceptable here because:
    ///   • the mirror target server is chosen by the user from their kind-10063 list;
    ///   • the mirror server independently validates the fetched blob hash against
    ///     the authorized `x` tag (BUD-04 Step 5); hash mismatch → 409 Conflict.
    ///
    /// Note: This heuristic works well for most real-world domains (e.g., `.media`,
    /// `.com`, `.net`, `.io`, `.dev`). For multi-level TLDs like `.co.uk`, `.com.au`,
    /// or `.ac.uk`, this may incorrectly match subdomains. However, given the two
    /// layers of defense above, this is an acceptable trade-off for simplicity.
    static func areSameRegistrableDomain(_ hostA: String, _ hostB: String) -> Bool {
        let a = hostA.lowercased().split(separator: ".").map(String.init)
        let b = hostB.lowercased().split(separator: ".").map(String.init)
        guard a.count >= 2, b.count >= 2 else { return false }
        return a.suffix(2) == b.suffix(2)
    }

    /// Pick the URL that should be sent as the mirror payload (BUD-04).
    ///
    /// Trusts the upload server's own response URL when the host matches the
    /// upload host exactly or is a sibling on the same registrable domain
    /// (e.g. a CDN subdomain like `cdn.example.media`). Falls back to the
    /// canonical origin URL for unrelated hosts.
    ///
    /// `mirrorBlob` itself is kept independently hardened — mirror targets are
    /// limited to the user's configured kind-10063 server list.
    static func sanitizeMirrorURL(
        serverReturnedURL: String,
        uploadHost: String,
        fallbackURL: String
    ) -> String {
        guard let resultURL = URL(string: serverReturnedURL),
              let resultHost = resultURL.host,
              !resultHost.isEmpty else {
            return fallbackURL
        }
        let uploadHostLower = uploadHost.lowercased()
        let resultHostLower = resultHost.lowercased()

        if resultHostLower == uploadHostLower { return serverReturnedURL }
        if areSameRegistrableDomain(resultHostLower, uploadHostLower) {
            return serverReturnedURL
        }
        return fallbackURL
    }

    /// Compute the lowercase hex SHA-256 of the given bytes.
    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Build the `Authorization: Nostr <base64url>` header value for a Blossom request.
    /// `action` should be one of "upload", "media", or "get" per BUD-11.
    /// `expirationOffset` is seconds from now; defaults to 5 minutes.
    /// Async because remote-signer accounts dispatch the auth-event sign over a relay.
    static func makeAuthHeader(
        keypair: Keypair,
        action: String,
        sha256Hex: String,
        expirationOffset: Int = 300
    ) async -> String? {
        let now = NostrClock.now()
        let tags: [[String]] = [
            ["t", action],
            ["x", sha256Hex],
            ["expiration", String(now + expirationOffset)]
        ]
        guard let signed = try? await Signer.sign(
            keypair: keypair,
            kind: kindAuth,
            tags: tags,
            content: "Blossom \(action)",
            createdAt: now
        ) else { return nil }
        let json = signed.toJSON()
        guard let data = json.data(using: .utf8) else { return nil }
        // BUD-11: Base64URL encoding without padding
        return "Nostr \(data.base64URLEncodedString())"
    }

    /// Convert a BUD-11 (Base64URL) auth header back to standard Base64 encoding.
    /// Used as a fallback for older Blossom servers that haven't implemented BUD-11.
    /// No re-signing required — re-encodes the same signed event JSON.
    ///
    /// This validates that the decoded data is a valid Nostr event JSON before
    /// re-encoding, to prevent passing garbage data to non-compliant servers.
    static func convertToLegacyBase64Auth(_ header: String) -> String? {
        guard header.hasPrefix("Nostr ") else { return nil }
        let b64url = String(header.dropFirst(6))
        var standardBase64 = b64url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standardBase64.count % 4
        if remainder > 0 {
            standardBase64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let decodedData = Data(base64Encoded: standardBase64) else { return nil }
        // Validate that decoded data is valid JSON and has the expected kind field
        // to prevent passing garbage data to legacy servers.
        if let json = try? JSONSerialization.jsonObject(with: decodedData, options: [.fragmentsAllowed]) as? [String: Any],
           let kind = json["kind"] as? Int,
           kind == 24242 {
            return "Nostr \(decodedData.base64EncodedString())"
        }
        return nil
    }

    /// Shared helper: perform a network operation with BUD-11 auth. On 401 (auth rejection),
    /// retry once with legacy standard-Base64 encoding. Eliminates duplication between
    /// `upload()`, `mirrorOnce()`, and `headOnce()`. (Fix #12: single source of truth)
    ///
    /// If the legacy conversion fails, the original 401 error is thrown.
    /// If the legacy retry itself fails, that error propagates instead. (Fix #9)
    private static func withLegacyFallback<T>(
        bud11Auth: String,
        attempt: (String) async throws -> T
    ) async throws -> T {
        do {
            return try await attempt(bud11Auth)
        } catch let blossomError as BlossomError {
            guard case .authRejected(statusCode: 401) = blossomError else {
                throw blossomError  // Propagate non-401 BlossomError
            }
            // 401: try legacy Base64 fallback
            if let legacyAuth = convertToLegacyBase64Auth(bud11Auth) {
                return try await attempt(legacyAuth)
            }
            throw blossomError  // Legacy conversion failed, throw original error
        }
    }

    /// Upload `bytes` to one of the given Blossom servers. Tries `/media` (BUD-05) first
    /// and falls back to `/upload` on 404, then moves on to the next server on other errors.
    /// Returns the public URL of the uploaded blob on the first success.
    static func upload(
        bytes: Data,
        mime: String,
        servers: [String],
        keypair: Keypair
    ) async throws -> BlossomUploadResult {
        guard !servers.isEmpty else { throw BlossomError.allServersFailed(nil) }
        let hash = sha256Hex(bytes)

        // BUD-01 blob-existence HEAD check (NOT BUD-06). Runs all servers in parallel
        // with a short deadline. Returns the canonical URL on first hit.
        // (Fix #2: clarify this is BUD-01, not BUD-06. Fix #4: parallelized.)
        guard let getAuth = await makeAuthHeader(keypair: keypair, action: "get", sha256Hex: hash) else {
            throw BlossomError.authFailed
        }

        let existingURL = await withTaskGroup(of: String?.self) { group in
            for server in servers {
                let normalized = normalizeServerURL(server)
                guard let headUrl = URL(string: normalized + "/" + hash) else { continue }
                group.addTask {
                    // Fix #8: headOnce retries with legacy auth on 401.
                    let exists = await headWithLegacyFallback(
                        hash: hash,
                        url: headUrl,
                        bud11Auth: getAuth
                    )
                    return exists ? (normalized + "/" + hash) : nil
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result as String?
                }
            }
            return nil as String?
        }

        if let existing = existingURL {
            os_log(.debug, "Blossom HEAD hit: blob already exists, skipping upload")
            return BlossomUploadResult(url: existing, sha256Hex: hash, mime: mime, size: bytes.count)
        }

        // Pre-generate media and upload auth headers.
        guard let mediaAuth = await makeAuthHeader(keypair: keypair, action: "media", sha256Hex: hash),
              let uploadAuth = await makeAuthHeader(keypair: keypair, action: "upload", sha256Hex: hash) else {
            throw BlossomError.authFailed
        }

        var lastError: String?
        var legacyBase64 = false

        for server in servers {
            let normalized = normalizeServerURL(server)

            // Per-server legacy-auth cache. Computed ONCE when legacy mode flips (Fix #10).
            var legacyCache: (media: String, upload: String)? = nil

            // Labeled loop: when a 401 flips legacyBase64, `continue serverAttempt` retries
            // this SAME server with legacy auth instead of skipping to the next server.
            serverAttempt: while true {
                let passMediaAuth: String
                let passUploadAuth: String
                if legacyBase64 {
                    if legacyCache == nil {
                        legacyCache = (
                            convertToLegacyBase64Auth(mediaAuth) ?? mediaAuth,
                            convertToLegacyBase64Auth(uploadAuth) ?? uploadAuth
                        )
                    }
                    passMediaAuth = legacyCache!.media
                    passUploadAuth = legacyCache!.upload
                } else {
                    passMediaAuth = mediaAuth
                    passUploadAuth = uploadAuth
                }

                let pathAuthPairs: [(String, String)] = [
                    ("/media", passMediaAuth),
                    ("/upload", passUploadAuth)
                ]

                var pathError: String?

                for (path, auth) in pathAuthPairs {
                    guard let url = URL(string: normalized + path) else { continue }
                    do {
                        let result = try await uploadOnce(bytes: bytes, mime: mime, hash: hash, url: url, auth: auth)

                        let safePublicURL = sanitizeMirrorURL(
                            serverReturnedURL: result.url,
                            uploadHost: URL(string: normalized)?.host ?? "",
                            fallbackURL: normalized + "/" + hash
                        )

                        // Fire-and-forget mirror to remaining servers (BUD-04).
                        // This is non-blocking for the caller. Mirror tasks are untracked and
                        // will be cancelled if the app is suspended. This is acceptable because:
                        // - Mirrors are best-effort redundancy, not critical for the upload
                        // - Mirror servers are from the user's kind-10063 list (trusted)
                        // - Each mirror server validates the blob hash (defense in depth)
                        // - The mirror itself uses withLegacyFallback for resilience
                        //
                        // Limitation: No lifecycle tracking. If mirrors fail, there's no retry
                        // or failure reporting. A proper implementation would use BGTaskScheduler
                        // for background completion, but that requires Info.plist configuration
                        // and background mode entitlement. For now, this fire-and-forget pattern
                        // is sufficient for BUD-04 compliance.
                        Task.detached(priority: .utility) {
                            os_log(.debug, "Starting mirror task for hash %{private}@ to %d servers", hash, servers.count - 1)
                            await mirrorBlob(
                                hash: hash,
                                publicURL: safePublicURL,
                                servers: servers,
                                currentServer: normalized,
                                keypair: keypair
                            )
                        }

                        return BlossomUploadResult(url: safePublicURL, sha256Hex: hash, mime: mime, size: bytes.count)
                    } catch BlossomError.authRejected(statusCode: 401) where !legacyBase64 {
                        // BUD-11 backward-compat: flip to legacy mode and retry THIS server.
                        legacyBase64 = true
                        os_log(.debug, "Blossom server %@ rejected BUD-11 Base64URL (401), falling back to standard Base64", server)
                        continue serverAttempt  // Restart server loop iteration with legacy auth.
                    } catch BlossomError.authRejected(let code) {
                        pathError = "HTTP \(code)"
                        continue  // Try next path.
                    } catch BlossomError.allServersFailed(let msg) where msg == "404" {
                        pathError = msg
                        continue  // /media not supported → try /upload.
                    } catch {
                        pathError = "\(error)"
                        break  // Network error → stop this server.
                    }
                }

                // Reached here without success or server-401 retry — move to next server.
                if let pathError {
                    lastError = pathError
                }
                break serverAttempt
            }
        }
        throw BlossomError.allServersFailed(lastError)
    }

    private static func uploadOnce(bytes: Data, mime: String, hash: String, url: URL, auth: String) async throws -> BlossomUploadResult {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue(hash, forHTTPHeaderField: "X-SHA-256")
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        req.setValue(String(bytes.count), forHTTPHeaderField: "Content-Length")
        req.httpBody = bytes
        req.timeoutInterval = 120

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BlossomError.invalidResponse }
        if http.statusCode == 401 {
            throw BlossomError.authRejected(statusCode: 401)
        }
        if http.statusCode == 404 {
            throw BlossomError.allServersFailed("404")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BlossomError.allServersFailed("HTTP \(http.statusCode): \(body)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let publicURL = obj["url"] as? String else {
            throw BlossomError.invalidResponse
        }
        return BlossomUploadResult(url: publicURL, sha256Hex: hash, mime: mime, size: bytes.count)
    }

    /// HEAD check for blob existence (BUD-01). Wraps headOnce with legacy-fallback
    /// so non-BUD-11 servers aren't mis-reported as "no blob". (Fix #8)
    private static func headWithLegacyFallback(hash: String, url: URL, bud11Auth: String) async -> Bool {
        return (try? await withLegacyFallback(bud11Auth: bud11Auth) { auth in
            try await headOnce(hash: hash, url: url, auth: auth)
        }) ?? false
    }

    private static func headOnce(hash: String, url: URL, auth: String) async throws -> Bool {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue(hash, forHTTPHeaderField: "X-SHA-256")
        // Short timeout — blob-existence HEAD is a non-fatal optimization, must
        // not block the upload path for more than ~5s total across all servers.
        req.timeoutInterval = 5

        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// Mirror an already-uploaded blob to other servers in the user's list (BUD-04).
    /// Concurrency is capped at `mirrorMaxConcurrent` simultaneous PUTs to avoid
    /// saturating the network or getting rate-limited by cooperative servers.
    /// Each server gets a legacy-base64 retry on 401 before logging failure.
    private static let mirrorMaxConcurrent = 3

    private static func mirrorBlob(hash: String, publicURL: String, servers: [String], currentServer: String, keypair: Keypair) async {
        // Fix #1: BUD-11 requires `t=upload` for /mirror, not a separate "mirror" verb.
        // BUD-04 example flow: "Client sends the url to Server B /mirror using the
        // original upload authorization token".
        guard let auth = await makeAuthHeader(keypair: keypair, action: "upload", sha256Hex: hash) else {
            os_log(.fault, "Blossom mirror: failed to generate auth header for hash %{private}@", hash)
            return
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: ["url": publicURL]) else {
            os_log(.fault, "Blossom mirror: failed to serialize mirror body for %{private}@", publicURL)
            return
        }

        let targets: [(server: String, url: URL)] = servers.compactMap { server in
            let normalized = normalizeServerURL(server)
            guard normalized != currentServer else { return nil }
            guard let url = URL(string: normalized + "/mirror") else { return nil }
            return (server: server, url: url)
        }

        // Concurrency cap via a simple semaphore-free chunk approach.
        for chunk in stride(from: 0, to: targets.count, by: mirrorMaxConcurrent) {
            let slice = Array(targets[chunk..<min(chunk + mirrorMaxConcurrent, targets.count)])
            await withTaskGroup(of: Void.self) { group in
                for (server, url) in slice {
                    group.addTask {
                        await mirrorOnce(server: server, url: url, auth: auth, hash: hash, bodyData: bodyData)
                    }
                }
            }
        }
    }

    /// Execute a single mirror PUT. Uses `withLegacyFallback` to retry on 401.
    /// Logs the outcome for observability. (Fix #5: retry strictly on 401 only.)
    private static func mirrorOnce(server: String, url: URL, auth: String, hash: String, bodyData: Data) async {
        do {
            let statusCode = try await withLegacyFallback(bud11Auth: auth) { currentAuth -> Int? in
                return try await mirrorPUT(url: url, auth: currentAuth, hash: hash, bodyData: bodyData)
            }

            guard let statusCode else {
                // nil = 404/405 — endpoint unsupported, log only.
                os_log(.debug, "Blossom mirror: server %{public}@ does not support /mirror endpoint", server)
                return
            }

            if (200..<300).contains(statusCode) {
                os_log(.debug, "Blossom mirror to %{public}@ succeeded with HTTP %{public}@", server, String(statusCode))
            } else {
                os_log(.fault, "Blossom mirror to %{public}@ failed after legacy retry with HTTP %{public}@", server, String(statusCode))
            }
        } catch {
            os_log(.fault, "Blossom mirror to %{public}@ threw: %{public}@", server, error.localizedDescription)
        }
    }

    /// Performs a single mirror PUT. Returns the HTTP status code, or `nil` for 404/405
    /// (endpoint unsupported). Throws `BlossomError.authRejected` on 401 so the caller's
    /// `withLegacyFallback` wrapper can retry with legacy encoding. (Fix #5)
    private static func mirrorPUT(url: URL, auth: String, hash: String, bodyData: Data) async throws -> Int? {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue(hash, forHTTPHeaderField: "X-SHA-256")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 30

        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 || http.statusCode == 405 {
            return nil
        }
        if http.statusCode == 401 {
            throw BlossomError.authRejected(statusCode: 401)
        }
        return http.statusCode
    }
}
