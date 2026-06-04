import UIKit
import os
import os.signpost

/// Shared, in-flight-deduped fetch+decode for inline media. Both the
/// foreground views (`RetryingAsyncImage`, `AnimatedImageView`) and the
/// viewport lookahead (`MediaLookaheadPrefetcher`) load through here, so:
///
///   • a row that mounts while its image is mid-prefetch ATTACHES to the
///     in-flight task instead of starting a duplicate download;
///   • exactly one fetch+decode runs per decoded-cache key, no matter how
///     many views / prefetch passes ask for it;
///   • results land in `DecodedImageCache` under the same keys the views
///     read synchronously in `body`, so the next appearance is flash-free.
///
/// Cancellation semantics (deliberate): the owning `Task` stored in the
/// in-flight map is created unstructured (`Task { }`) with a `Never` failure
/// type, so it is NOT part of any view's structured-concurrency tree. A
/// SwiftUI `.task` that gets cancelled when its row scrolls away simply stops
/// awaiting — the shared task runs to completion and populates the cache for
/// whoever mounts next. Awaiting a `Never`-failure task's `.value` cannot
/// rethrow the awaiter's cancellation into the task.
@MainActor
enum InlineMediaLoader {

    /// Which connection pool a NEW fetch runs on. A view attaching to a task
    /// the prefetcher already started awaits it on the prefetch pool — that's
    /// fine (still strictly faster than restarting the download).
    ///   • `.foreground` → `imageClient` (the user is looking at it now).
    ///   • `.prefetch`   → `mediaPrefetchClient` (separate pool so lookahead
    ///     bursts can't starve foreground loads — documented regression —
    ///     but the SAME URLCache, so warmed bytes are foreground hits).
    enum Source {
        case foreground
        case prefetch

        var session: URLSession {
            switch self {
            case .foreground: return HttpClientFactory.imageClient
            case .prefetch: return HttpClientFactory.mediaPrefetchClient
            }
        }
    }

    // In-flight tasks keyed by decoded-cache key. Entries are removed inside
    // the owning task body (on MainActor) before it returns — no race window.
    private static var inFlightStatic: [String: Task<UIImage?, Never>] = [:]
    private static var inFlightAnimated: [String: Task<AnimatedImagePayload?, Never>] = [:]
    private static var inFlightBytes: [String: Task<Void, Never>] = [:]

    /// Decoded-cache key for a static image at `maxPixelSize`. MUST stay in
    /// sync with what `RetryingAsyncImage` renders from: the inline-capped
    /// (`#px1024`) and full-screen-uncapped (bare URL) variants of the same
    /// URL are distinct entries.
    static func staticKey(url: URL, maxPixelSize: CGFloat?) -> String {
        maxPixelSize.map { "\(url.absoluteString)#px\(Int($0))" } ?? url.absoluteString
    }

    /// Fetch + decode a still image, deduped across all callers. Returns the
    /// cached image immediately when `DecodedImageCache` already has it.
    /// `nil` on network / decode failure (callers own retry policy).
    static func staticImage(url: URL, maxPixelSize: CGFloat?, source: Source) async -> UIImage? {
        let key = staticKey(url: url, maxPixelSize: maxPixelSize)
        if let cached = DecodedImageCache.staticImage(for: key) { return cached }
        if let task = inFlightStatic[key] { return await task.value }

        let session = source.session
        let task = Task<UIImage?, Never> {
            let image: UIImage? = await Task.detached(priority: .utility) {
                let signpostId = Signposts.media.makeSignpostID()
                let state = Signposts.media.beginInterval("fetchStaticImage", id: signpostId)
                defer { Signposts.media.endInterval("fetchStaticImage", state) }
                do {
                    let (data, response) = try await session.data(from: url)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        return nil
                    }
                    // Downsample to the cap off-main so the main thread never
                    // decompresses an oversized source at draw time.
                    return AnimatedImageDecoder.decodeStatic(data: data, maxPixelSize: maxPixelSize)
                } catch {
                    return nil
                }
            }.value
            if let image { DecodedImageCache.storeStatic(image, for: key) }
            inFlightStatic[key] = nil
            return image
        }
        inFlightStatic[key] = task
        return await task.value
    }

    /// Fetch + decode an animated payload (GIF / APNG / animated WebP),
    /// deduped. Key is the bare URL string — matches `AnimatedImageView`.
    /// Inline animated media is always decoded at the 1024px frame cap.
    static func animatedPayload(url: URL, source: Source) async -> AnimatedImagePayload? {
        let key = url.absoluteString
        if let cached = DecodedImageCache.animatedPayload(for: key) { return cached }
        if let task = inFlightAnimated[key] { return await task.value }

        let session = source.session
        let task = Task<AnimatedImagePayload?, Never> {
            let payload: AnimatedImagePayload? = await Task.detached(priority: .utility) {
                let signpostId = Signposts.media.makeSignpostID()
                let state = Signposts.media.beginInterval("fetchAnimated", id: signpostId)
                defer { Signposts.media.endInterval("fetchAnimated", state) }
                do {
                    let (data, _) = try await session.data(from: url)
                    // Cap inline animated media so a huge source can't peg the
                    // render server scaling full-res frames. 1024 matches the
                    // video poster cap.
                    return AnimatedImageDecoder.decode(data: data, maxPixelSize: 1024)
                } catch {
                    return nil
                }
            }.value
            if let payload { DecodedImageCache.storeAnimated(payload, for: key) }
            inFlightAnimated[key] = nil
            return payload
        }
        inFlightAnimated[key] = task
        return await task.value
    }

    /// Byte-warm only: pull the response into the shared `URLCache` without
    /// decoding. Used by the lookahead prefetcher for animated media, whose
    /// decoded frame arrays are too memory-heavy to build ahead of need —
    /// the mount-time decode then skips the network entirely.
    static func warmBytes(url: URL) async {
        let key = url.absoluteString
        // Skip when the decoded payload already exists or a real decode is in
        // flight — warming bytes would be pure waste.
        if DecodedImageCache.animatedPayload(for: key) != nil { return }
        if inFlightAnimated[key] != nil { return }
        if let task = inFlightBytes[key] {
            await task.value
            return
        }
        let task = Task<Void, Never> {
            await Task.detached(priority: .utility) {
                let signpostId = Signposts.media.makeSignpostID()
                let state = Signposts.media.beginInterval("prefetchBytes", id: signpostId)
                defer { Signposts.media.endInterval("prefetchBytes", state) }
                _ = try? await HttpClientFactory.mediaPrefetchClient.data(from: url)
            }.value
            inFlightBytes[key] = nil
        }
        inFlightBytes[key] = task
        await task.value
    }
}
