import Foundation
import CryptoKit

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

    /// Compute the lowercase hex SHA-256 of the given bytes.
    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Build the `Authorization: Nostr <base64>` header value for a Blossom upload.
    /// `expirationOffset` is seconds from now; defaults to 5 minutes (per Android client).
    /// Async because remote-signer accounts dispatch the auth-event sign over a relay.
    @MainActor
    static func makeUploadAuthHeader(
        keypair: Keypair,
        sha256Hex: String,
        expirationOffset: Int = 300
    ) async -> String? {
        let now = Int(Date().timeIntervalSince1970)
        let tags: [[String]] = [
            ["t", "upload"],
            ["x", sha256Hex],
            ["expiration", String(now + expirationOffset)]
        ]
        guard let signed = try? await Signer.sign(
            keypair: keypair,
            kind: kindAuth,
            tags: tags,
            content: "Upload",
            createdAt: now
        ) else { return nil }
        let json = signed.toJSON()
        guard let data = json.data(using: .utf8) else { return nil }
        let b64 = data.base64EncodedString()
        return "Nostr \(b64)"
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
        guard let auth = await makeUploadAuthHeader(keypair: keypair, sha256Hex: hash) else {
            throw BlossomError.authFailed
        }

        var lastError: String?
        for server in servers {
            let normalized = server.hasSuffix("/") ? String(server.dropLast()) : server
            for path in ["/media", "/upload"] {
                guard let url = URL(string: normalized + path) else { continue }
                do {
                    let result = try await uploadOnce(bytes: bytes, mime: mime, hash: hash, url: url, auth: auth)
                    return result
                } catch BlossomError.allServersFailed(let msg) where msg == "404" {
                    // /media not supported on this server, try /upload next.
                    continue
                } catch {
                    lastError = "\(error)"
                    break // skip /upload retry — different failure
                }
            }
        }
        throw BlossomError.allServersFailed(lastError)
    }

    private static func uploadOnce(bytes: Data, mime: String, hash: String, url: URL, auth: String) async throws -> BlossomUploadResult {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
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
}
