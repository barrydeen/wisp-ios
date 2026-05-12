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

    func body(content: Content) -> some View {
        content.highPriorityGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in toggle() }
        )
    }

    private func toggle() {
        guard !busy, !pubkey.isEmpty,
              let kp = NostrKey.load(),
              kp.pubkey != pubkey else { return }
        busy = true
        // Pre-read so the toast text reflects the action the user just took,
        // not whatever state the cache ends up in after the publish round-trip.
        let wasFollowing = FollowsCache.shared.followsSet(for: kp.pubkey).contains(pubkey)
        Haptics.shared.pulse()
        Task { @MainActor in
            defer { busy = false }
            do {
                if wasFollowing {
                    try await FollowSender.shared.unfollow(pubkey, keypair: kp)
                    QuickFollowToast.shared.show("Unfollowed")
                } else {
                    try await FollowSender.shared.follow(pubkey, keypair: kp)
                    QuickFollowToast.shared.show("Followed")
                }
            } catch {
                NSLog("[QuickFollow] toggle failed: %@", String(describing: error))
                QuickFollowToast.shared.show(QuickFollowLongPressModifier.message(for: error))
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
