import SwiftUI
import AVKit
import AVFoundation

/// Reusable `AVPlayerViewController` wrapper with Picture-in-Picture fully
/// wired — including the `restoreUserInterfaceForPictureInPictureStop` delegate
/// the system calls when the user taps "return to app" on the PiP window.
///
/// Generalized from the live-stream player so fullscreen videos get the same
/// behavior. On PiP start the controller hands the player view controller (and
/// itself, the delegate) to `VideoPiPCoordinator` so the session survives this
/// view being dismissed; the caller-supplied `onRestore` re-presents the source.
struct PiPPlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer
    /// Called from the restore delegate; re-present the source surface here.
    var onRestore: () -> Void = {}
    var showsPlaybackControls = true

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player, onRestore: onRestore)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.videoGravity = .resizeAspect
        vc.showsPlaybackControls = showsPlaybackControls
        vc.delegate = context.coordinator
        vc.player = player
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        context.coordinator.update(player: player, onRestore: onRestore)
        if vc.player !== player {
            vc.player = player
        }
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        // Do NOT clear vc.player — PiP continues against the retained player.
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private var player: AVPlayer
        private var onRestore: () -> Void

        init(player: AVPlayer, onRestore: @escaping () -> Void) {
            self.player = player
            self.onRestore = onRestore
        }

        func update(player: AVPlayer, onRestore: @escaping () -> Void) {
            self.player = player
            self.onRestore = onRestore
        }

        nonisolated func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            Task { @MainActor in
                VideoPiPCoordinator.shared.begin(player: self.player, retaining: [playerViewController, self])
            }
        }

        nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            Task { @MainActor in VideoPiPCoordinator.shared.end() }
        }

        nonisolated func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            Task { @MainActor in
                self.onRestore()
                completionHandler(true)
            }
        }
    }
}
