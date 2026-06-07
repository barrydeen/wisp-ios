import UIKit

/// Process-wide in-memory cache of *decoded* image payloads, keyed by URL.
///
/// Why this exists: SwiftUI's `AsyncImage` and the project's `AnimatedImageView`
/// both rely on `URLSession.shared` + `URLCache` for transit caching. That
/// keeps the bytes around but each view re-mount has to decode them into a
/// `UIImage` (or a `CGImageSource` frame array for GIFs / APNG / animated
/// WebP) — a 30–80 ms operation that's enough to flash a loader as a row
/// scrolls back into a `LazyVStack`.
///
/// This cache holds the already-decoded result so a row that came back into
/// view renders instantly with no loader flash. NSCache evicts under memory
/// pressure on its own.
@MainActor
enum DecodedImageCache {
    /// Bounded by count AND total decoded bytes. The byte cost is the real
    /// constraint — a 1024px static image is ~4 MB resident, an animated
    /// payload can be hundreds — so each `setObject` passes its pixel-byte
    /// cost and NSCache evicts LRU-ish when the budget is exceeded. The count
    /// limits stay as a backstop for pathological tiny-entry floods. Sized so
    /// the viewport-lookahead prefetcher can decode ahead without unbounded
    /// growth; NSCache additionally evicts under system memory pressure.
    private static let staticCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 512
        c.totalCostLimit = 128 * 1024 * 1024
        return c
    }()

    private static let animatedCache: NSCache<NSString, AnimatedPayloadBox> = {
        let c = NSCache<NSString, AnimatedPayloadBox>()
        c.countLimit = 64
        c.totalCostLimit = 256 * 1024 * 1024
        return c
    }()

    final class AnimatedPayloadBox {
        let payload: AnimatedImagePayload
        init(_ payload: AnimatedImagePayload) { self.payload = payload }
    }

    static func staticImage(for url: String) -> UIImage? {
        staticCache.object(forKey: url as NSString)
    }

    static func storeStatic(_ image: UIImage, for url: String) {
        staticCache.setObject(image, forKey: url as NSString, cost: pixelCost(image))
    }

    static func animatedPayload(for url: String) -> AnimatedImagePayload? {
        animatedCache.object(forKey: url as NSString)?.payload
    }

    static func storeAnimated(_ payload: AnimatedImagePayload, for url: String) {
        let perFrame = payload.frames.first.map(pixelCost) ?? 0
        let cost = perFrame * payload.frames.count
        animatedCache.setObject(AnimatedPayloadBox(payload), forKey: url as NSString, cost: cost)
    }

    /// Approximate resident bytes of a decoded image: pixels × 4 (BGRA).
    private static func pixelCost(_ image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale) * 4
    }
}
