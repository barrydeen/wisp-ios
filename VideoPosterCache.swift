import AVFoundation
import Observation
import QuartzCore
import UIKit
import os

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

    #if DEBUG
    /// Tracks whether any AVFoundation API has been touched yet this session.
    /// The first `AVURLAsset`/`AVAssetImageGenerator` triggers framework load +
    /// `mediaserverd` connection — a prime suspect for the one-time feed freeze.
    @ObservationIgnored private static var firstAVUse = false
    #endif

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
        #if DEBUG
        let firstUse = !Self.firstAVUse
        Self.firstAVUse = true
        PerfTrace.mark(firstUse ? "poster.firstAVFoundation" : "poster.generate", url: url)
        #endif
        Task.detached(priority: .utility) { [weak self] in
            #if DEBUG
            let t0 = CACurrentMediaTime()
            let sp = Signposts.media.beginInterval("posterGenerate")
            #endif
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
                #if DEBUG
                Signposts.media.endInterval("posterGenerate", sp)
                mediaPerfLog.log("posterGenerate \(Int((CACurrentMediaTime() - t0) * 1000), privacy: .public)ms firstAVFoundation=\(firstUse, privacy: .public) url=\(url, privacy: .public)")
                #endif
                await MainActor.run {
                    self?.images[url] = ui
                    self?.inflight.remove(url)
                }
            } catch {
                #if DEBUG
                Signposts.media.endInterval("posterGenerate", sp)
                mediaPerfLog.error("posterGenerate FAILED \(Int((CACurrentMediaTime() - t0) * 1000), privacy: .public)ms url=\(url, privacy: .public)")
                #endif
                await MainActor.run { self?.inflight.remove(url) }
            }
        }
    }
}
