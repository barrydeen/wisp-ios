import SwiftUI
import UIKit
import ImageIO
import os.signpost

/// Pixel budgets for downsampled image decodes, sized to the surface each
/// image renders on (× device scale, with oversampling headroom for retina
/// sharpness and moderate zoom). Centralised so the feed and fullscreen
/// targets are documented in one place.
enum ImagePixelBudget {
    /// Gallery tile / inline feed image — capped at one screen width of pixels.
    /// A feed image never renders wider than the screen, and tiles are ~70% of
    /// it, so this is already generous oversampling.
    @MainActor static var feed: CGFloat {
        UIScreen.main.bounds.width * UIScreen.main.scale
    }

    /// Fullscreen viewer — two screen widths so pinch-zoom (up to 4×) stays
    /// reasonably crisp without retaining the full multi-megapixel source.
    @MainActor static var fullscreen: CGFloat {
        UIScreen.main.bounds.width * UIScreen.main.scale * 2
    }
}

/// Decodes `data` straight to a thumbnail whose longest edge is at most
/// `maxPixel` points-in-pixels, using ImageIO so the full-resolution bitmap is
/// never retained — only the downsized result lives in memory. Returns nil if
/// the source can't be read (caller falls back to a full `UIImage(data:)`).
/// Free function so it can run inside a detached, nonisolated decode task.
private func downsampledImage(from data: Data, maxPixel: CGFloat) -> UIImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
        return nil
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel.rounded()),
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    return UIImage(cgImage: cgImage)
}

/// Drop-in replacement for `AsyncImage` that:
///   - reads from `DecodedImageCache` first so a cell scrolled back into view
///     renders the previously-decoded `UIImage` instantly with no loader flash;
///   - retries transient network failures with exponential backoff (vanilla
///     `AsyncImage` gives up forever on the first `.failure`);
///   - falls through to a tap-to-retry placeholder once the retry budget is
///     exhausted.
///
/// Decoding happens off the main thread; the decoded `UIImage` is stored in
/// the shared cache so subsequent appearances of the same URL are O(1).
struct RetryingAsyncImage<Content: View, Loading: View, Failure: View>: View {
    let url: URL?
    let maxAttempts: Int
    /// When set, the source bytes decode down to a thumbnail whose longest
    /// edge is at most this many pixels, rather than at full resolution. Bounds
    /// retained memory so a gallery of large images can't accumulate dozens of
    /// multi-megapixel `UIImage`s. Nil (the default) preserves full-resolution
    /// decoding for callers that need it (avatars, draft thumbnails). The
    /// decoded result is cached per `url`+`maxPixelSize`, so a small tile
    /// decode and a larger fullscreen decode of the same URL coexist instead of
    /// clobbering each other.
    let maxPixelSize: CGFloat?
    /// Hex pubkey of the event author that owns a piece of media. When set and
    /// the primary URL and all retries fail, `BlossomFallbackFetcher` is called
    /// with this pubkey to attempt recovery from the author's kind-10063 servers.
    let authorPubkey: String?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let loading: () -> Loading
    @ViewBuilder let failure: () -> Failure

    @State private var phase: Phase = .empty
    @State private var attempt: Int = 0

    private enum Phase {
        case empty
        case loading
        case success(UIImage)
        case failure
    }

    init(
        url: URL?,
        maxAttempts: Int = 3,
        maxPixelSize: CGFloat? = nil,
        authorPubkey: String? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder loading: @escaping () -> Loading,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.url = url
        self.maxAttempts = maxAttempts
        self.maxPixelSize = maxPixelSize
        self.authorPubkey = authorPubkey
        self.content = content
        self.loading = loading
        self.failure = failure
    }

    /// Synchronous decoded-cache pre-read (DecodedImageCache is @MainActor).
    /// `.task` only fires AFTER the first body render, so without this a
    /// recycled row flashes the loader for one frame even on a cache hit —
    /// the same fix CachedAvatarView already applies.
    private var cachedImage: UIImage? {
        guard let url else { return nil }
        let key = InlineMediaLoader.staticKey(url: url, maxPixelSize: maxPixelSize)
        return DecodedImageCache.staticImage(for: key)
    }

    var body: some View {
        Group {
            switch phase {
            case .empty, .loading:
                if let cachedImage {
                    content(Image(uiImage: cachedImage))
                } else {
                    loading()
                }
            case .success(let image):
                content(Image(uiImage: image))
            case .failure:
                failure()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        attempt = 0
                        phase = .empty
                    }
            }
        }
        .task(id: TaskKey(url: url, attempt: attempt, maxPixelSize: maxPixelSize)) {
            await load()
        }
    }

    /// Combined state key so a URL change OR a retry both kick off a fresh
    /// load via `.task(id:)`. Reusing one identifier per view keeps the
    /// cancellation semantics clean.
    private struct TaskKey: Hashable {
        let url: URL?
        let attempt: Int
        /// Part of the identity so a caller that raises `maxPixelSize` (e.g.
        /// the fullscreen viewer upgrading to full resolution on deep zoom)
        /// kicks off a fresh, higher-resolution decode.
        let maxPixelSize: CGFloat?
    }

    private func load() async {
        guard let url else {
            phase = .failure
            return
        }
        // Key the decoded cache by URL *and* target size: the same image
        // decoded small for a gallery tile and larger for the fullscreen
        // viewer are distinct entries, so neither serves the other a
        // wrong-resolution bitmap.
        let key = InlineMediaLoader.staticKey(url: url, maxPixelSize: maxPixelSize)

        // Cache hit — render immediately with no loading state.
        if let cached = DecodedImageCache.staticImage(for: key) {
            phase = .success(cached)
            return
        }

        if attempt > 0 {
            // Exponential backoff capped at 4s — 0.5s, 1s, 2s.
            let delay = min(4.0, 0.5 * pow(2.0, Double(attempt - 1)))
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
        }

        // Keep any already-decoded image on screen while a re-decode runs
        // (e.g. a deep-zoom upgrade to full resolution) so the viewer doesn't
        // flash a loader over the image the user is actively zooming.
        if case .success = phase {} else { phase = .loading }
        // Shared in-flight-deduped fetch+decode: if the lookahead prefetcher
        // (or another mounted view) already started this URL, attach to that
        // task instead of fetching again. This view's `.task` being cancelled
        // on scroll-away does NOT cancel the shared load — the result still
        // lands in DecodedImageCache for the next appearance.
        let image = await InlineMediaLoader.staticImage(
            url: url,
            maxPixelSize: maxPixelSize,
            source: .foreground
        )

        if Task.isCancelled { return }
        if let image {
            phase = .success(image)
        } else if attempt < maxAttempts {
            attempt += 1  // Triggers another `task` cycle via TaskKey change.
        } else {
            if let authorPubkey, let fallbackData = await BlossomFallbackFetcher.fetch(url: url, authorPubkey: authorPubkey) {
                if let image = AnimatedImageDecoder.decodeStatic(data: fallbackData, maxPixelSize: maxPixelSize) {
                    DecodedImageCache.storeStatic(image, for: key)
                    phase = .success(image)
                    return
                }
            }
            phase = .failure
        }
    }
}
