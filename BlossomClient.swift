import Foundation
import CryptoKit
import os

enum BlossomError: Error {
    case authFailed
    /// A 401 Unauthorized response was received. Used by `withLegacyFallback` to
    /// trigger a retry with standard Base64 encoding for pre-BUD-11 servers.
    case authRejected
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

    /// Strips all trailing slashes and rejects non-HTTPS URLs.
    /// Returns `nil` for any URL whose scheme is not `https` — auth headers must
    /// never be sent over cleartext connections.
    static func normalizeServerURL(_ server: String) -> String? {
        var result = server
        while result.hasSuffix("/") {
            result = String(result.dropLast())
        }
        // Enforce HTTPS: a signed Nostr auth event transmitted over HTTP is
        // interceptable and replayable by any on-path observer.
        guard result.lowercased().hasPrefix("https://") else { return nil }
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
    /// Note: Works well for most real-world domains (`.media`, `.com`, `.net`, `.io`,
    /// `.dev`). For multi-level TLDs like `.co.uk`, `.com.au`, or `.ac.uk`, this may
    /// incorrectly match subdomains — an acceptable trade-off given the two defenses.
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
    /// Validates that the decoded data is a valid Nostr event JSON before re-encoding,
    /// to prevent passing garbage data to legacy servers.
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
        // Validate decoded data is a Nostr auth event (kind 24242) before re-encoding.
        // Note: `.fragmentsAllowed` is intentionally omitted — only JSON objects are valid here.
        if let json = try? JSONSerialization.jsonObject(with: decodedData) as? [String: Any],
           let kind = json["kind"] as? Int,
           kind == 24242 {
            return "Nostr \(decodedData.base64EncodedString())"
        }
        return nil
    }

