import AVKit
import AVFoundation
import Observation

/// Where a Picture-in-Picture session came from, so the native "return to app"
/// (restore) button can re-open the right surface. Set by the PiP delegates
/// when the user taps restore; `MainView` observes
/// `VideoPiPCoordinator.shared.restoreRequest`, presents the matching view,
/// then clears it.
enum PiPRestoreRequest: Equatable {
    case liveStream(LiveStreamRoute)
    case fullscreenVideo(url: String, atSeconds: Double)
}

/// App-wide owner of the *single* active Picture-in-Picture session.
///
/// Native PiP keeps playing only while the objects driving it stay alive — the
/// `AVPlayer`, and (because PiP delegates are held *weakly*) the delegate, plus
/// the `AVPictureInPictureController` (inline videos) or `AVPlayerViewController`
/// (live streams / fullscreen videos). Those normally die with the source view:
/// feed videos live in recyclable `LazyVStack` rows, and live/fullscreen players
/// are dismissed. So when PiP starts we hand the driving objects here via
/// `begin(player:retaining:)`; they survive until PiP stops. Without this the
/// restore button would dead-end and inline playback would pause on scroll-off.
///
/// Inline rows also call `isOwning(_:)` in `onDisappear` so scrolling a popped-out
/// video off-screen doesn't pause the floating window.
@MainActor
@Observable
final class VideoPiPCoordinator {
    static let shared = VideoPiPCoordinator()
    private init() {}

    /// The player currently driving PiP.
    private(set) var activePlayer: AVPlayer?
    /// Strong refs that keep the PiP session alive past its source view's
    /// teardown (player view controller / pip controller / delegate).
    private var retained: [AnyObject] = []
    /// True between PiP start and stop. Drives the inline `onDisappear` guard.
    private(set) var isPiPActive = false

    /// Set when the user taps the PiP window's restore button. `MainView`
    /// watches this, presents the source, then clears it.
    var restoreRequest: PiPRestoreRequest?

    /// True when `player` is the one currently popped out to PiP.
    func isOwning(_ player: AVPlayer) -> Bool {
        activePlayer === player
    }

    /// Take ownership of the objects driving a PiP session as it starts. Ends
    /// any prior session first — only one PiP at a time.
    func begin(player: AVPlayer?, retaining objects: [AnyObject]) {
        reset()
        activePlayer = player
        retained = objects
        isPiPActive = true
    }

    /// Release whatever this coordinator owns. Safe to call when nothing is
    /// active. Drops only this coordinator's strong refs — it does not pause or
    /// release players owned elsewhere (e.g. `LivePlayerStore`).
    func end() {
        reset()
    }

    func requestRestore(_ request: PiPRestoreRequest) {
        restoreRequest = request
    }

    func clearRestoreRequest() {
        restoreRequest = nil
    }

    private func reset() {
        activePlayer = nil
        retained = []
        isPiPActive = false
    }
}
