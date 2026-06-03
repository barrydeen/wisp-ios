import SwiftUI
import UIKit
import os.signpost

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
    /// Longest-edge pixel cap for the decode. Defaults to 1024 (matches the
    /// inline animated / video-poster cap) so feed / grid / gallery images are
    /// downsampled to a bounded size instead of decompressing the full source
    /// on the main thread at draw time. Full-screen zoom passes `nil` to keep
    /// native resolution.
    let maxPixelSize: CGFloat?
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
        maxPixelSize: CGFloat? = 1024,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder loading: @escaping () -> Loading,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.url = url
        self.maxAttempts = maxAttempts
        self.maxPixelSize = maxPixelSize
        self.content = content
        self.loading = loading
        self.failure = failure
    }

    var body: some View {
        Group {
            switch phase {
            case .empty, .loading:
                loading()
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
        .task(id: TaskKey(url: url, attempt: attempt)) {
            await load()
        }
    }

    /// Combined state key so a URL change OR a retry both kick off a fresh
    /// load via `.task(id:)`. Reusing one identifier per view keeps the
    /// cancellation semantics clean.
    private struct TaskKey: Hashable {
        let url: URL?
        let attempt: Int
    }

    private func load() async {
        guard let url else {
            phase = .failure
            return
        }
        // Key the decoded cache by url + pixel cap so the inline-capped (1024)
        // and full-screen-uncapped variants of the same URL don't collide.
        let key = maxPixelSize.map { "\(url.absoluteString)#px\(Int($0))" } ?? url.absoluteString

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

        phase = .loading
        let cap = maxPixelSize
        let image: UIImage? = await Task.detached(priority: .utility) {
            let signpostId = Signposts.media.makeSignpostID()
            let signpostState = Signposts.media.beginInterval("fetchStaticImage", id: signpostId)
            defer { Signposts.media.endInterval("fetchStaticImage", signpostState) }
            do {
                // Dedicated foreground image session (own pool + 64/256 MB
                // transit cache) instead of URLSession.shared, so image loads
                // don't share the 6-per-host budget with JSON/LNURL/relay-info.
                let (data, response) = try await HttpClientFactory.imageClient.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return nil
                }
                // Downsample to `cap` (off-main) so the main thread never
                // decompresses an oversized source at draw time.
                return AnimatedImageDecoder.decodeStatic(data: data, maxPixelSize: cap)
            } catch {
                return nil
            }
        }.value

        if Task.isCancelled { return }
        if let image {
            DecodedImageCache.storeStatic(image, for: key)
            phase = .success(image)
        } else if attempt < maxAttempts {
            attempt += 1  // Triggers another `task` cycle via TaskKey change.
        } else {
            phase = .failure
        }
    }
}
