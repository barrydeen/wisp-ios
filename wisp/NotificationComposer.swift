import SwiftUI

/// Tap-to-open affordance that hands off to the full `ComposeView` in `.reply` mode.
/// Matches the thread-view pattern — replies share the same composer as new posts so
/// mentions, emoji, media, polls, and the 10-second undo countdown all work.
struct NotificationComposer: View {
    let targetEvent: NostrEvent
    @Binding var sending: Bool
    let viewModel: NotificationsViewModel

    @State private var showCompose = false
    /// Root router for keyboard-raising sheets. This row lives in the
    /// notifications lazy feed; presenting the composer from its own
    /// `.sheet` is the recycle-loop mechanism a diagnostic trace proved on
    /// 2026-06-07 (keyboard rises → presenting row recycled → the row's
    /// surviving `@State` re-presents, looping until force-quit), so
    /// replies route to the app-root host. The local sheet below survives
    /// only as the fallback for a missing environment injection.
    @Environment(ComposePresenter.self) private var composePresenter: ComposePresenter?

    var body: some View {
        Button {
            if let composePresenter {
                composePresenter.openReply(parent: targetEvent, root: replyRoot())
            } else {
                showCompose = true
            }
        } label: {
            HStack(spacing: 10) {
                Text("Reply\u{2026}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "pencil")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.wispPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.wispSurfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showCompose) {
            if let keypair = NostrKey.load() {
                ComposeView(keypair: keypair, mode: .reply(parent: targetEvent, root: replyRoot()))
            }
        }
    }

    /// Resolve the thread root. If `targetEvent` is itself a reply, build a minimal stub
    /// pointing at its NIP-10 `root` so ComposeView emits a proper `["e", root, "", "root"]`
    /// tag. Otherwise `targetEvent` is the root.
    private func replyRoot() -> NostrEvent? {
        guard let rootId = Nip10.rootId(of: targetEvent), rootId != targetEvent.id else {
            return targetEvent
        }
        return NostrEvent(
            id: rootId, pubkey: "", kind: 1,
            createdAt: 0, tags: [], content: "", sig: ""
        )
    }
}
