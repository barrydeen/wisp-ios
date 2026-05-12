import SwiftUI

extension View {
    /// Adds the long-press follow/unfollow affordance promised by the
    /// onboarding tutorial ("long-press any profile picture to follow or
    /// unfollow"). Apply at every avatar render site that displays another
    /// user; self-presses and missing-keypair cases short-circuit silently.
    ///
    /// `highPriorityGesture` so a deliberate hold runs the follow toggle
    /// *and* suppresses the wrapping `NavigationLink` / `Button` tap that
    /// would otherwise also fire on finger lift and push the profile. A
    /// quick tap shorter than the recognizer's `minimumDuration` still
    /// falls through to the tap target unchanged.
    func quickFollowOnLongPress(pubkey: String) -> some View {
        modifier(QuickFollowLongPressModifier(pubkey: pubkey))
    }
}

private struct QuickFollowLongPressModifier: ViewModifier {
    let pubkey: String
    @State private var busy = false
    /// 0 = idle, >0 = glow intensity during/after the press. Driven as a single
    /// scalar so the ring scale, stroke opacity, and outer shadow can all
    /// interpolate against it from one animation.
    @State private var glow: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // Rim glow tracing the avatar's edge: a crisp inner stroke at
            // the rim plus a wider, blurred halo just outside it. Both
            // layers scale their stroke and blur proportionally to the
            // avatar's actual rendered size so the ring reads consistently
            // on a 32pt DM avatar and on the 96pt profile header alike.
            // `40pt` is the calibration base — values picked there feel
            // right and `s` rescales everything from that anchor.
            .background(
                GeometryReader { geo in
                    let s = min(geo.size.width, geo.size.height) / 40.0
                    ZStack {
                        Circle()
                            .stroke(Color.wispPrimary.opacity(0.45), lineWidth: 6 * s)
                            .blur(radius: 5 * s)
                            .scaleEffect(1.07)
                        Circle()
                            .stroke(Color.wispPrimary, lineWidth: 3 * s)
                            .blur(radius: 1.2 * s)
                            .scaleEffect(1.025)
                    }
                    .opacity(Double(glow))
                }
                .allowsHitTesting(false)
            )
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in toggle() }
            )
    }

    private func toggle() {
        guard !busy, !pubkey.isEmpty,
              let kp = NostrKey.load(),
              kp.pubkey != pubkey else { return }
        busy = true
        let wasFollowing = FollowsCache.shared.followsSet(for: kp.pubkey).contains(pubkey)
        // Immediate feedback that the long-press registered: tactile pulse,
        // glow ring, and an optimistic toast. `FollowSender` already commits
        // the new follow set to the local cache before it tries to publish,
        // so showing the toast here matches the actual state of the app —
        // the relay round-trip is just confirmation. A publish failure
        // overrides the toast with the specific reason below.
        Haptics.shared.pulse()
        withAnimation(.easeInOut(duration: 0.18)) { glow = 1 }
        QuickFollowToast.shared.show(wasFollowing ? "Unfollowed" : "Followed")
        // Match the toast's lifetime exactly — same 0.18s ease-in, 1.6s
        // hold, 0.22s ease-out as `QuickFollowToast.show(_:)` — so the
        // ring and toast appear and dismiss together.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeInOut(duration: 0.22)) { glow = 0 }
        }
        Task { @MainActor in
            defer { busy = false }
            do {
                if wasFollowing {
                    try await FollowSender.shared.unfollow(pubkey, keypair: kp)
                } else {
                    try await FollowSender.shared.follow(pubkey, keypair: kp)
                }
                Haptics.shared.success()
            } catch {
                NSLog("[QuickFollow] toggle failed: %@", String(describing: error))
                QuickFollowToast.shared.show(QuickFollowLongPressModifier.message(for: error))
                Haptics.shared.fail()
            }
        }
    }

    /// Surface a concise reason for the toast so the user can tell whether
    /// the publish was rejected by relays, the key wasn't usable, etc.
    private static func message(for error: Error) -> String {
        if let send = error as? FollowSender.SendError {
            switch send {
            case .missingKey: return "Couldn't sign — key unavailable"
            case .noRelays: return "No write relays configured"
            case .publishFailed: return "Relays rejected the update"
            }
        }
        return "Couldn't update follow"
    }
}
