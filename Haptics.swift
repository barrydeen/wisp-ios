import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreHaptics)
import CoreHaptics
#endif

@MainActor
final class Haptics {
    static let shared = Haptics()

    #if canImport(CoreHaptics) && !os(tvOS)
    private let supportsCoreHaptics: Bool
    private var engine: CHHapticEngine?
    #endif

    #if canImport(UIKit) && !os(tvOS)
    private let lightGen = UIImpactFeedbackGenerator(style: .light)
    private let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private let heavyGen = UIImpactFeedbackGenerator(style: .heavy)
    private let successGen = UINotificationFeedbackGenerator()
    #endif

    private init() {
        #if canImport(CoreHaptics) && !os(tvOS)
        supportsCoreHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        #endif
    }

    func blip() {
        #if canImport(UIKit) && !os(tvOS)
        lightGen.prepare()
        lightGen.impactOccurred(intensity: 0.3)
        #endif
    }

    func pulse() {
        #if canImport(UIKit) && !os(tvOS)
        mediumGen.prepare()
        mediumGen.impactOccurred(intensity: 0.6)
        #endif
    }

    /// Heavy single thump — the most prominent single-impact haptic we offer.
    /// Distinct from `pulse` (medium / 0.6) when both fire close together;
    /// used at the moment an instant zap kicks off so the user can feel the
    /// gesture *commit*, not just be acknowledged.
    func bump() {
        #if canImport(UIKit) && !os(tvOS)
        heavyGen.prepare()
        heavyGen.impactOccurred(intensity: 1.0)
        #endif
    }

    /// CoreHaptics-backed short tap for touch-down acknowledgement on the
    /// zap button. Uses the same `CHHapticEngine` path as `zapBuzz` —
    /// `UIImpactFeedbackGenerator` can sit silent on devices where the
    /// Settings → Sounds & Haptics → System Haptics toggle is off, but
    /// CoreHaptics-driven patterns play either way.
    func zapPressTap() {
        #if canImport(CoreHaptics) && !os(tvOS)
        playCoreHapticTap(intensity: 0.55, sharpness: 0.7) { [weak self] in
            #if canImport(UIKit)
            self?.mediumGen.prepare()
            self?.mediumGen.impactOccurred(intensity: 0.6)
            #endif
        }
        #endif
    }

    /// CoreHaptics-backed strong tap for the moment a long-press commits
    /// to an instant zap. Sharper than `zapPressTap` so the two feel
    /// distinct when they fire ~250 ms apart.
    func zapCommitThump() {
        #if canImport(CoreHaptics) && !os(tvOS)
        playCoreHapticTap(intensity: 1.0, sharpness: 0.95) { [weak self] in
            #if canImport(UIKit)
            self?.heavyGen.prepare()
            self?.heavyGen.impactOccurred(intensity: 1.0)
            #endif
        }
        #endif
    }

    #if canImport(CoreHaptics) && !os(tvOS)
    /// Shared transient-event player for the zap press / commit taps.
    /// Falls through to `fallback` (a `UIImpactFeedbackGenerator` call)
    /// on devices without CoreHaptics support OR when the engine errors,
    /// so we never end up silent regardless of hardware path.
    private func playCoreHapticTap(
        intensity: Float,
        sharpness: Float,
        fallback: () -> Void
    ) {
        guard supportsCoreHaptics else {
            fallback()
            return
        }
        do {
            try ensureEngineRunning()
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                ],
                relativeTime: 0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine?.makePlayer(with: pattern)
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {
            NSLog("[Haptics] zap-press tap failed: %@", String(describing: error))
            fallback()
        }
    }
    #endif

    /// Discrete "operation succeeded" tap — softer than `pulse` so it reads
    /// as a confirmation, not a separate action. Used after follow / unfollow
    /// publishes settle.
    func success() {
        #if canImport(UIKit) && !os(tvOS)
        successGen.prepare()
        successGen.notificationOccurred(.success)
        #endif
    }

    /// Discrete "operation failed" buzz. Pairs with `success` so the user
    /// gets unambiguous feedback either way.
    func fail() {
        #if canImport(UIKit) && !os(tvOS)
        successGen.prepare()
        successGen.notificationOccurred(.error)
        #endif
    }

    func zapBuzz() {
        #if canImport(CoreHaptics) && canImport(UIKit) && !os(tvOS)
        guard supportsCoreHaptics else {
            successGen.prepare()
            successGen.notificationOccurred(.success)
            return
        }
        do {
            try ensureEngineRunning()
            let e1 = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.78),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)
                ],
                relativeTime: 0,
                duration: 0.060
            )
            let e2 = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
                ],
                relativeTime: 0.100,
                duration: 0.100
            )
            let pattern = try CHHapticPattern(events: [e1, e2], parameters: [])
            let player = try engine?.makePlayer(with: pattern)
            try player?.start(atTime: CHHapticTimeImmediate)
        } catch {
            NSLog("[Haptics] zapBuzz failed: %@", String(describing: error))
            successGen.notificationOccurred(.success)
        }
        #endif
    }

    #if canImport(CoreHaptics) && !os(tvOS)
    private func ensureEngineRunning() throws {
        if engine == nil {
            let e = try CHHapticEngine()
            e.resetHandler = { [weak self] in
                try? self?.engine?.start()
            }
            try e.start()
            engine = e
        } else {
            try engine?.start()
        }
    }
    #endif
}
