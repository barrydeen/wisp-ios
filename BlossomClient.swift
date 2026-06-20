import Foundation
import CryptoKit
import os

/// Async semaphore for throttling concurrent operations. Swift concurrency has no
/// built-in semaphore, but we need one for fan-out parallelism (e.g., BUD-03
/// fallback fetches across N servers capped at 3 in-flight). Implemented with
/// `CheckedContinuation` so waiting tasks are parked rather than spinning
/// via `Task.yield()`, which avoids wasting cooperative-thread-pool cycles
/// when multiple media images fail simultaneously during scroll.
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        precondition(value > 0, "AsyncSemaphore value must be positive")
        self.available = value
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            available += 1
        }
    }
}

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
    static let kindAuthGet = 24243

    /// Maximum simultaneous Blossom network operations. Shared by `upload()` (mirrors),
    /// `BlossomFallbackFetcher.fetch` (BUD-03 fallback GETs), and any future surface.
    /// Value of 3 empirically balances throughput against typical Blossom server rate limits.
    /// Changing this number must be done with care — bursts above 3 can trigger 429s on
    /// shared infrastructure.
    static let maxConcurrentOperations = 3

    /// Fan-out helper that caps concurrent task execution at `chunkSize`. Unlike
    /// sequential chunking (which waits for each chunk to fully drain before starting
    /// the next), this helper launches ALL tasks but throttles via a semaphore so
    /// the first success doesn't pay a multiplicative latency penalty proportional
    /// to total item count.
    ///
    /// The first `.success` returned by `work` cancels the remaining tasks and
    /// is propagated to the caller. `.skip` outcomes are ignored — useful for
    /// cases like an integrity mismatch where the caller wants to keep trying
    /// other servers. If all items produce `.skip`, this returns nil.
    static func chunkedFirstSuccess<Item: Sendable, R: Sendable>(
        items: [Item],
        chunkSize: Int = maxConcurrentOperations,
        work: @Sendable @escaping (Item) async -> ChunkedOutcome<R>
    ) async -> R? {
        guard !items.isEmpty else { return nil }
        let semaphore = AsyncSemaphore(value: chunkSize)
        return await withTaskGroup(of: ChunkedOutcome<R>.self) { group in
            for item in items {
                group.addTask {
                    await semaphore.acquire()
                    defer { Task { await semaphore.release() } }
                    return await work(item)
                }
            }
            for await outcome in group {
                if case .success(let result) = outcome {
                    group.cancelAll()
                    return result
                }
                // .skip → keep trying the next item.
            }
            return nil
        }
    }

    /// Outcome of a single task in `chunkedFirstSuccess`. `.success` short-circuits
    /// the fan-out; `.skip` lets the next item try.
    enum ChunkedOutcome<Success>: Sendable {
        case success(Success)
        case skip
    }

    /// Same as `chunkedFirstSuccess` but accumulates all non-nil results instead of
    /// stopping at the first. Used by mirror/fan-out paths where every target gets
    /// the operation regardless of earlier success.
    static func chunkedFanOut<T: Sendable, U>(
        items: [T],
        chunkSize: Int = maxConcurrentOperations,
        work: @Sendable @escaping (T) async -> U
    ) async -> [U] {
        guard !items.isEmpty else { return [] }
        let semaphore = AsyncSemaphore(value: chunkSize)
        return await withTaskGroup(of: U.self) { group in
            for item in items {
                group.addTask {
                    await semaphore.acquire()
                    defer { Task { await semaphore.release() } }
                    return await work(item)
                }
            }
            var results: [U] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    /// Prevents overlapping mirror dispatches for the same blob hash.
    /// Rapid multi-image compose could otherwise spawn an unbounded number
    /// of detached mirror tasks.
    private static let activeMirrorsLock = NSLock()
    private static var activeMirrors: Set<String> = []

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
        return override ?? .shared
    }
    #else
    static var session: URLSession { .shared }
    #endif

    /// Normalizes a Blossom server URL string for use as a base origin. Enforces
    /// HTTPS (auth headers must never travel over cleartext), lowercases the host,
    /// preserves non-default ports, brackets IPv6 hosts, and **preserves the path**
    /// so users with path-prefixed kind-10063 entries (e.g.
    /// `https://blossom.example.com/custom/`) keep working across upgrades.
    ///
    /// Query and fragment are stripped — they're not meaningful for Blossom
    /// endpoints and may contain tracking/session tokens. Trailing slashes on
    /// the path are trimmed so the caller can safely append `/<hash>` etc.
    ///
    /// Returns `nil` for any URL whose scheme is not `https`, or whose host is
    /// empty/unparseable.
    static func normalizeServerURL(_ server: String) -> String? {
        var trimmed = server
        while trimmed.hasSuffix("/") {
            trimmed = String(trimmed.dropLast())
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        let normalizedHost = host.lowercased()
        let hostString = normalizedHost.contains(":") ? "[\(normalizedHost)]" : normalizedHost
        var result = "https://\(hostString)"
        if let port = url.port {
            result += ":\(port)"
        }
        if !url.path.isEmpty {
            // Preserve the path; strip a trailing slash if any (already trimmed above,
            // but defensive in case the URL string had internal slashes before query).
            var path = url.path
            while path.hasSuffix("/") {
                path = String(path.dropLast())
            }
            if !path.isEmpty {
                result += path
            }
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
    /// Note: Works well for most real-world domains (`.media`, `.com`, `.net`, `.io`,
    /// `.dev`). For multi-level TLDs like `.co.uk`, `.com.au`, or `.ac.uk`, this may
    /// incorrectly match subdomains — an acceptable trade-off given the two defenses.
    static func areSameRegistrableDomain(_ hostA: String, _ hostB: String) -> Bool {
        let a = hostA.lowercased().split(separator: ".").map(String.init)
        let b = hostB.lowercased().split(separator: ".").map(String.init)
        if hostA.contains(":") || hostB.contains(":") {
            return hostA.lowercased() == hostB.lowercased()
        }
        // IP addresses (all labels numeric) must match exactly; never treat two
        // different IPs as the "same domain" just because they share the last
        // two octets.
        let aIsIP = a.allSatisfy { Int($0) != nil }
        let bIsIP = b.allSatisfy { Int($0) != nil }
        if aIsIP || bIsIP {
            return a == b
        }
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
            os_log(.debug, "Blossom: server returned unparseable mirror URL, using fallback")
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
    ///
    /// `kind` defaults to `kindAuthGet` for the "get" action (BUD-03) and
    /// `kindAuth` for everything else. Callers can override `kind` for legacy
    /// retry paths (e.g. HEAD on pre-BUD-03 servers that reject kind 24243).
    ///
    /// `encoding` defaults to Base64URL (BUD-11). Legacy retry paths pass
    /// `.standardBase64` to re-encode the same event for pre-BUD-11 servers
    /// that don't recognise Base64URL.
    ///
    /// Async because remote-signer accounts dispatch the auth-event sign over a relay.
    static func makeAuthHeader(
        keypair: Keypair,
        action: String,
        sha256Hex: String,
        kind: Int? = nil,
        encoding: AuthHeaderEncoding = .base64URL,
        expirationOffset: Int = 300
    ) async -> String? {
        let now = NostrClock.now()
        let tags: [[String]] = [
            ["t", action],
            ["x", sha256Hex],
            ["expiration", String(now + expirationOffset)]
        ]
        let resolvedKind = kind ?? (action == "get" ? kindAuthGet : kindAuth)
        guard let signed = try? await Signer.sign(
            keypair: keypair,
            kind: resolvedKind,
            tags: tags,
            content: "Blossom \(action)",
            createdAt: now
        ) else { return nil }
        let json = signed.toJSON()
        guard let data = json.data(using: .utf8) else { return nil }
        switch encoding {
        case .base64URL:
            return "Nostr \(data.base64URLEncodedString())"
        case .standardBase64:
            return "Nostr \(data.base64EncodedString())"
        }
    }

    /// Encoding for the auth header body. BUD-11 requires Base64URL; legacy
    /// pre-BUD-11 servers expect standard Base64 with padding.
    enum AuthHeaderEncoding: Sendable {
        case base64URL
        case standardBase64
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
        // Validate decoded data is a valid Nostr auth event (kind 24242 for uploads
        // or kind 24243 for GET/HEAD per BUD-03) before re-encoding, to prevent
        // passing garbage data to legacy servers.
        // Note: `.fragmentsAllowed` is intentionally omitted — only JSON objects are valid here.
        if let json = try? JSONSerialization.jsonObject(with: decodedData) as? [String: Any],
           let kind = json["kind"] as? Int,
           kind == 24242 || kind == 24243 {
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

        // Generate upload auth headers concurrently — each may require a relay round-trip
        // for remote-signer accounts, so serializing them would triple the latency.
        // GET/HEAD auth is generated inside `headWithLegacyFallback` because the
        // legacy retry path needs to re-sign with kind 24242 and we want to keep
        // signing off the hot parallel loop.
        async let mediaAuthTask  = makeAuthHeader(keypair: keypair, action: "media",  sha256Hex: hash)
        async let uploadAuthTask = makeAuthHeader(keypair: keypair, action: "upload", sha256Hex: hash)
        guard let mediaAuth  = await mediaAuthTask,
              let uploadAuth = await uploadAuthTask else {
            throw BlossomError.authFailed
        }

        // BUD-01 blob-existence check: run a HEAD /<hash> in parallel against all servers.
        // If any already has the blob, return early — no upload or mirror needed.
        let existingURL = await withTaskGroup(of: String?.self) { group in
            for normalized in validServers {
                guard let headUrl = URL(string: normalized + "/" + hash) else { continue }
                group.addTask {
                    // HEAD retries with kind-24242 re-sign on 401 (non-BUD-03 servers).
                    let exists = await headWithLegacyFallback(hash: hash, url: headUrl, keypair: keypair)
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
                        activeMirrorsLock.lock()
                        let shouldMirror = activeMirrors.insert(hash).inserted
                        activeMirrorsLock.unlock()
                        if shouldMirror {
                            Task.detached(priority: .utility) {
                                os_log(.debug, "Blossom: starting mirror for hash %{private}@ to %d server(s)", hash, validServers.count - 1)
                                defer {
                                    activeMirrorsLock.lock()
                                    activeMirrors.remove(hash)
                                    activeMirrorsLock.unlock()
                                }
                                await mirrorBlob(
                                    hash: hash,
                                    publicURL: safePublicURL,
                                    servers: validServers,
                                    currentServer: normalized,
                                    keypair: keypair
                                )
                            }
                        } else {
                            os_log(.debug, "Blossom: mirror for hash %{private}@ already in progress, skipping duplicate dispatch", hash)
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
                    } catch let error as BlossomError {
                        pathError = "\(error)"
                        break     // Blossom error → stop this server.
                    } catch {
                        // Transport-level failures (URLError, timeouts, DNS, etc.) must
                        // not abort the whole upload — record and try the next server.
                        pathError = "\(error)"
                        break
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

        let (data, resp) = try await session.data(for: req)
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

    /// HEAD check for blob existence. First tries with the kind-24243 BUD-03
    /// auth event (Base64URL); on 401 (pre-BUD-03 server), retries with a
    /// kind-24242 event encoded as standard Base64. The two-axis retry
    /// handles both pre-BUD-03 servers (reject kind 24243) and pre-BUD-11
    /// servers (reject Base64URL). Returns true on the first success.
    private static func headWithLegacyFallback(hash: String, url: URL, keypair: Keypair) async -> Bool {
        guard let bud11Auth = await makeAuthHeader(
            keypair: keypair, action: "get", sha256Hex: hash
        ) else { return false }

        // First attempt: BUD-03 (kind 24243, Base64URL). On 404/500 we return
        // false directly — no point retrying with a different kind on the
        // same blob. Only 401 triggers the legacy kind re-sign.
        do {
            return try await headOnce(hash: hash, url: url, auth: bud11Auth)
        } catch BlossomError.authRejected {
            // Legacy fallback: re-sign with kind 24242 + standard Base64 for
            // pre-BUD-03 / pre-BUD-11 servers. The old approach re-encoded the
            // BUD-11 event with standard Base64 (kind 24243) which doesn't help
            // — pre-BUD-03 servers reject the kind, not the encoding.
        } catch {
            return false
        }

        guard let legacyAuth = await makeAuthHeader(
            keypair: keypair,
            action: "get",
            sha256Hex: hash,
            kind: kindAuth,
            encoding: .standardBase64
        ) else { return false }

        return (try? await headOnce(hash: hash, url: url, auth: legacyAuth)) ?? false
    }

    /// Variant of `makeAuthHeader` that lets the caller override the event kind.
    /// Used for legacy retry paths where the original kind is not recognised by
    /// the server (e.g., HEAD on pre-BUD-03 servers expect kind 24242).
    static func makeAuthHeaderWithKind(
        keypair: Keypair,
        action: String,
        sha256Hex: String,
        kind: Int,
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
            kind: kind,
            tags: tags,
            content: "Blossom \(action)",
            createdAt: now
        ) else { return nil }
        let json = signed.toJSON()
        guard let data = json.data(using: .utf8) else { return nil }
        return "Nostr \(data.base64URLEncodedString())"
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

        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return false }
        if http.statusCode == 401 { throw BlossomError.authRejected }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - Mirroring (BUD-04)

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

        // Fan-out mirrors in parallel with a `maxConcurrentOperations` cap. Unlike
        // sequential chunking, every target is launched immediately so first-success
        // latency is independent of total mirror count.
        await chunkedFanOut(items: targets, chunkSize: maxConcurrentOperations) { target in
            await mirrorOnce(server: target.server, url: target.url, auth: auth, hash: hash, bodyData: bodyData)
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

        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 || http.statusCode == 405 { return nil }
        if http.statusCode == 401 { throw BlossomError.authRejected }
        return http.statusCode
    }
}
