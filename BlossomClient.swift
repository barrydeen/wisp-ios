import Foundation
import CryptoKit
import os

enum BlossomError: Error {
    case authFailed
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
        
        guard let mediaAuth = await makeAuthHeader(keypair: keypair, action: "media", sha256Hex: hash),
              let uploadAuth = await makeAuthHeader(keypair: keypair, action: "upload", sha256Hex: hash) else {
            throw BlossomError.authFailed
        }
        
        var lastError: String?
        for server in servers {
            let normalized = normalizeServerURL(server)

            // Pre-flight HEAD check (BUD-06) - target the specific resource path once per server
            guard let headUrl = URL(string: normalized + "/" + hash) else { continue }
            let exists = (try? await headOnce(hash: hash, url: headUrl, auth: mediaAuth)) ?? false
            if exists {
                return BlossomUploadResult(url: normalized + "/" + hash, sha256Hex: hash, mime: mime, size: bytes.count)
            }

            var pathError: String?
            for (path, auth) in [("/media", mediaAuth), ("/upload", uploadAuth)] {
                guard let url = URL(string: normalized + path) else { continue }
                do {
                    let result = try await uploadOnce(bytes: bytes, mime: mime, hash: hash, url: url, auth: auth)

                    // Validate returned URL to prevent SSRF in mirror payload, fallback to local construction
                    let safePublicURL: String
                    if let resultURL = URL(string: result.url),
                       let normalizedURL = URL(string: normalized),
                       resultURL.host == normalizedURL.host {
                        safePublicURL = result.url
                    } else {
                        safePublicURL = normalized + "/" + hash
                    }

                    // Mirror to remaining servers in background (Phase 5)
                    Task.detached(priority: .utility) {
                        await mirrorBlob(hash: hash, publicURL: safePublicURL, servers: servers, currentServer: normalized, keypair: keypair)
                    }
                    return result
                } catch BlossomError.allServersFailed(let msg) where msg == "404" {
                    pathError = msg
                    continue
                } catch {
                    pathError = "\(error)"
                    break
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
        req.timeoutInterval = 15

        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// Mirror an already-uploaded blob to other servers in the user's list (BUD-04).
    private static func mirrorBlob(hash: String, publicURL: String, servers: [String], currentServer: String, keypair: Keypair) async {
        // Hoist auth header and body generation outside the loop since they are invariant.
        guard let auth = await makeAuthHeader(keypair: keypair, action: "mirror", sha256Hex: hash) else { return }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: ["url": publicURL]) else { return }
        
        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                let normalizedServer = normalizeServerURL(server)
                guard normalizedServer != currentServer else { continue }
                guard let url = URL(string: normalizedServer + "/mirror") else { continue }
                
                group.addTask {
                    do {
                        var req = URLRequest(url: url)
                        req.httpMethod = "PUT"
                        req.setValue(auth, forHTTPHeaderField: "Authorization")
                        req.setValue(hash, forHTTPHeaderField: "X-SHA-256")
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        req.httpBody = bodyData
                        req.timeoutInterval = 30

                        let (_, resp) = try await URLSession.shared.data(for: req)
                        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                            if http.statusCode == 404 || http.statusCode == 405 {
                                os_log(.debug, "Blossom mirror to %@ not supported (status %@)", server, String(http.statusCode))
                            } else {
                                os_log(.fault, "Blossom mirror to %@ failed with status %@", server, String(http.statusCode))
                            }
                        }
                    } catch {
                        os_log(.fault, "Blossom mirror to %@ failed: %@", server, error.localizedDescription)
                    }
                }
            }
        }
    }
}
