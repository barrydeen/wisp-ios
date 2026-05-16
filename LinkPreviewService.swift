import Foundation
import LinkPresentation
import UIKit

struct OpenGraphData: Sendable {
    let title: String?
    let description: String?
    let image: String?
    let siteName: String?
}

actor LinkPreviewService {
    static let shared = LinkPreviewService()

    private var cache: [String: OpenGraphData] = [:]
    private var inflight: [String: Task<OpenGraphData?, Never>] = [:]
    private let cacheLimit = 200

    private static let ogTagRegex = try! NSRegularExpression(
        pattern: #"<meta[^>]+property\s*=\s*["']og:(\w+)["'][^>]+content\s*=\s*["']([^"']*)["'][^>]*/?>|<meta[^>]+content\s*=\s*["']([^"']*)["'][^>]+property\s*=\s*["']og:(\w+)["'][^>]*/?>"#,
        options: [.caseInsensitive]
    )
    private static let titleTagRegex = try! NSRegularExpression(
        pattern: #"<title[^>]*>([^<]+)</title>"#,
        options: [.caseInsensitive]
    )
    private static let youtubeRegex = try! NSRegularExpression(
        pattern: #"(?:https?://)?(?:www\.)?(?:youtube\.com/(?:watch\?.*v=|shorts/|embed/|live/)|youtu\.be/)([a-zA-Z0-9_-]{11})"#,
        options: [.caseInsensitive]
    )

    func cached(_ url: String) -> OpenGraphData? {
        cache[url]
    }

    /// Fire-and-forget cache warming. The composer calls this for the
    /// standalone links in a post being written so that by the time the
    /// note is published and rendered in the feed/thread its preview card
    /// paints from cache instead of showing a spinner. Concurrency and
    /// dedup are already handled by `fetch` (in-flight + cache maps).
    nonisolated func prefetch(_ url: String) {
        Task { _ = await self.fetch(url) }
    }

    func fetch(_ url: String) async -> OpenGraphData? {
        if let cached = cache[url] { return cached }
        if let existing = inflight[url] { return await existing.value }

        let task = Task<OpenGraphData?, Never> {
            await self.fetchInternal(url)
        }
        inflight[url] = task
        let result = await task.value
        inflight[url] = nil
        if let result {
            store(url: url, data: result)
        }
        return result
    }

    private func store(url: String, data: OpenGraphData) {
        if cache.count >= cacheLimit {
            // simple eviction: drop one arbitrary entry
            if let key = cache.keys.first { cache.removeValue(forKey: key) }
        }
        cache[url] = data
    }

    private func fetchInternal(_ urlString: String) async -> OpenGraphData? {
        if let videoId = youtubeVideoId(urlString) {
            if let yt = await fetchYoutubeOembed(urlString, videoId: videoId) {
                return yt
            }
        }

        // YouTube channel URLs with a `?sub_confirmation=1` query trigger an
        // interstitial subscription confirmation page that has no OG meta
        // tags. Drop the query for the OG fetch so the canonical channel
        // page renders; the click-through uses the original URL untouched.
        let fetchUrlString = sanitizeForFetch(urlString)
        guard let url = URL(string: fetchUrlString) else { return nil }
        var request = URLRequest(url: url)
        // Browser-realistic User-Agent — many large sites (notably YouTube)
        // serve a stripped-down or interstitial page to bot-like UAs that
        // omits the OG meta tags we need.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 6

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                guard 200..<300 ~= http.statusCode else {
                    return synthesizeYoutubeChannelPreview(urlString)
                }
                let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                if !contentType.contains("text/html") {
                    return synthesizeYoutubeChannelPreview(urlString)
                }
            }
            // Use first 256KB. YouTube + similar SPA-ish pages bury the OG
            // meta tags well past the 64KB mark we used to allow.
            let limited = data.prefix(256 * 1024)
            guard let html = String(data: Data(limited), encoding: .utf8) ??
                             String(data: Data(limited), encoding: .isoLatin1) else {
                return synthesizeYoutubeChannelPreview(urlString)
            }
            if let parsed = parseOgTags(html: html, fallbackUrl: urlString) {
                return parsed
            }
            // HTML parser came up empty (page served a JS shell, consent
            // wall, or stripped tags). Hand off to Apple's WebKit-backed
            // LinkPresentation, which competing clients use for tricky
            // sites like YouTube channel pages.
            if let lp = await fetchViaLinkPresentation(urlString) { return lp }
            // Last resort: synthesize a minimal card from the URL itself
            // for YouTube channels.
            return synthesizeYoutubeChannelPreview(urlString)
        } catch {
            if let lp = await fetchViaLinkPresentation(urlString) { return lp }
            return synthesizeYoutubeChannelPreview(urlString)
        }
    }

    /// Use Apple's `LPMetadataProvider` (WebKit-backed) to fetch link
    /// metadata. Slower than our regex-on-HTML path but handles consent
    /// walls, JS-rendered OG tags, and other cases that defeat the
    /// generic fetch — notably YouTube channel pages. The provided
    /// image is loaded into the on-device caches directory and the
    /// returned `image` field points at the resulting `file://` URL so
    /// downstream `AsyncImage` can render it without a second fetch.
    private func fetchViaLinkPresentation(_ urlString: String) async -> OpenGraphData? {
        guard let url = URL(string: urlString) else { return nil }
        let provider = LPMetadataProvider()
        provider.timeout = 8

        let metadata: LPLinkMetadata
        do {
            metadata = try await provider.startFetchingMetadata(for: url)
        } catch {
            return nil
        }

        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let siteName = metadata.url?.host?.replacingOccurrences(of: "www.", with: "")

        var imageUrl: String?
        if let imageProvider = metadata.imageProvider ?? metadata.iconProvider {
            imageUrl = await loadProvidedImageToCache(imageProvider, sourceUrl: urlString)
        }

        let hasTitle = (title?.isEmpty == false)
        guard hasTitle || imageUrl != nil else { return nil }
        return OpenGraphData(
            title: title,
            description: nil,
            image: imageUrl,
            siteName: siteName
        )
    }

    /// Pull a UIImage out of the `NSItemProvider`, encode it as JPEG, and
    /// write it to a stable path under the caches directory. The returned
    /// `file://` URL string can be handed to AsyncImage / RetryingAsyncImage
    /// like any other URL. Stable filename per source URL means re-fetches
    /// reuse the same cached file.
    private nonisolated func loadProvidedImageToCache(
        _ provider: NSItemProvider,
        sourceUrl: String
    ) async -> String? {
        let image: UIImage? = await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
        guard let image, let data = image.jpegData(compressionQuality: 0.85) else {
            return nil
        }
        let safeKey = sourceUrl
            .replacingOccurrences(of: "://", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "&", with: "_")
        let filename = "lp-\(safeKey.suffix(120)).jpg"
        guard let cachesDir = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return nil }
        let target = cachesDir.appendingPathComponent(filename)
        do {
            try data.write(to: target, options: .atomic)
            return target.absoluteString
        } catch {
            return nil
        }
    }

    /// When a YouTube channel URL fails the generic OG fetch, build a
    /// minimal preview from the URL itself: handle / channel name as
    /// title, "YouTube" as the site. Returns nil for non-channel URLs.
    private nonisolated func synthesizeYoutubeChannelPreview(_ urlString: String) -> OpenGraphData? {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              host == "youtube.com" || host == "www.youtube.com" || host == "m.youtube.com" else {
            return nil
        }
        let path = url.path
        var title: String?
        if path.contains("/@") {
            // path like "/@SovereignSessions" or "/@SovereignSessions/about"
            let trimmed = path.drop(while: { $0 == "/" })
            let firstSegment = trimmed.split(separator: "/").first.map(String.init) ?? String(trimmed)
            title = firstSegment
        } else if path.hasPrefix("/c/") {
            let trimmed = String(path.dropFirst(3))
            title = "@" + (trimmed.split(separator: "/").first.map(String.init) ?? trimmed)
        } else if path.hasPrefix("/channel/") {
            let trimmed = String(path.dropFirst(9))
            title = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        } else if path.hasPrefix("/user/") {
            let trimmed = String(path.dropFirst(6))
            title = "@" + (trimmed.split(separator: "/").first.map(String.init) ?? trimmed)
        }
        guard let title, !title.isEmpty else { return nil }
        return OpenGraphData(
            title: title,
            description: "YouTube channel",
            image: nil,
            siteName: "YouTube"
        )
    }

    private func youtubeVideoId(_ url: String) -> String? {
        let ns = url as NSString
        let r = NSRange(location: 0, length: ns.length)
        guard let m = Self.youtubeRegex.firstMatch(in: url, range: r), m.numberOfRanges >= 2 else { return nil }
        let idRange = m.range(at: 1)
        guard idRange.location != NSNotFound else { return nil }
        return ns.substring(with: idRange)
    }

    private func fetchYoutubeOembed(_ url: String, videoId: String) async -> OpenGraphData? {
        guard let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let oembedUrl = URL(string: "https://www.youtube.com/oembed?url=\(encoded)&format=json") else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: oembedUrl)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let title = obj["title"] as? String
            let author = obj["author_name"] as? String
            let thumb = obj["thumbnail_url"] as? String
            return OpenGraphData(
                title: title,
                description: author,
                image: "https://img.youtube.com/vi/\(videoId)/hqdefault.jpg".isEmpty ? thumb : "https://img.youtube.com/vi/\(videoId)/hqdefault.jpg",
                siteName: "YouTube"
            )
        } catch {
            return nil
        }
    }

    private func parseOgTags(html: String, fallbackUrl: String) -> OpenGraphData? {
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        var props: [String: String] = [:]
        Self.ogTagRegex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match else { return }
            let propA = match.range(at: 1).location != NSNotFound ? ns.substring(with: match.range(at: 1)) : ""
            let contentA = match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)) : ""
            let contentB = match.range(at: 3).location != NSNotFound ? ns.substring(with: match.range(at: 3)) : ""
            let propB = match.range(at: 4).location != NSNotFound ? ns.substring(with: match.range(at: 4)) : ""
            let prop = (propA.isEmpty ? propB : propA).lowercased()
            let content = contentA.isEmpty ? contentB : contentA
            if !prop.isEmpty, !content.isEmpty, props[prop] == nil {
                props[prop] = content
            }
        }

        var title = props["title"]
        if title == nil {
            if let m = Self.titleTagRegex.firstMatch(in: html, range: range), m.numberOfRanges >= 2 {
                title = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let resolvedImage = props["image"]
            .map(unescapeHtml)
            .flatMap { resolveOgUrl($0, against: fallbackUrl) }
        let result = OpenGraphData(
            title: title.map(unescapeHtml),
            description: props["description"].map(unescapeHtml),
            image: resolvedImage,
            siteName: props["site_name"].map(unescapeHtml)
        )
        if result.title != nil || result.image != nil {
            return result
        }
        return nil
    }

    /// Some hosts serve interstitial / confirmation pages when query params
    /// are present that have no OG meta tags. Strip those for the OG fetch
    /// while leaving `urlString` untouched for the click-through. Currently
    /// targets YouTube's `?sub_confirmation=1` flow on channel URLs.
    private nonisolated func sanitizeForFetch(_ urlString: String) -> String {
        guard var comps = URLComponents(string: urlString) else { return urlString }
        let host = (comps.host ?? "").lowercased()
        let isYoutube = host == "youtube.com" || host == "www.youtube.com" || host == "m.youtube.com"
        if isYoutube,
           let path = comps.path as String?,
           path.contains("/@") || path.hasPrefix("/c/") || path.hasPrefix("/channel/") || path.hasPrefix("/user/") {
            comps.query = nil
            comps.fragment = nil
        }
        return comps.string ?? urlString
    }

    /// Resolve an `og:image` value to an absolute URL string. OG content frequently
    /// arrives as a root-relative ("/og.png"), document-relative ("og.png"), or
    /// protocol-relative ("//cdn.example.com/og.png") path; AsyncImage can only
    /// render absolute http(s) URLs. Returns nil if resolution can't produce one.
    private nonisolated func resolveOgUrl(_ raw: String, against pageUrl: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return trimmed
        }
        if trimmed.hasPrefix("//") {
            // Protocol-relative — adopt the page's scheme (default https).
            let scheme = URL(string: pageUrl)?.scheme ?? "https"
            return "\(scheme):\(trimmed)"
        }
        guard let base = URL(string: pageUrl),
              let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL else {
            return nil
        }
        return resolved.absoluteString
    }

    private nonisolated func unescapeHtml(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&#x27;", with: "'")
    }
}
