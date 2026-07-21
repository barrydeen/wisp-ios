import Foundation

/// Thin REST client for nostrarchives.com — the same backend that powers the
/// profile sort/feed websocket relays (`feeds.nostrarchives.com`), but reached
/// over its HTTP JSON API for graph data the relays don't expose cleanly.
///
/// Base: `https://api.nostrarchives.com` (120 requests/min per IP). Fetches run
/// on `HttpClientFactory.generalClient` so these one-shot JSON requests use
/// their own 4-per-host pool and never compete with the foreground image
/// loaders on `URLSession.shared`.
enum NostrArchivesClient {
    static let baseURL = "https://api.nostrarchives.com"

    /// A `follows`/`followers` bucket from `/v1/social`: total `count` plus one
    /// page of hex `pubkeys`.
    struct SocialList: Decodable {
        let count: Int
        let pubkeys: [String]
    }

    /// Response of `GET /v1/social/{pubkey}`.
    struct ProfileSocial: Decodable {
        let pubkey: String
        let follows: SocialList
        let followers: SocialList
    }

    /// `GET /v1/social/{pubkey}` — follow/follower counts plus paginated hex
    /// pubkey lists. `pubkey` is hex (the API also accepts npub). Limits clamp
    /// server-side to 1–500; offsets page through the lists.
    static func social(
        pubkey: String,
        followsLimit: Int = 1,
        followsOffset: Int = 0,
        followersLimit: Int = 100,
        followersOffset: Int = 0
    ) async throws -> ProfileSocial {
        guard var comps = URLComponents(string: "\(baseURL)/v1/social/\(pubkey)") else {
            throw URLError(.badURL)
        }
        comps.queryItems = [
            URLQueryItem(name: "follows_limit", value: String(followsLimit)),
            URLQueryItem(name: "follows_offset", value: String(followsOffset)),
            URLQueryItem(name: "followers_limit", value: String(followersLimit)),
            URLQueryItem(name: "followers_offset", value: String(followersOffset)),
        ]
        guard let url = comps.url else { throw URLError(.badURL) }

        let (data, response) = try await HttpClientFactory.generalClient.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ProfileSocial.self, from: data)
    }
}
