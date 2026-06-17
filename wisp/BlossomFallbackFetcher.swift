import Foundation
import os

/// Fetches a blob from a Blossom server when the primary URL fails, using the
/// author's kind-10063 server list (BUD-03). Verifies the SHA-256 digest of the
/// downloaded data before returning it.
enum BlossomFallbackFetcher {

    /// Attempts to fetch and verify a blob from the author's Blossom servers.
    /// - Parameters:
    ///   - url: The originally failed URL (used to extract the hash and optionally extension).
    ///   - authorPubkey: The pubkey of the event author, to fetch their kind-10063 server list.
    /// - Returns: The verified `Data` if successful, or nil if all servers fail or verification fails.
    static func fetch(url: URL, authorPubkey: String) async -> Data? {
        guard let expectedHash = ContentParser.sha256Hash(fromUrl: url.absoluteString) else {
            return nil
        }

        let servers = await BlossomServerList.refresh(for: authorPubkey)
        let ext = fileExtension(from: url)

        let keypair = NostrKey.load()
        let bud11Auth: String? = if let kp = keypair {
            await BlossomClient.makeAuthHeader(keypair: kp, action: "get", sha256Hex: expectedHash)
        } else {
            nil
        }

        return await withTaskGroup(of: Data?.self) { group in
            for server in servers {
                let normalized = BlossomClient.normalizeServerURL(server)
                let path = ext.isEmpty ? "/\(expectedHash)" : "/\(expectedHash).\(ext)"
                guard let fetchURL = URL(string: normalized + path) else { continue }

                group.addTask {
                    return try? await fetchOnce(url: fetchURL, hash: expectedHash, bud11Auth: bud11Auth)
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

    private static func fetchOnce(url: URL, hash: String, bud11Auth: String?) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15

        var (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.cannotParseResponse) }

        if http.statusCode == 401, let auth = bud11Auth {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
            (data, resp) = try await URLSession.shared.data(for: req)
            guard let retryHttp = resp as? HTTPURLResponse else { throw URLError(.cannotParseResponse) }

            if retryHttp.statusCode == 401, let legacyAuth = BlossomClient.convertToLegacyBase64Auth(auth) {
                req.setValue(legacyAuth, forHTTPHeaderField: "Authorization")
                (data, resp) = try await URLSession.shared.data(for: req)
            }
        }

        guard let finalHttp = resp as? HTTPURLResponse, (200..<300).contains(finalHttp.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let computedHash = BlossomClient.sha256Hex(data)
        guard computedHash == hash else {
            os_log(.fault, "BlossomFallbackFetcher: SHA-256 mismatch. Expected %@, got %@", hash, computedHash)
            throw URLError(.cannotDecodeContentData)
        }

        return data
    }

    private static func fileExtension(from url: URL) -> String {
        return url.pathExtension.lowercased()
    }
}
