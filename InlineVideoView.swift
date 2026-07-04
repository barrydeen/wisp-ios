import SwiftUI
import AVKit
import AVFoundation
import Observation

@MainActor
@Observable
final class GlobalVideoMute {
    static let shared = GlobalVideoMute()
    /// URL of the *single* video currently allowed to emit audio. `nil`
    /// means every InlineVideoView is muted (the default). Tapping unmute
    /// on a video sets this to that video's URL, which auto-mutes any
    /// other video that happens to be on screen — feed posts with two
    /// videos in view shouldn't play overlapping audio.
    var unmutedUrl: String? = nil
    private init() {}
}

/// Owns the `AVPictureInPictureController` for one inline feed video. Bridges
/// the layer-based PiP API to SwiftUI: `CroppingVideoPlayer` wires the on-screen
/// player layer in via `attach(layer:player:)`, the PiP button calls `start()`,
/// and the delegate hands the player to `VideoPiPCoordinator` (so playback
/// survives the row scrolling off-screen) and requests a fullscreen restore when
/// the user taps "return to app" on the floating window.
final class InlineVideoPiP: NSObject, AVPictureInPictureControllerDelegate {
    private var controller: AVPictureInPictureController?
    private weak var player: AVPlayer?
    /// URL used to re-present the video fullscreen on PiP restore.
    var restoreURL: String?
    /// Polls `isPictureInPicturePossible` after the audio-session takeover so we
    /// start PiP the moment the system allows it.
    private var startTask: Task<Void, Never>?

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Wire the on-screen player layer into a PiP controller. Called from
    /// `CroppingVideoPlayer.makeUIView`/`updateUIView`. Rebinds if the backing
    /// layer changed (SwiftUI can recreate the `UIView`), otherwise the
    /// controller would point at an off-screen layer and PiP would never become
    /// possible.
    func attach(layer: AVPlayerLayer, player: AVPlayer) {
        self.player = player
        guard Self.isSupported else { return }
        if controller?.playerLayer !== layer {
            let c = AVPictureInPictureController(playerLayer: layer)
            c?.delegate = self
            controller = c
        }
    }

    /// Pop this video into the system PiP window. Hands the controller + this
    /// delegate to `VideoPiPCoordinator` first so they outlive the recyclable
    /// feed row; `isOwning` then stops the row's `onDisappear` pausing it.
    func start() {
        guard let controller, let player else {
            QuickFollowToast.shared.show("Picture-in-Picture isn't available here")
            return
        }
        // PiP needs the session as the primary `.playback` route — inline
        // autoplay leaves it mixable (`.mixWithOthers`), under which PiP can't
        // start. Take it over, then start once the controller reports it's
        // possible (the switch propagates a beat later, so a synchronous check
        // here would falsely fail).
        MediaAudioSession.activatePlayback()
        player.isMuted = false
        VideoPiPCoordinator.shared.begin(player: player, retaining: [controller, self])

        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
            return
        }
        startTask?.cancel()
        startTask = Task { @MainActor in
            // Poll up to ~2s for PiP to become possible after the session switch.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                if controller.isPictureInPicturePossible {
                    controller.startPictureInPicture()
                    return
                }
            }
            VideoPiPCoordinator.shared.end()
            QuickFollowToast.shared.show("Picture-in-Picture isn't available here")
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            if let url = self.restoreURL, let player = self.player {
                let seconds = CMTimeGetSeconds(player.currentTime())
                VideoPiPCoordinator.shared.requestRestore(
                    .fullscreenVideo(url: url, atSeconds: seconds.isFinite ? seconds : 0)
                )
            }
            completionHandler(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.startTask?.cancel()
            VideoPiPCoordinator.shared.end()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.startTask?.cancel()
            VideoPiPCoordinator.shared.end()
            QuickFollowToast.shared.show("Couldn't start Picture-in-Picture")
        }
    }
}

