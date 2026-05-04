import SwiftUI

/// Tap-to-open affordance that hands off to the full `ComposeView` in `.reply` mode.
/// Matches the thread-view pattern — replies share the same composer as new posts so
/// mentions, emoji, media, polls, and the 10-second undo countdown all work.
struct NotificationComposer: View {
    let targetEvent: NostrEvent
    @Binding var sending: Bool
    let viewModel: NotificationsViewModel

    @State private var showCompose = false

    var body: some View {
        Button {
            showCompose = true
        } label: {
            HStack(spacing: 10) {
                Text("Reply\u{2026}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "square.and.pencil")
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
