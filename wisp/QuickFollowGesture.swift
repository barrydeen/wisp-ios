import SwiftUI

extension View {
    /// Adds the long-press follow/unfollow affordance promised by the
    /// onboarding tutorial ("long-press any profile picture to follow or
    /// unfollow"). Apply at every avatar render site that displays another
    /// user; self-presses and missing-keypair cases short-circuit silently.
    ///
    /// Uses `simultaneousGesture` so callers that wrap the avatar in a
    /// `NavigationLink` or `Button` (tap-to-open-profile) keep their normal
    /// tap behavior — only a deliberate hold routes here.
    func quickFollowOnLongPress(pubkey: String) -> some View {
        modifier(QuickFollowLongPressModifier(pubkey: pubkey))
    }
}

private struct QuickFollowLongPressModifier: ViewModifier {
    let pubkey: String
    @State private var busy = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(
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
                QuickFollowToast.shared.show("Couldn't update follow")
            }
        }
    }
}