struct InlineVideoView: View {
    let meta: MediaMeta
    /// Hex pubkey of the note author that owns this media. Forwarded to image
    /// surfaces (poster / fullscreen) for Blossom fallback when needed.
    var authorPubkey: String? = nil
    /// When true the AVPlayer's render surface ignores hit tests so swipes
    /// pass through to a parent gesture, and the inline tap-to-fullscreen +
    /// corner expand affordances are dropped. Used inside
    /// `FullScreenMediaPager` where the player would otherwise swallow the
    /// page-swipe and pull-to-dismiss gestures across the video bounds.
    var passthroughHitTests: Bool = false
    @Environment(AppSettings.self) private var settings
    @State private var loaded = false
    @State private var player: AVPlayer?
    @State private var showFullScreen = false
    @State private var muteState = GlobalVideoMute.shared
    /// Per-video Picture-in-Picture controller. Created lazily once the player
    /// layer is on screen; the PiP button (below) starts the floating window.
    @State private var pip = InlineVideoPiP()
    @State private var showPhotosAlert = false
    /// True when the user deliberately paused inline playback by tapping the
    /// video. Drives the centered play affordance. Distinct from lifecycle
    /// pauses (scroll-off) — those don't set it, and `onAppear` clears it on
    /// the re-appearing autoplay.
    @State private var isPaused = false
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

    /// True when this view's video should be silent. Derived from the global
    /// "single unmuted video" state so two visible feed videos can't both
    /// play audio at once.
    private var isMuted: Bool { muteState.unmutedUrl != meta.url }

