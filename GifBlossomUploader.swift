import Foundation

/// Re-hosts a Giphy CDN GIF on the user's Blossom servers so that posted notes
/// don't depend on Giphy's anonymous-quota CDN. Downloads the bytes, signs a
/// BUD-01 upload auth event with the active key, and PUTs to the user's
/// configured Blossom server list.
///
/// Falls back to the original Giphy URL if anything goes wrong — better to ship
/// a working but rate-limit-prone link than to drop the GIF entirely.
enum GifBlossomUploader {
    enum UploadError: Error {
        case downloadFailed
        case noPrivateKey
    }

    struct Outcome {
        /// URL the composer should append to the post body. Either the Blossom
        /// public URL on success or the original Giphy URL on fallback.
        let url: String
        /// True iff the bytes were successfully re-hosted on Blossom.
        let didRehost: Bool
    }

    /// Best-effort re-host. Caller hands us a Giphy CDN URL plus the active
    /// keypair and the user's Blossom server list (the same one
    /// `ComposeViewModel` uses for image attachments).
    @MainActor
    static func rehost(
        giphyURL: String,
        keypair: Keypair,
        servers: [String]
    ) async -> Outcome {
        guard !servers.isEmpty, let url = URL(string: giphyURL) else {
            return Outcome(url: giphyURL, didRehost: false)
        }

        // Download the original GIF.
        let bytes: Data
        let mime: String
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            bytes = data
            mime = (response as? HTTPURLResponse)?.mimeType
                ?? response.mimeType
                ?? "image/gif"
        } catch {
            return Outcome(url: giphyURL, didRehost: false)
        }

        // Re-upload to Blossom.
        do {
            let result = try await BlossomClient.upload(
                bytes: bytes,
                mime: mime,
                servers: servers,
                keypair: keypair
            )
            return Outcome(url: result.url, didRehost: true)
        } catch {
            return Outcome(url: giphyURL, didRehost: false)
        }
    }
}
