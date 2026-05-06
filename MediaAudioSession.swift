import AVFoundation

/// Centralized AVAudioSession setup for inline media playback.
///
/// iOS defaults the shared session to `.soloAmbient`, which honors the
/// device's silent switch and ducks against other audio — so videos and
/// audio notes play silently whenever the ringer is off, and only "work"
/// after some other surface (e.g. a NIP-53 live stream) has already
/// promoted the session to `.playback`. That's the "sound works some of
/// the time" symptom.
///
/// `activatePlayback()` is idempotent and cheap: call it immediately
/// before any `AVPlayer.play()` in the inline video / fullscreen video /
/// audio note views. Setting the same category twice is a no-op; the
/// activate call also re-arms the session after interruptions (phone
/// calls, route changes, other apps' audio).
enum MediaAudioSession {
    /// Configure the shared session for silent or mixed playback so muted
    /// videos don't pause whatever the user is listening to in another app
    /// (podcast, music, audiobook). Idempotent — safe to call from every
    /// inline player's `onAppear`. The user-explicit "take over" call is
    /// `activateExclusive()`.
    static func activateMixed() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
        #endif
    }

    /// Take ownership of the audio session — pauses other apps' audio.
    /// Called only when the user explicitly unmutes a video, plays an
    /// audio note, or opens a fullscreen / live-stream player.
    static func activateExclusive() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true, options: [])
        #endif
    }

    /// Backward-compatible alias. Existing call sites that use this name
    /// (audio notes, fullscreen video, live stream) all want the
    /// exclusive variant.
    static func activatePlayback() {
        activateExclusive()
    }
}
