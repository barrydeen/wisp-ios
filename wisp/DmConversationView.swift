import SwiftUI

struct DmConversationView: View {
    let keypair: Keypair
    let participants: [String]

    @State private var viewModel: DmConversationViewModel
    @State private var profiles: [String: ProfileData] = [:]
    @FocusState private var composerFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(keypair: Keypair, participants: [String]) {
        self.keypair = keypair
        self.participants = participants
        _viewModel = State(initialValue: DmConversationViewModel(keypair: keypair, participants: participants))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
            messageList
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
            composer
        }
        .background(Color.wispBackground)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            viewModel.refresh()
            loadProfiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            viewModel.refresh()
        }
    }

    private var title: String {
        if participants.count == 1, let p = participants.first {
            return profiles[p]?.displayString ?? shortPubkey(p)
        }
        return "Group (\(participants.count))"
    }

    private var header: some View {
        ZStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 60)
            HStack {
                BackChevronButton { dismiss() }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.messages) { msg in
                        DmMessageBubbleView(
                            message: msg,
                            isMine: msg.senderPubkey == keypair.pubkey,
                            senderProfile: profiles[msg.senderPubkey],
                            onReply: { viewModel.replyingTo = msg }
                        )
                        .id(msg.id)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let reply = viewModel.replyingTo {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .foregroundStyle(Color.wispPrimary)
                    Text("Replying to: \(reply.content)")
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        viewModel.replyingTo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $viewModel.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 18))
                    .focused($composerFocused)

                Button {
                    Task {
                        await viewModel.send()
                        viewModel.refresh()
                    }
                } label: {
                    if viewModel.isSending {
                        ProgressView().tint(.white).padding(10)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(10)
                    }
                }
                .background(canSend ? Color.wispPrimary : Color.wispSurfaceVariant, in: Circle())
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            if let err = viewModel.sendError {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
            }
        }
    }

    private var canSend: Bool {
        !viewModel.isSending && !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadProfiles() {
        let repo = ProfileRepository.shared
        for pk in participants {
            profiles[pk] = repo.get(pk)
        }
        profiles[keypair.pubkey] = repo.get(keypair.pubkey)
    }

    private func shortPubkey(_ hex: String) -> String {
        guard hex.count >= 8 else { return hex }
        return Nip19.shortNpub(hex: hex)
    }
}

struct DmMessageBubbleView: View {
    let message: DmMessage
    let isMine: Bool
    let senderProfile: ProfileData?
    let onReply: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMine { Spacer(minLength: 40) }
            if !isMine {
                CachedAvatarView(url: senderProfile?.picture, size: 28)
            }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .font(.subheadline)
                    .foregroundStyle(isMine ? Color.white : Color.wispOnSurface)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        isMine ? Color.wispPrimary : Color.wispSurfaceVariant,
                        in: RoundedRectangle(cornerRadius: 18)
                    )
            }
            .contextMenu {
                Button { onReply() } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            }
            if !isMine { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }
}