    /// Shared helper: perform a network operation with BUD-11 auth. On 401 (auth rejection),
    /// retry once with legacy standard-Base64 encoding.
    ///
    /// Used by the HEAD check and mirror paths. Note: `upload()` implements its own
    /// compatible retry loop so it can scope the legacy flag per-server and cover both
    /// `/media` and `/upload` paths atomically.
    ///
    /// **Error contract for callers:** the `attempt` closure must throw
    /// `BlossomError.authRejected` when it receives HTTP 401 to engage the legacy retry.
    /// Any other thrown error propagates unchanged.
    ///
    /// If the legacy Base64 conversion fails, the original error is rethrown.
    /// If the legacy retry itself fails, that error propagates to the caller.
    private static func withLegacyFallback<T>(
        bud11Auth: String,
        attempt: (String) async throws -> T
    ) async throws -> T {
        do {
            return try await attempt(bud11Auth)
        } catch let blossomError as BlossomError {
            guard case .authRejected = blossomError else {
                throw blossomError  // Propagate non-401 BlossomError
            }
            // 401: retry once with legacy Standard Base64 encoding.
            if let legacyAuth = convertToLegacyBase64Auth(bud11Auth) {
                return try await attempt(legacyAuth)
            }
            throw blossomError  // Legacy conversion failed; rethrow original error.
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
        let validServers = servers.compactMap { normalizeServerURL($0) }
        guard !validServers.isEmpty else { throw BlossomError.allServersFailed("No HTTPS servers available") }
        let hash = sha256Hex(bytes)

        // Generate all three auth headers concurrently — each may require a relay round-trip
        // for remote-signer accounts, so serializing them would triple the latency.
        async let getAuthTask    = makeAuthHeader(keypair: keypair, action: "get",    sha256Hex: hash)
        async let mediaAuthTask  = makeAuthHeader(keypair: keypair, action: "media",  sha256Hex: hash)
        async let uploadAuthTask = makeAuthHeader(keypair: keypair, action: "upload", sha256Hex: hash)
        guard let getAuth    = await getAuthTask,
              let mediaAuth  = await mediaAuthTask,
              let uploadAuth = await uploadAuthTask else {
            throw BlossomError.authFailed
        }

        // BUD-01 blob-existence check: run a HEAD /<hash> in parallel against all servers.
        // If any already has the blob, return early — no upload or mirror needed.
        let existingURL = await withTaskGroup(of: String?.self) { group in
            for normalized in validServers {
                guard let headUrl = URL(string: normalized + "/" + hash) else { continue }
                group.addTask {
                    // HEAD retries with legacy encoding on 401 (non-BUD-11 servers).
                    let exists = await headWithLegacyFallback(hash: hash, url: headUrl, bud11Auth: getAuth)
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

        // Pre-compute the legacy Base64 pair once at function scope — shared by all servers
        // if BUD-11 auth is rejected. Avoids re-encoding on every subsequent server.
        var legacyAuthPair: (media: String, upload: String)?

        var lastError: String?

        for normalized in validServers {
            // Each server gets a fresh legacyBase64 flag so a pre-BUD-11 server doesn't
            // prevent BUD-11 attempts on the servers that follow it.
            var legacyBase64 = false

            // Two-pass: first try BUD-11 encoding; if a 401 is received, retry this same
            // server immediately with legacy Standard Base64 before moving on.
            for triedLegacy in [false, true] {
                if triedLegacy && !legacyBase64 { break }    // No 401 → skip legacy pass.

                let passMediaAuth: String
                let passUploadAuth: String
                if legacyBase64 {
                    if legacyAuthPair == nil {
                        legacyAuthPair = (
                            convertToLegacyBase64Auth(mediaAuth)  ?? mediaAuth,
                            convertToLegacyBase64Auth(uploadAuth) ?? uploadAuth
                        )
                    }
                    passMediaAuth  = legacyAuthPair!.media
                    passUploadAuth = legacyAuthPair!.upload
                } else {
                    passMediaAuth  = mediaAuth
                    passUploadAuth = uploadAuth
                }

                var pathError: String?
                var didFlipLegacy = false

                for (path, auth) in [("/media", passMediaAuth), ("/upload", passUploadAuth)] {
                    guard let url = URL(string: normalized + path) else { continue }
                    do {
                        let result = try await uploadOnce(bytes: bytes, mime: mime, hash: hash, url: url, auth: auth)

                        let safePublicURL = sanitizeMirrorURL(
                            serverReturnedURL: result.url,
                            uploadHost: URL(string: normalized)?.host ?? "",
                            fallbackURL: normalized + "/" + hash
                        )

                        // Fire-and-forget mirror to remaining servers (BUD-04).
                        // Mirrors are best-effort — the caller is not blocked and the
                        // detached task may be silently dropped if the app suspends.
                        // Each mirror server independently validates the blob hash.
                        Task.detached(priority: .utility) {
                            os_log(.debug, "Blossom: starting mirror for hash %{private}@ to %d server(s)", hash, validServers.count - 1)
                            await mirrorBlob(
                                hash: hash,
                                publicURL: safePublicURL,
                                servers: validServers,
                                currentServer: normalized,
                                keypair: keypair
                            )
                        }

                        return BlossomUploadResult(url: safePublicURL, sha256Hex: hash, mime: mime, size: bytes.count)
                    } catch BlossomError.authRejected where !legacyBase64 {
                        // BUD-11 backward-compat: flip to legacy mode and retry this server.
                        legacyBase64 = true
                        didFlipLegacy = true
                        os_log(.debug, "Blossom: server %{public}@ rejected BUD-11 (401), retrying with standard Base64", normalized)
                        break  // Break the path loop; the outer for-triedLegacy will re-enter.
                    } catch BlossomError.authRejected {
                        pathError = "auth rejected"
                        continue  // Try next path.
                    } catch BlossomError.allServersFailed(let msg) where msg == "404" {
                        pathError = msg
                        continue  // /media not supported → try /upload.
                    } catch {
                        pathError = "\(error)"
                        break     // Unexpected error → stop this server.
                    }
                }

                if !didFlipLegacy {
                    if let e = pathError { lastError = e }
                    break  // Both paths tried (or errored) without a 401 flip.
                }
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
            throw BlossomError.authRejected
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

    /// HEAD check for blob existence. Wraps `headOnce` with a legacy-Base64 fallback
    /// so pre-BUD-11 servers with existing blobs are not incorrectly reported as empty.
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
        // Short timeout — this is a non-fatal optimization and must not block the
        // upload path; all servers are checked in parallel so this is the ceiling
        // for the entire HEAD phase (~5 s total).
        req.timeoutInterval = 5

        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return false }
        if http.statusCode == 401 { throw BlossomError.authRejected }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - Mirroring (BUD-04)

    /// Maximum simultaneous mirror PUTs. Caps network burst without serialising mirrors.
    /// Value of 3 empirically balances throughput against typical Blossom server rate limits.
    private static let mirrorMaxConcurrent = 3

    private static func mirrorBlob(
        hash: String,
        publicURL: String,
        servers: [String],
        currentServer: String,
        keypair: Keypair
    ) async {
        // BUD-04 example flow: "Client sends the url to Server B /mirror using the
        // original upload authorization token" — so the action tag is "upload", not "mirror".
        guard let auth = await makeAuthHeader(keypair: keypair, action: "upload", sha256Hex: hash) else {
            os_log(.fault, "Blossom mirror: failed to generate auth header for hash %{private}@", hash)
            return
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: ["url": publicURL]) else {
            os_log(.fault, "Blossom mirror: failed to serialize mirror body for %{private}@", publicURL)
            return
        }

        let targets: [(server: String, url: URL)] = servers.compactMap { server in
            guard server != currentServer else { return nil }
            guard let url = URL(string: server + "/mirror") else { return nil }
            return (server: server, url: url)
        }

        // Chunked concurrency cap: processes `mirrorMaxConcurrent` PUTs in parallel,
        // waiting for each batch before starting the next.
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

    /// Execute a single mirror PUT with BUD-11 auth. Retries with legacy Base64 on 401.
    private static func mirrorOnce(server: String, url: URL, auth: String, hash: String, bodyData: Data) async {
        do {
            let statusCode = try await withLegacyFallback(bud11Auth: auth) { currentAuth -> Int? in
                return try await mirrorPUT(url: url, auth: currentAuth, hash: hash, bodyData: bodyData)
            }

            guard let statusCode else {
                // nil = 404/405 — /mirror endpoint unsupported on this server.
                os_log(.debug, "Blossom mirror: server %{public}@ does not support /mirror", server)
                return
            }

            if (200..<300).contains(statusCode) {
                os_log(.debug, "Blossom mirror to %{public}@ succeeded (HTTP %{public}@)", server, String(statusCode))
            } else {
                os_log(.fault, "Blossom mirror to %{public}@ failed after legacy retry (HTTP %{public}@)", server, String(statusCode))
            }
        } catch {
            os_log(.fault, "Blossom mirror to %{public}@ threw: %{public}@", server, error.localizedDescription)
        }
    }

    /// Performs a single mirror PUT.
    /// Returns the HTTP status code, or `nil` for 404/405 (endpoint unsupported).
    /// Throws `BlossomError.authRejected` on 401 so `withLegacyFallback` can retry.
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
        if http.statusCode == 404 || http.statusCode == 405 { return nil }
        if http.statusCode == 401 { throw BlossomError.authRejected }
        return http.statusCode
    }
}
