import SwiftUI
import UIKit
import ImageIO
import os.signpost

/// Async URL-loaded image that animates GIFs (and APNG / animated WebP).
/// SwiftUI's `AsyncImage` rasterizes through `UIImage(data:)`, which strips
/// every frame after the first — this view bypasses that by reading frames
/// with `CGImageSource` and handing them to a `UIImageView`, which has free
/// frame sequencing on iOS.
///
/// Use in place of `AsyncImage` when the URL is or might be animated. For
/// known-static images, prefer `AsyncImage` to avoid the UIView round-trip.
struct AnimatedImageView<Placeholder: View, Failure: View>: View {
    let url: URL?
    /// Aspect ratio hint from NIP-92 imeta. When present, the view reserves
    /// space at this ratio so layout doesn't jump on load. When absent, the
    /// natural aspect ratio of the decoded image is used after load.
    let aspect: CGFloat?
    /// `.fit` (default) preserves the source aspect inside an inline layout.
    /// `.fill` lets a parent-supplied explicit `.frame(width:, height:)`
    /// crop the frames edge-to-edge — used by the gallery tile so an
    /// animated thumbnail crops like the static `.scaledToFill()` path
    /// instead of letterboxing inside the tile.
    var contentMode: ContentMode = .fit
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let failure: () -> Failure

    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case success(AnimatedImagePayload)
        case failure
    }

    /// Synchronous decoded-cache pre-read. `.task` only fires AFTER the first
    /// body render, so without this a recycled row flashes the placeholder
    /// for one frame even when the payload is already decoded — the same fix
    /// CachedAvatarView / RetryingAsyncImage apply.
    private var cachedPayload: AnimatedImagePayload? {
        guard let url else { return nil }
        return DecodedImageCache.animatedPayload(for: url.absoluteString)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                if let cachedPayload {
                    rendered(cachedPayload)
                } else {
                    placeholder()
                }
            case .failure:
                failure()
            case .success(let payload):
                rendered(payload)
            }
        }
        .task(id: url) {
            await load()
        }
    }

    /// No `.allowsHitTesting(false)` here: with it, the GIF's frame
    /// becomes non-hit-testable in SwiftUI and pinch / drag /
    /// double-tap gestures attached to the surrounding view never
    /// fire over animated content. UIImageView itself ships with
    /// `isUserInteractionEnabled = false` so it doesn't intercept
    /// touches at the UIKit layer either — gestures pass cleanly
    /// up to the SwiftUI parent.
    @ViewBuilder
    private func rendered(_ payload: AnimatedImagePayload) -> some View {
        switch contentMode {
        case .fit:
            AnimatedImageRenderer(payload: payload)
                .aspectRatio(aspect ?? payload.aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
        case .fill:
            // No SwiftUI aspectRatio wrapper — let UIImageView's
            // `.scaleAspectFill` crop into the parent's explicit
            // frame. `.clipped()` on the parent (gallery tile)
            // keeps the bleed inside the corner-radius rect.
            AnimatedImageRenderer(
                payload: payload,
                contentMode: .scaleAspectFill
            )
        }
    }

    private func load() async {
        guard let url else {
            phase = .failure
            return
        }

        // Decoded-payload cache hit: skip the loader entirely. This is what
        // makes scrolled-back GIFs reappear instantly instead of flashing the
        // placeholder while CGImageSource decodes the frame array again.
        let key = url.absoluteString
        if let cached = DecodedImageCache.animatedPayload(for: key) {
            phase = .success(cached)
            return
        }

        phase = .loading

        // Shared in-flight-deduped fetch+decode: attaches to a load the
        // prefetcher (or another mounted view) already started instead of
        // re-fetching. This view's `.task` being cancelled on scroll-away
        // does NOT cancel the shared load — the decoded payload still lands
        // in DecodedImageCache for the next appearance.
        let payload = await InlineMediaLoader.animatedPayload(url: url, source: .foreground)

        if Task.isCancelled { return }
        if let payload {
            phase = .success(payload)
        } else {
            phase = .failure
        }
    }
}

