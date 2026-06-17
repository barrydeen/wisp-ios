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
        server.hasSuffix("/") ? String(server.dropLast()) : server
    }

    /// Returns `true` if two hosts share the same registrable (base) domain.
    /// A simple last-two-label heuristic (no public-suffix list); good enough
    /// for the Blossom CDN scenario (e.g., `cdn.azzamo.media` and
    /// `blossom.azzamo.media` both reduce to base `azzamo.media`).
    ///
    /// False positives are possible with `.co.uk`-style multi-level TLDs, but
    /// that is acceptable here because:
    ///   • the mirror target server is chosen by the user from their kind-10063 list;
    ///   • the mirror server independently validates the fetched blob hash against
    ///     the authorized `x` tag (BUD-04 Step 5); hash mismatch → 409 Conflict.
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
    /// (e.g., a CDN subdomain like `cdn.example.media`). Falls back to the
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
    /// `action` should be "upload", "media", "get", "delete", or "mirror".
    /// `expirationOffset` is seconds from now; defaults to 5 minutes.
    /// Async because remote-signer accounts dispatch the auth-event sign over a relay.
    @MainActor
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
        return "Nostr \(decodedData.base64EncodedString())"
    }

    /// Upload `bytes` to one of the given Blossom servers. Tries `/media` (BUD-05) first
    /// and falls back to `/upload` on 404, then moves on to the next server on other errors.
    /// Returns the public URL of the uploaded blob on the first success.
    @MainActor
    static func upload(
        bytes: Data,
        mime: String,
        servers: [String],
        keypair: Keypair
    ) async throws -> BlossomUploadResult {
        guard !servers.isEmpty else { throw BlossomError.allServersFailed(nil) }
        let hash = sha256Hex(bytes)

        // BUD-06 pre-flight HEAD uses a "get" action tag, per BUD-11.
        guard let getAuth = await makeAuthHeader(keypair: keypair, action: "get", sha256Hex: hash),
              let mediaAuth = await makeAuthHeader(keypair: keypair, action: "media", sha256Hex: hash) else {
            throw BlossomError.authFailed
        }
        // uploadAuth generated lazily below — only if the first server rejects /media and also /upload must be attempted.

        var lastError: String?
        var uploadAuth: String?
        var legacyBase64 = false

        for server in servers {
            let normalized = normalizeServerURL(server)

            // Pre-flight HEAD check (BUD-06) — fast timeout, non-fatal.
            // If blob already exists, return canonical URL directly (no mirror needed).
            guard let headUrl = URL(string: normalized + "/" + hash) else { continue }
            let exists = (try? await headOnce(hash: hash, url: headUrl, auth: getAuth)) ?? false
            if exists {
                os_log(.debug, "Blossom HEAD hit: blob exists on %@, skipping upload", server)
                return BlossomUploadResult(url: normalized + "/" + hash, sha256Hex: hash, mime: mime, size: bytes.count)
            }

            // Generate uploadAuth lazily on first use (saves one remote-signer round-trip on happy path).
            if uploadAuth == nil {
                uploadAuth = await makeAuthHeader(keypair: keypair, action: "upload", sha256Hex: hash)
                guard let ua = uploadAuth else { throw BlossomError.authFailed }
                uploadAuth = ua
            }
            guard let resolvedUploadAuth = uploadAuth else { throw BlossomError.authFailed }

            // Retry loop: when legacyBase64 flips true, both /media and /upload are retried
            // on this server with standard Base64 encoding before moving on.
            var needsLegacyRetry = true
            var pathError: String?

            while needsLegacyRetry {
                needsLegacyRetry = false

                let authPairs: [(String, String)] = [("/media", mediaAuth), ("/upload", resolvedUploadAuth)]
                for (path, rawAuth) in authPairs {
                    let auth = legacyBase64
                        ? (convertToLegacyBase64Auth(rawAuth) ?? rawAuth)
                        : rawAuth
                    guard let url = URL(string: normalized + path) else { continue }
                    do {
                        let result = try await uploadOnce(bytes: bytes, mime: mime, hash: hash, url: url, auth: auth)

                        let safePublicURL = sanitizeMirrorURL(
                            serverReturnedURL: result.url,
                            uploadHost: URL(string: normalized)?.host ?? "",
                            fallbackURL: normalized + "/" + hash
                        )

                        // Fire-and-forget mirror to remaining servers (BUD-04).
                        Task.detached(priority: .utility) {
                            await mirrorBlob(hash: hash, publicURL: safePublicURL, servers: servers, currentServer: normalized, keypair: keypair)
                        }
                        // Return canonical content-addressed URL to caller.
                        return BlossomUploadResult(url: safePublicURL, sha256Hex: hash, mime: mime, size: bytes.count)
                    } catch BlossomError.authRejected(statusCode: 401) where !legacyBase64 {
                        // BUD-11 backward-compat: switch to standard Base64 and re-try this server.
                        legacyBase64 = true
                        os_log(.debug, "Blossom server %@ rejected BUD-11 Base64URL (401), falling back to standard Base64", server)
                        needsLegacyRetry = true
                        break  // Restart the path loop on this server with legacy encoding.
                    } catch BlossomError.authRejected(let code) {
                        pathError = "HTTP \(code)"
                        continue  // Other auth errors → try next path.
                    } catch BlossomError.allServersFailed(let msg) where msg == "404" {
                        pathError = msg
                        continue  // /media not supported → try /upload.
                    } catch {
                        pathError = "\(error)"
                        break  // Network/unexpected error → stop this server.
                    }
                }
            }
            if let pathError {
                lastError = pathError
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

    private static func headOnce(hash: String, url: URL, auth: String) async throws -> Bool {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue(hash, forHTTPHeaderField: "X-SHA-256")
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
        guard let auth = await makeAuthHeader(keypair: keypair, action: "mirror", sha256Hex: hash) else {
            os_log(.fault, "Blossom mirror: failed to generate auth header for hash %@", hash)
            return
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: ["url": publicURL]) else {
            os_log(.fault, "Blossom mirror: failed to serialize mirror body for %@", publicURL)
            return
        }

        let targets: [(server: String, url: URL)] = servers.compactMap { server in
            let normalized = normalizeServerURL(server)
            guard normalized != currentServer else { return nil }
            guard let url = URL(string: normalized + "/mirror") else { return nil }
            return (server: server, url: url)
        }

        // Concurrency cap via a simple semaphore-free chunk approach.
        // withTaskGroup naturally runs all tasks concurrently, so we partition into batches.
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

    /// Execute a single mirror PUT. On 401 (BUD-11 auth rejection), retry once with
    /// standard Base64 encoding. Logs the outcome for observability.
    private static func mirrorOnce(server: String, url: URL, auth: String, hash: String, bodyData: Data) async {
        do {
            let firstResult = try await mirrorPUT(url: url, auth: auth, hash: hash, bodyData: bodyData)
            guard let firstResult else {
                // nil = 404/405 — endpoint unsupported on this server, no retry.
                os_log(.debug, "Blossom mirror: server %@ does not support /mirror endpoint", server)
                return
            }
            if firstResult {
                os_log(.debug, "Blossom mirror to %@ succeeded", server)
                return
            }
            // firstResult == false: got 401 (or other non-2xx) → retry with legacy Base64.
            if let legacyAuth = convertToLegacyBase64Auth(auth) {
                let retryResult = try await mirrorPUT(url: url, auth: legacyAuth, hash: hash, bodyData: bodyData)
                if retryResult == true {
                    os_log(.debug, "Blossom mirror to %@ succeeded with legacy Base64", server)
                    return
                }
            }
            os_log(.fault, "Blossom mirror to %@ failed after legacy Base64 retry (status: %@)", server, firstResult ? "unknown" : "non-2xx")
        } catch {
            os_log(.fault, "Blossom mirror to %@ threw: %@", server, error.localizedDescription)
        }
    }

    /// Performs a single mirror PUT. Returns `true` when 2xx, `false` when the
    /// server returned a non-2xx (non-404/405) status, or `nil` when 404/405
    /// (endpoint unsupported — log only, no retry).
    private static func mirrorPUT(url: URL, auth: String, hash: String, bodyData: Data) async throws -> Bool? {
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
            return nil  // Endpoint unsupported — not an error worth retrying.
        }
        return (200..<300).contains(http.statusCode)
    }
}
