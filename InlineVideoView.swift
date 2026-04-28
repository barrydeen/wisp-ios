import SwiftUI
import AVKit
import AVFoundation
import Observation

@MainActor
@Observable
final class GlobalVideoMute {
    static let shared = GlobalVideoMute()
    var isMuted: Bool = true
    private init() {}
}

struct InlineVideoView: View {
    let meta: MediaMeta
    @Environment(AppSettings.self) private var settings
    @State private var loaded = false
    @State private var player: AVPlayer?
    @State private var showFullScreen = false
    @State private var muteState = GlobalVideoMute.shared
    /// Aspect ratio (W / H) detected from `AVPlayerItem.presentationSize` after
    /// the asset's tracks load. `nil` until known — many notes ship with no
    /// imeta `dim` tag, so we can't trust the static fallback.
    @State private var detectedAspect: CGFloat?

    /// Aspect we'd use without the runtime detection — imeta `dim` if present,
    /// otherwise the squarish default. Avoids assuming 16:9 (which silently
    /// turns every dim-less portrait video into a letterboxed flat box).
    private var staticAspect: CGFloat? {
        ContentParser.parseAspectRatio(meta.dimension)
    }

    /// Floor on the rendered box's aspect ratio (W / H). Sources taller than
    /// this — typical 9:16 phone video — get clamped so the player fills full
    /// card width instead of rendering near-double-tall. Content is cropped
    /// (resizeAspectFill) so there are no black bars on the sides.
    private let minDisplayAspect: CGFloat = 4.0 / 5.0

    /// Best-known aspect right now: detected presentation size > imeta dim >
    /// 4:5 default. The default matches the squarish gallery tile so a
    /// dim-less video starts in a sensible frame and adjusts once known.
    private var resolvedAspect: CGFloat {
        detectedAspect ?? staticAspect ?? minDisplayAspect
    }

    private var displayAspect: CGFloat {
        max(resolvedAspect, minDisplayAspect)
    }

    private var videoGravity: AVLayerVideoGravity {
        resolvedAspect < minDisplayAspect ? .resizeAspectFill : .resizeAspect
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black)

            if loaded, let player {
                CroppingVideoPlayer(player: player, gravity: videoGravity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onAppear {
                        MediaAudioSession.activatePlayback()
                        player.isMuted = muteState.isMuted
                        player.play()
                    }
                    .onDisappear {
                        player.pause()
                    }
                    .onChange(of: muteState.isMuted) { _, newValue in
                        player.isMuted = newValue
                    }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            muteState.isMuted.toggle()
                        } label: {
                            Image(systemName: muteState.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(Color.black.opacity(0.55), in: Circle())
                        }

                        Button {
                            showFullScreen = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(Color.black.opacity(0.55), in: Circle())
                        }
                    }
                    .padding(8)
                }
            } else {
                Button {
                    initPlayer()
                    loaded = true
                } label: {
                    ZStack {
                        Color.black.opacity(0.001)
                        VStack(spacing: 8) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(.white)
                            Text("Tap to play")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                .buttonStyle(.plain)
                .onAppear {
                    if settings.autoLoadMedia && settings.videoAutoplay {
                        initPlayer()
                        loaded = true
                    }
                }
            }
        }
        .aspectRatio(displayAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenVideoView(url: meta.url)
        }
    }

    private func initPlayer() {
        guard let url = URL(string: meta.url) else { return }
        let p = AVPlayer(url: url)
        p.isMuted = muteState.isMuted
        player = p
        Task { await detectAspect(for: p.currentItem) }
    }

    /// Reads the asset's natural video size via the modern `load(.tracks)`
    /// API and updates `detectedAspect` so the layout snaps to the real
    /// aspect even when no imeta `dim` tag was supplied.
    private func detectAspect(for item: AVPlayerItem?) async {
        guard let asset = item?.asset else { return }
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let resolved = size.applying(transform)
            let w = abs(resolved.width)
            let h = abs(resolved.height)
            guard w > 0, h > 0 else { return }
            await MainActor.run { detectedAspect = w / h }
        } catch {
            // Fall through — keep the static / default aspect.
        }
    }
}

/// `AVPlayerLayer` wrapper that exposes `videoGravity` (which `VideoPlayer`
/// does not). Used by `InlineVideoView` so portrait sources can fill the
/// rendered box via `.resizeAspectFill` instead of letterboxing.
struct CroppingVideoPlayer: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        uiView.playerLayer.videoGravity = gravity
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

struct FullScreenVideoView: View {
    let url: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear {
                        MediaAudioSession.activatePlayback()
                        player.play()
                    }
                    .onDisappear { player.pause() }
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(Color.black.opacity(0.6), in: Circle())
                    }
                    .padding()
                }
                Spacer()
            }
        }
        .task {
            if let videoURL = URL(string: url) {
                player = AVPlayer(url: videoURL)
            }
        }
    }
}
