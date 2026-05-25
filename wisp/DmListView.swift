import SwiftUI

struct DmListView: View {
    let viewModel: MessagesViewModel
    let onTap: (DmConversation) -> Void
    let onCompose: () -> Void

    var body: some View {
        ZStack {
            if viewModel.conversations.isEmpty {
                empty
            } else {
                list
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    composeButton
                        .padding(.trailing, 18)
                        .padding(.bottom, 32)
                }
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.conversations) { conv in
                    Button { onTap(conv) } label: {
                        DmListRow(conversation: conv, myPubkey: viewModel.keypair.pubkey)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No messages yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Tap the compose button to start an encrypted DM.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composeButton: some View {
        Button(action: onCompose) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.wispPrimary, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New message")
    }
}

private struct DmListRow: View {
    let conversation: DmConversation
    let myPubkey: String

    @State private var profile: ProfileData?

    private var peerPubkey: String { conversation.peerPubkey }
    private var lastMessage: DmMessage? { conversation.messages.last }

    var body: some View {
        HStack(spacing: 12) {
            CachedAvatarView(url: profile?.picture, size: 48)
                .quickFollowOnLongPress(pubkey: peerPubkey)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if conversation.isGroup {
                        Text("(\(conversation.participants.count))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let ts = lastMessage?.createdAt {
                        Text(relativeTime(ts))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .task(id: peerPubkey) {
            profile = ProfileRepository.shared.get(peerPubkey)
        }
    }

    private var displayName: String {
        profile?.displayString ?? shortPubkey(peerPubkey)
    }

    private var preview: String {
        guard let last = lastMessage else { return "(no messages)" }
        let isMine = last.senderPubkey == myPubkey
        return isMine ? "You: \(last.content)" : last.content
    }

    private func shortPubkey(_ hex: String) -> String {
        guard hex.count >= 8 else { return hex }
        return Nip19.shortNpub(hex: hex)
    }

    private func relativeTime(_ ts: Int) -> String {
        let interval = Date().timeIntervalSince1970 - Double(ts)
        switch interval {
        case ..<60: return "now"
        case ..<3600: return "\(Int(interval / 60))m"
        case ..<86400: return "\(Int(interval / 3600))h"
        default: return "\(Int(interval / 86400))d"
        }
    }
}
