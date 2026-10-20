import AVFoundation

/// Some LL-HLS origins (zap.stream among them) answer partial-segment byte
/// ranges with HTTP 416, which AVPlayer treats as fatal a few seconds into
/// playback. Serving playlists without the LL-HLS tags makes AVPlayer fall back
/// to whole segments: a few seconds more latency, but uninterrupted playback.
///
/// Adapted from tkhumush/nostrTV (MIT License), PR #39.
enum HLSPlaylistRewriter {
    private static let schemePrefix = "wisp-"
    /// `#EXT-X-PART` also matches `#EXT-X-PART-INF`.
    private static let lowLatencyTags = ["#EXT-X-PART", "#EXT-X-PRELOAD-HINT", "#EXT-X-RENDITION-REPORT", "#EXT-X-SERVER-CONTROL", "#EXT-X-SKIP"]

    /// The custom-scheme URL AVPlayer requests so playlists reach `HLSPlaylistLoader`.
    static func loaderURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        components.scheme = schemePrefix + scheme
        return components.url
    }

    static func originURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), scheme.hasPrefix(schemePrefix) else { return nil }
        components.scheme = String(scheme.dropFirst(schemePrefix.count))
        return components.url
    }

    /// Drops LL-HLS tags and makes every URI absolute. Child playlists keep the
    /// loader scheme; segments, init sections and keys point straight at the origin.
    static func rewrite(_ playlist: String, origin: URL) -> String {
        let isMultivariant = playlist.contains("#EXT-X-STREAM-INF")
        func media(_ uri: String) -> String { URL(string: uri, relativeTo: origin)?.absoluteString ?? uri }
        func child(_ uri: String) -> String {
            URL(string: uri, relativeTo: origin).flatMap { loaderURL(for: $0.absoluteURL) }?.absoluteString ?? uri
        }
        return playlist.components(separatedBy: .newlines).compactMap { line -> String? in
            let tag = line.trimmingCharacters(in: .whitespaces)
            if tag.isEmpty { return line }
            if lowLatencyTags.contains(where: tag.hasPrefix) { return nil }
            if !tag.hasPrefix("#") { return isMultivariant ? child(tag) : media(tag) }
            if tag.hasPrefix("#EXT-X-MEDIA:") || tag.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") { return replacingURI(in: tag, with: child) }
            if tag.hasPrefix("#EXT-X-MAP:") || tag.hasPrefix("#EXT-X-KEY:") || tag.hasPrefix("#EXT-X-SESSION-KEY:") { return replacingURI(in: tag, with: media) }
            return line
        }.joined(separator: "\n")
    }

    private static func replacingURI(in tag: String, with transform: (String) -> String) -> String {
        guard let start = tag.range(of: "URI=\""), let end = tag[start.upperBound...].firstIndex(of: "\"") else { return tag }
        return tag.replacingCharacters(in: start.upperBound..<end, with: transform(String(tag[start.upperBound..<end])))
    }
}

/// Fetches playlists requested through the loader scheme and hands AVPlayer the
/// rewritten text. Media segments never pass through here.
final class HLSPlaylistLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = HLSPlaylistLoader()
    let queue = DispatchQueue(label: "wisp.hls.playlist-loader")
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()
    /// Accessed only on `queue`, which is also the resource loader's delegate queue.
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    /// Builds the player item for a live stream URL. HLS playlists are served
    /// through the playlist loader so AVPlayer never enters LL-HLS mode against
    /// origins that mishandle partial segments.
    static func playerItem(for url: URL) -> AVPlayerItem {
        guard url.pathExtension.lowercased() == "m3u8", let loaderURL = HLSPlaylistRewriter.loaderURL(for: url) else {
            return AVPlayerItem(url: url)
        }
        let asset = AVURLAsset(url: loaderURL)
        asset.resourceLoader.setDelegate(HLSPlaylistLoader.shared, queue: HLSPlaylistLoader.shared.queue)
        return AVPlayerItem(asset: asset)
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, let origin = HLSPlaylistRewriter.originURL(for: url) else { return false }
        let id = ObjectIdentifier(loadingRequest)
        let task = session.dataTask(with: origin) { [weak self] data, response, error in
            self?.queue.async {
                guard let self, self.tasks.removeValue(forKey: id) != nil else { return }
                if let error { return loadingRequest.finishLoading(with: error) }
                guard let data, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    return loadingRequest.finishLoading(with: URLError(.badServerResponse))
                }
                let body: Data
                if let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") {
                    body = Data(HLSPlaylistRewriter.rewrite(text, origin: http.url ?? origin).utf8)
                } else {
                    body = data
                }
                loadingRequest.dataRequest?.respond(with: body)
                loadingRequest.finishLoading()
            }
        }
        tasks[id] = task
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }
}
