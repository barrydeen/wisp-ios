import AVFoundation
import Observation
import UIKit

/// In-memory cache of video poster frames generated on demand via `AVAssetImageGenerator`.
///
/// When a kind-1 / kind-21 / kind-22 video has no NIP-92 `image` poster URL we fall back to
/// asking AVFoundation to decode the first key frame. That requires fetching a small chunk of
/// the video header, which is the minimum cost to get a real frame instead of a black tile.
///
/// Cache is keyed by the video URL so repeat impressions of the same clip in the feed (and
/// in the fullscreen pager) share one decode.
@MainActor
@Observable
final class VideoPosterCache {
    static let shared = VideoPosterCache()

    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var inflight: Set<String> = []

    private init() {}

    /// Returns a cached poster if one exists; otherwise kicks off a one-shot generator that
    /// fills `images[url]` when the first frame is decoded. The caller observes `images` so
    /// SwiftUI re-renders the moment the poster lands.
    func image(for url: String) -> UIImage? {
        if let cached = images[url] { return cached }
        ensureGenerated(url: url)
        return nil
    }

    func ensureGenerated(url: String) {
        guard images[url] == nil, !inflight.contains(url) else { return }
        guard let parsed = URL(string: url) else { return }
        inflight.insert(url)
        Task.detached(priority: .utility) { [weak self] in
            let asset = AVURLAsset(url: parsed)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1024, height: 1024)
            // Prefer a frame ~0.5s in so HLS streams that start with a black slate still resolve
            // to something visible. The generator returns whichever keyframe is closest.
            let target = CMTime(seconds: 0.5, preferredTimescale: 600)
            do {
                let cg = try await generator.image(at: target).image
                let ui = UIImage(cgImage: cg)
                await MainActor.run {
                    self?.images[url] = ui
                    self?.inflight.remove(url)
                }
            } catch {
                await MainActor.run { self?.inflight.remove(url) }
            }
        }
    }
}
