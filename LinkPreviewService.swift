import Foundation

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

        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (compatible; Wisp/1.0)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 6

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                guard 200..<300 ~= http.statusCode else { return nil }
                let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                if !contentType.contains("text/html") { return nil }
            }
            // Use first 64KB
            let limited = data.prefix(64 * 1024)
            guard let html = String(data: Data(limited), encoding: .utf8) ??
                             String(data: Data(limited), encoding: .isoLatin1) else { return nil }
            return parseOgTags(html: html, fallbackUrl: urlString)
        } catch {
            return nil
        }
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
        let result = OpenGraphData(
            title: title.map(unescapeHtml),
            description: props["description"].map(unescapeHtml),
            image: props["image"].map(unescapeHtml),
            siteName: props["site_name"].map(unescapeHtml)
        )
        if result.title != nil || result.image != nil {
            return result
        }
        return nil
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
