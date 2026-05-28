import Foundation

/// Tiered `URLSession` registry. Mirrors the Android `HttpClientFactory`
/// pattern (see commits `e337388`, `c4a8aac` in the Android repo) so a slow
/// `.well-known/nostr.json` request can't tie up the same connection pool
/// used for inline image loads, and so each workload's timeouts match what
/// the user actually expects to wait.
///
/// All clients are lazily created `static let`s — process-singleton, no
/// teardown cost, no synchronisation needed.
enum HttpClientFactory {

    /// Image and avatar loads. Generous resource timeout for slow CDNs but
    /// fail-fast on connection so a stalled host doesn't queue head-of-line.
    /// Has its own 64 MB / 256 MB URLCache so transit-layer hits don't share
    /// a budget with relay-info JSON.
    static let imageClient: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024,
            directory: nil
        )
        return URLSession(configuration: config)
    }()

    /// Generic JSON / payload fetches: relay metadata, exchange rates,
    /// LNURL, NIP-57 zap requests. Default cache policy.
    static let generalClient: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    /// Fail-fast client for fragile endpoints whose long timeouts otherwise
    /// freeze adjacent UI work: `.well-known/nostr.json` (NIP-05),
    /// NIP-11 relay info, OpenGraph preview fetches. 5 s connect / 5 s
    /// resource — a missing endpoint should fail before the user notices.
    static let shortTimeoutClient: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Streaming media (audio prefetch, large file downloads). No URL cache
    /// — segments are huge and bypassing cache prevents double-buffering
    /// against AVPlayer's own caches.
    static let mediaClient: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
}