struct AnimatedImagePayload: @unchecked Sendable {
    let frames: [UIImage]
    let totalDuration: TimeInterval
    let aspect: CGFloat
}

/// `nonisolated` so its pure-compute decode runs genuinely off the main actor
/// when called from `Task.detached` — under the project's MainActor-default
/// isolation it would otherwise be MainActor-isolated (see the
/// `project_mainactor_default_isolation` regression: crypto/decode silently
/// pinned to main froze the feed).
nonisolated enum AnimatedImageDecoder {
    /// Frame-count ceiling. A pathological clip (hundreds/thousands of frames)
    /// would otherwise build a giant in-memory payload that the render server
    /// has to cycle. We sample evenly to this many frames and keep the real
    /// total duration, so playback speed is unchanged — just coarser.
    private static let maxFrames = 120

    /// Decodes every frame from `data`, summing the per-frame delays for the
    /// total animation duration. Returns nil if the bytes don't decode to an
    /// image. For single-frame inputs, returns one frame with duration 0.
    ///
    /// `maxPixelSize` downsamples each frame to that longest-edge cap. Pass it
    /// for avatars / inline media so a huge source can't blow up per-frame cost.
    ///
    /// Frames are ALWAYS fully decoded here (off the main thread). Plain
    /// `CGImageSourceCreateImageAtIndex` returns a *lazily* decoded image whose
    /// decompression is deferred to draw time — which runs on the MAIN thread as
    /// `UIImageView` animates. A massive animated avatar (large dimensions ×
    /// many frames, shown on every one of an author's feed rows) then pegged the
    /// main thread for seconds. `kCGImageSourceShouldCacheImmediately` forces the
    /// decode here instead.
    static func decode(data: Data, maxPixelSize: CGFloat? = nil) -> AnimatedImagePayload? {
        let signpostId = Signposts.media.makeSignpostID()
        let signpostState = Signposts.media.beginInterval("decodeAnimated", id: signpostId)
        defer { Signposts.media.endInterval("decodeAnimated", signpostState) }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }

        var opts: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        let useThumbnail = maxPixelSize != nil
        if let maxPixelSize {
            opts[kCGImageSourceCreateThumbnailFromImageAlways] = true
            opts[kCGImageSourceCreateThumbnailWithTransform] = true
            opts[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
        }
        let cfOpts = opts as CFDictionary

        // Sample every `step`-th frame when the source exceeds `maxFrames`.
        let step = count > maxFrames ? Int((Double(count) / Double(maxFrames)).rounded(.up)) : 1

        var frames: [UIImage] = []
        frames.reserveCapacity(min(count, maxFrames))
        var total: TimeInterval = 0
        for i in 0..<count {
            // Read every frame's delay so the summed duration stays accurate even
            // when frames are sampled.
            if count > 1 { total += frameDelay(at: i, source: src) }
            guard i % step == 0 else { continue }
            let cg = useThumbnail
                ? CGImageSourceCreateThumbnailAtIndex(src, i, cfOpts)
                : CGImageSourceCreateImageAtIndex(src, i, cfOpts)
            if let cg { frames.append(UIImage(cgImage: cg)) }
        }
        guard let first = frames.first else { return nil }
        let aspect: CGFloat = first.size.height > 0 ? first.size.width / first.size.height : 1
        return AnimatedImagePayload(frames: frames, totalDuration: total, aspect: aspect)
    }

    /// Decode a single still image, optionally downsampled to `maxPixelSize`
    /// (longest edge). Used by the avatar + inline-image paths so a multi-
    /// thousand-pixel source isn't decompressed at full resolution on the main
    /// thread at draw time (and then GPU-downscaled into a 40 pt circle / 320 pt
    /// row every frame) — and so the cached bitmap's resident footprint is
    /// bounded. The thumbnail path applies EXIF orientation
    /// (`…WithTransform`) and forces the decode here (`…ShouldCacheImmediately`)
    /// off the caller's `Task.detached`. Pass `nil` to keep full source
    /// resolution (full-screen zoom). Falls back to `UIImage(data:)` (which
    /// preserves orientation) if ImageIO can't build a thumbnail.
    static func decodeStatic(data: Data, maxPixelSize: CGFloat? = nil) -> UIImage? {
        guard let maxPixelSize else { return UIImage(data: data) }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg)
    }

    /// Per-frame delay from GIF / APNG / animated-WebP metadata. Browsers
    /// clamp delays under 20ms to 100ms (the historical default for buggy
    /// GIFs); we follow suit.
    private static func frameDelay(at index: Int, source: CGImageSource) -> TimeInterval {
        let fallback: TimeInterval = 0.1
        guard let raw = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return fallback
        }
        let gif = raw[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let png = raw[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let webp = raw[kCGImagePropertyWebPDictionary as CFString] as? [CFString: Any]

        let unclamped = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
            ?? (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? NSNumber)?.doubleValue
            ?? (webp?[kCGImagePropertyWebPUnclampedDelayTime as CFString] as? NSNumber)?.doubleValue
        let clamped = (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
            ?? (png?[kCGImagePropertyAPNGDelayTime] as? NSNumber)?.doubleValue
            ?? (webp?[kCGImagePropertyWebPDelayTime as CFString] as? NSNumber)?.doubleValue

        let delay = unclamped ?? clamped ?? fallback
        return delay < 0.02 ? fallback : delay
    }
}

/// Heuristic: does this URL/MIME suggest an animated payload? Used at call
/// sites to gate which renderer to pick. False negatives are tolerable —
/// non-detected GIFs simply fall back to AsyncImage's first-frame behavior,
/// matching the pre-fix status quo.
///
/// WebP is treated as potentially animated even though many WebPs are static:
/// Giphy and other GIF hosts serve animated content with a `.webp` extension,
/// and the alternative (rendering them through AsyncImage) freezes them on
/// frame 0. The animated decoder handles single-frame WebPs correctly, so the
/// only cost of a false positive is the CGImageSource round-trip.
///
/// `nonisolated`: pure string compute, called from MainActor views and from
/// off-main prefetch paths (AvatarPrefetcher's actor) alike — same rationale
/// as `AnimatedImageDecoder` under the project's MainActor-default isolation.
nonisolated enum AnimatedImageHint {
    static func isLikelyAnimated(url: String, mime: String?) -> Bool {
        if let mime = mime?.lowercased(),
           mime.hasPrefix("image/gif") || mime.hasPrefix("image/webp") || mime.hasPrefix("image/apng") {
            return true
        }
        let lower = url.lowercased()
        let withoutQuery = lower.split(separator: "?").first.map(String.init) ?? lower
        let withoutFragment = withoutQuery.split(separator: "#").first.map(String.init) ?? withoutQuery
        return withoutFragment.hasSuffix(".gif")
            || withoutFragment.hasSuffix(".webp")
            || withoutFragment.hasSuffix(".apng")
    }
}

struct AnimatedImageRenderer: UIViewRepresentable {
    let payload: AnimatedImagePayload
    /// Defaults to `.scaleAspectFit` for inline / full-screen image use. Avatar
    /// callers pass `.scaleAspectFill` so a circular clip frames the image
    /// edge-to-edge.
    var contentMode: UIView.ContentMode = .scaleAspectFit

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = contentMode
        v.clipsToBounds = true
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.image = payload.frames.first
        if payload.frames.count > 1 {
            uiView.animationImages = payload.frames
            uiView.animationDuration = payload.totalDuration
            uiView.animationRepeatCount = 0
            if !uiView.isAnimating { uiView.startAnimating() }
        } else {
            uiView.animationImages = nil
            uiView.stopAnimating()
        }
    }

    static func dismantleUIView(_ uiView: UIImageView, coordinator: ()) {
        uiView.stopAnimating()
        uiView.animationImages = nil
        uiView.image = nil
    }
}
