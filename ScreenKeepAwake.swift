import AVFoundation
import UIKit

/// Keeps the screen on while any tracked `AVPlayer` is actively playing.
///
/// Without this, the system idle timer keeps running during video playback and
/// the screen dims/auto-locks mid-video. Surfaces call `track(_:)` when they
/// start driving a player and `untrack(_:owner:)` when they stop being
/// responsible for it; each tracked player is observed on
/// `timeControlStatus`, and the idle timer is disabled only while at least one
/// tracked player isn't paused. Pause, natural playback end, stalling to
/// rebuffer, and audio-session interruptions all flow through that one
/// observation, so no per-surface pause/end bookkeeping can drift.
///
/// `owner` lets two surfaces hold the same player independently — a visible
/// feed row and `VideoPiPCoordinator` during Picture-in-Picture. It defaults
/// to the player itself, which is unique per surface for inline/fullscreen
/// players. Audio playback deliberately isn't tracked: podcast-style audio
/// should let the screen sleep.
enum ScreenKeepAwake {
    private struct Entry {
        let player: AVPlayer
        let observation: NSKeyValueObservation
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]

    static func track(_ player: AVPlayer, owner: AnyObject? = nil) {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let key = ObjectIdentifier(owner ?? player)
        guard entries[key] == nil else { return }
        let observation = player.observe(\.timeControlStatus, options: [.new]) { _, _ in
            Task { @MainActor in refresh() }
        }
        entries[key] = Entry(player: player, observation: observation)
        refresh()
        #endif
    }

    static func untrack(_ player: AVPlayer, owner: AnyObject? = nil) {
        #if os(iOS) || os(tvOS) || os(visionOS)
        entries[ObjectIdentifier(owner ?? player)] = nil
        refresh()
        #endif
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    private static func refresh() {
        let anyPlaying = entries.values.contains { entry in
            entry.player.timeControlStatus != .paused
        }
        UIApplication.shared.isIdleTimerDisabled = anyPlaying
    }
    #endif
}