    /// Pre-play poster fallback when there's no imeta `image` URL (or it
    /// hasn't loaded yet): prefer the AVFoundation-decoded first frame, fall
    /// back to the NIP-92 blurhash, fall back to the underlying black tile.
    @ViewBuilder
    private var blurhashOrGeneratedPoster: some View {
        if let blurImage = BlurHash.decode(meta.blurhash, width: 32, height: 32) {
            GeneratedVideoPoster(videoUrl: meta.url) {
                Image(uiImage: blurImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        } else {
            GeneratedVideoPoster(videoUrl: meta.url) { Color.black.opacity(0.001) }
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black)

            if loaded, let player {
                CroppingVideoPlayer(player: player, gravity: videoGravity, pip: passthroughHitTests ? nil : pip)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Tapping anywhere on the playing video toggles
                        // play/pause — fullscreen lives on the dedicated
                        // corner expand button instead. The inner mute /
                        // expand buttons (rendered after this in the ZStack)
                        // take SwiftUI hit-test priority over an
                        // `onTapGesture`, so their actions still fire.
                        // Skipped in passthrough mode — the parent pager is
                        // already a fullscreen presentation and we want the
                        // tap surface available for its own gestures.
                        guard !passthroughHitTests else { return }
                        if isPaused {
                            player.play()
                            withAnimation(.easeInOut(duration: 0.15)) { isPaused = false }
                        } else {
                            player.pause()
                            withAnimation(.easeInOut(duration: 0.15)) { isPaused = true }
                        }
                    }
                    .allowsHitTesting(!passthroughHitTests)
                    .onAppear {
                        // Pin the shared AVAudioSession to mixed mode so
                        // silent (muted) playback coexists with whatever
                        // the user is listening to in another app
                        // (podcast, music). Without this, an earlier
                        // exclusive-mode player (live stream, audio note,
                        // tapped-unmute video) would have left the session
                        // at `.playback` no-mix, and AVPlayer.play() under
                        // that mode interrupts other apps even with
                        // `isMuted = true`.
                        MediaAudioSession.activateMixed()
                        player.isMuted = isMuted
                        player.play()
                        // A re-appearing row autoplays, so clear any prior
                        // user-pause. (onDisappear's pause is a lifecycle
                        // pause and intentionally leaves `isPaused` alone.)
                        isPaused = false
                    }
                    .onDisappear {
                        // Don't pause a video that's been popped into PiP — it
                        // must keep playing in the floating window after the row
                        // scrolls off-screen.
                        guard !VideoPiPCoordinator.shared.isOwning(player) else { return }
                        player.pause()
                    }
                    .onChange(of: muteState.unmutedUrl) { _, newValue in
                        let nowMuted = isMuted
                        if !nowMuted, player.isMuted {
                            // Just transitioned muted → unmuted on THIS
                            // player. Take ownership of the session so
                            // background audio actually pauses.
                            MediaAudioSession.activateExclusive()
                        } else if nowMuted, !player.isMuted, newValue == nil {
                            // Just transitioned unmuted → muted (the
                            // global slot was cleared). Drop back to mixed
                            // so any background audio that ducked / paused
                            // can resume.
                            MediaAudioSession.activateMixed()
                        }
                        player.isMuted = nowMuted
                    }

                // Centered play glyph shown only while the user has tapped to
                // pause, so the paused state is discoverable and re-tappable.
                // Non-interactive: taps fall through to the play/pause
                // `onTapGesture` on the video layer, and the bottom-trailing
                // mute / expand buttons keep their hit-test priority.
                if isPaused {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            // Tapping the speaker on a muted video promotes
                            // it to the global unmuted slot (auto-muting any
                            // other video). Tapping again (now unmuted)
                            // clears the slot, returning every video to
                            // muted.
                            muteState.unmutedUrl = isMuted ? meta.url : nil
                        } label: {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(Color.black.opacity(0.55), in: Circle())
                        }

                        if !passthroughHitTests {
                            Button {
                                Task { await saveVideo() }
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white)
                                    .padding(8)
                                    .background(Color.black.opacity(0.55), in: Circle())
                            }

                            if InlineVideoPiP.isSupported {
                                Button {
                                    // Pop into the system Picture-in-Picture
                                    // window so the user can keep scrolling the
                                    // feed (or leave the app) while watching.
                                    pip.restoreURL = meta.url
                                    muteState.unmutedUrl = meta.url
                                    pip.start()
                                } label: {
                                    Image(systemName: "pip.enter")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.white)
                                        .padding(8)
                                        .background(Color.black.opacity(0.55), in: Circle())
                                }
                            }

                            Button {
                                // Pause the inline player before the fullscreen
                                // cover takes over. SwiftUI keeps the underlying
                                // view alive when a fullScreenCover presents, so
                                // the inline `onDisappear` doesn't fire and both
                                // players would otherwise emit audio at once.
                                player.pause()
                                showFullScreen = true
                            } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white)
                                    .padding(8)
                                    .background(Color.black.opacity(0.55), in: Circle())
                            }
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
                        // Poster behind the play button: imeta `image` URL when
                        // present, AVFoundation-decoded first frame otherwise.
                        // The black RoundedRectangle below this ZStack still
                        // shows during the brief gap before the poster lands.
                        // When neither poster URL nor decoded frame are ready
                        // yet, fall through to a NIP-92 blurhash if one was
                        // tagged on the imeta — same intent as the still-image
                        // placeholder.
                        if let posterUrl = meta.posterUrl, let url = URL(string: posterUrl) {
                            RetryingAsyncImage(
                                url: url,
                                maxPixelSize: ImagePixelBudget.feed,
                                authorPubkey: authorPubkey,
                                content: { image in
                                    image.resizable().scaledToFill()
                                },
                                loading: { blurhashOrGeneratedPoster },
                                failure: { blurhashOrGeneratedPoster }
                            )
                        } else {
                            blurhashOrGeneratedPoster
                        }
                        VStack(spacing: 8) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(.white)
                                .shadow(radius: 4)
                            Text("Tap to play")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.95))
                                .shadow(radius: 4)
                        }
                    }
                }
                .buttonStyle(.plain)
                .onAppear {
                    if settings.autoLoadMedia && settings.videoAutoplay {
                        initPlayer()
                        loaded = true
                    } else if detectedAspect == nil, staticAspect == nil {
                        // Autoplay off + no imeta `dim`: probe the true aspect so
                        // the poster renders in the right-shaped box instead of
                        // the 4:5 fallback. Metadata-only, dim-less videos only.
                        Task { await detectAspectWithoutPlaying() }
                    }
                }
            }
        }
        .aspectRatio(displayAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem,
                  item === player?.currentItem,
                  settings.videoLoop else { return }
            player?.seek(to: .zero)
            player?.play()
        }
        .alert("Photos Access Required", isPresented: $showPhotosAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow Wisp to add to Photos in Settings to save videos.")
        }
        .fullScreenCover(isPresented: $showFullScreen, onDismiss: {
            // Resume the inline player on dismiss only when autoplay is on,
            // so users who disabled autoplay aren't surprised by audio
            // restarting in the feed. Keep `isPaused` in sync with whether
            // the inline player is actually playing so the centered play
            // glyph reflects reality (otherwise an autoplay-off video would
            // sit paused with no affordance).
            if settings.autoLoadMedia && settings.videoAutoplay {
                player?.play()
                isPaused = false
            } else {
                isPaused = true
            }
        }) {
            FullScreenVideoView(url: meta.url)
        }
    }

    private func saveVideo() async {
        do {
            try await MediaSaveService.saveVideoToPhotos(url: meta.url)
            QuickFollowToast.shared.show("Saved to Photos")
        } catch MediaSaveService.SaveError.denied {
            showPhotosAlert = true
        } catch {
            QuickFollowToast.shared.show("Save failed")
        }
    }

    private func initPlayer() {
        guard let url = URL(string: meta.url) else { return }
        let p = AVPlayer(url: url)
        p.isMuted = isMuted
        player = p
        Task { await detectAspect(of: p.currentItem?.asset) }
    }

    /// Probe the real aspect ratio *without* starting playback. Used by the
    /// poster branch when autoplay is off — otherwise `detectedAspect` stays
    /// nil (it's only set via `initPlayer`) and a dim-less video falls back to
    /// the squarish 4:5 default, squishing/cropping the poster. Builds a
    /// metadata-only `AVURLAsset` (no `AVPlayer`, no playback).
    private func detectAspectWithoutPlaying() async {
        guard let url = URL(string: meta.url) else { return }
        await detectAspect(of: AVURLAsset(url: url))
    }

    /// Reads the asset's natural video size via the modern `load(.tracks)`
    /// API and updates `detectedAspect` so the layout snaps to the real
    /// aspect even when no imeta `dim` tag was supplied.
    private func detectAspect(of asset: AVAsset?) async {
        guard let asset else { return }
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
    /// Optional Picture-in-Picture controller wired to this layer. Nil for
    /// passthrough usages (e.g. `FullScreenMediaPager`) that don't offer PiP.
    var pip: InlineVideoPiP? = nil

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        pip?.attach(layer: view.playerLayer, player: player)
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        uiView.playerLayer.videoGravity = gravity
        pip?.attach(layer: uiView.playerLayer, player: player)
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

struct FullScreenVideoView: View {
    let url: String
    /// When restoring from a PiP window, resume at the position the floating
    /// window was at. 0 for a fresh fullscreen open.
    var startSeconds: Double = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @State private var player: AVPlayer?
    @State private var dismissY: CGFloat = 0

    private var dismissProgress: CGFloat {
        // Linearly fade the black backdrop as the user drags down so the
        // gesture reads as a real "throw-away" — matches the Photos.app
        // and `MediaGridView` fullscreen dismiss feel.
        min(1, max(0, dismissY / 240))
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - dismissProgress * 0.7)
                .ignoresSafeArea()
            if let player {
                PiPPlayerViewController(
                    player: player,
                    onRestore: {
                        // "Return to app" tapped on the floating PiP window after
                        // the fullscreen cover was dismissed — re-present
                        // fullscreen via MainView at the current position.
                        let seconds = CMTimeGetSeconds(player.currentTime())
                        VideoPiPCoordinator.shared.requestRestore(
                            .fullscreenVideo(url: url, atSeconds: seconds.isFinite ? seconds : 0)
                        )
                    }
                )
                    .ignoresSafeArea()
                    .offset(y: dismissY)
                    .onAppear {
                        MediaAudioSession.activatePlayback()
                        player.play()
                    }
                    .onDisappear {
                        // Keep playing if the user popped this into PiP.
                        guard !VideoPiPCoordinator.shared.isOwning(player) else { return }
                        player.pause()
                    }
                    // `simultaneousGesture` runs alongside the player's
                    // built-in tap-to-toggle-controls / scrubber drags, so
                    // the system mute + PiP + AirPlay + scrubber + 10s-skip
                    // controls keep working unchanged while the user can
                    // also swipe down anywhere on the video to dismiss.
                    // `minimumDistance: 20` keeps small touches that the
                    // system would interpret as taps from being intercepted.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 20)
                            .onChanged { value in
                                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                                dismissY = max(0, value.translation.height)
                            }
                            .onEnded { value in
                                if value.translation.height > 120,
                                   abs(value.translation.height) > abs(value.translation.width) {
                                    dismiss()
                                } else {
                                    withAnimation(.spring(response: 0.3)) { dismissY = 0 }
                                }
                            }
                    )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem,
                  item === player?.currentItem,
                  settings.videoLoop else { return }
            player?.seek(to: .zero)
            player?.play()
        }
        .task {
            if let videoURL = URL(string: url) {
                let p = AVPlayer(url: videoURL)
                if startSeconds > 0 {
                    await p.seek(to: CMTime(seconds: startSeconds, preferredTimescale: 600))
                }
                player = p
            }
        }
    }
}
