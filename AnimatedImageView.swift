import SwiftUI
import UIKit
import ImageIO

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
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let failure: () -> Failure

    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case success(AnimatedImagePayload)
        case failure
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                placeholder()
            case .failure:
                failure()
            case .success(let payload):
                AnimatedImageRenderer(payload: payload)
                    .aspectRatio(aspect ?? payload.aspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url else {
            phase = .failure
            return
        }
        phase = .loading

        let payload: AnimatedImagePayload? = await Task.detached(priority: .utility) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                return AnimatedImageDecoder.decode(data: data)
            } catch {
                return nil
            }
        }.value

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

enum AnimatedImageDecoder {
    /// Decodes every frame from `data`, summing the per-frame delays for the
    /// total animation duration. Returns nil if the bytes don't decode to an
    /// image. For single-frame inputs, returns one frame with duration 0.
    static func decode(data: Data) -> AnimatedImagePayload? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }

        var frames: [UIImage] = []
        frames.reserveCapacity(count)
        var total: TimeInterval = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            if count > 1 {
                total += frameDelay(at: i, source: src)
            }
        }
        guard let first = frames.first else { return nil }
        let aspect: CGFloat = first.size.height > 0 ? first.size.width / first.size.height : 1
        return AnimatedImagePayload(frames: frames, totalDuration: total, aspect: aspect)
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
enum AnimatedImageHint {
    static func isLikelyAnimated(url: String, mime: String?) -> Bool {
        if let mime = mime?.lowercased(), mime.hasPrefix("image/gif") {
            return true
        }
        let lower = url.lowercased()
        let withoutQuery = lower.split(separator: "?").first.map(String.init) ?? lower
        let withoutFragment = withoutQuery.split(separator: "#").first.map(String.init) ?? withoutQuery
        return withoutFragment.hasSuffix(".gif")
    }
}

private struct AnimatedImageRenderer: UIViewRepresentable {
    let payload: AnimatedImagePayload

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
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
