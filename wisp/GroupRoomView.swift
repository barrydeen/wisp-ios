import SwiftUI

struct GroupRoomView: View {
    @Bindable var viewModel: GroupRoomViewModel
    @State private var showDetail = false

    var body: some View {
        VStack(spacing: 0) {
            messageList

            if let reply = viewModel.replyTarget {
                replyBanner(reply)
            }
            if let err = viewModel.sendError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 4)
            }

            composer
        }
        .background(Color.wispBackground)
        .navigationTitle(viewModel.room?.metadata?.name ?? viewModel.groupId)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showDetail = true } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .navigationDestination(isPresented: $showDetail) {
            GroupDetailView(viewModel: viewModel)
        }
        .onAppear {
            viewModel.repository.markRead(relayUrl: viewModel.relayUrl, groupId: viewModel.groupId)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.messages) { msg in
                        GroupMessageBubble(
                            message: msg,
                            isMine: msg.senderPubkey == viewModel.keypair.pubkey,
                            replyTarget: msg.replyToId.flatMap { id in
                                viewModel.messages.first(where: { $0.id == id })
                            }
                        )
                        .id(msg.id)
                        .onTapGesture { viewModel.setReplyTarget(msg) }
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func replyBanner(_ reply: GroupMessage) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to").font(.caption).foregroundStyle(.tertiary)
                Text(reply.content).font(.caption).lineLimit(2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { viewModel.clearReplyTarget() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.wispSurfaceVariant.opacity(0.5))
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $viewModel.messageText, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 18))
                .lineLimit(1...5)
            Button {
                Task { await viewModel.sendMessage() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(viewModel.messageText.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? Color.gray : Color.wispPrimary)
            }
            .disabled(viewModel.messageText.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isSending)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.wispBackground)
    }
}

private struct GroupMessageBubble: View {
    let message: GroupMessage
    let isMine: Bool
    let replyTarget: GroupMessage?

    @State private var profile: ProfileData?
    @State private var replyProfile: ProfileData?

    /// Synthesize NIP-30 emoji tags from the GroupMessage's stored emojiTags map
    /// so RichContentView can render `:shortcode:` references inline.
    private var emojiTagsForRenderer: [[String]] {
        message.emojiTags.map { ["emoji", $0.key, $0.value] }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isMine { Spacer(minLength: 40) }
            if !isMine {
                CachedAvatarView(url: profile?.picture, size: 32)
                    .padding(.top, 14)
            }

            VStack(alignment: .leading, spacing: 4) {
                if !isMine {
                    Text(profile?.displayString ?? short(message.senderPubkey))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }

                if let reply = replyTarget {
                    replyBanner(reply)
                }

                bubbleBody
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isMine ? Color.wispPrimary : Color.wispSurfaceVariant,
                                in: RoundedRectangle(cornerRadius: 14))

                if !message.reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(message.reactions.keys.sorted(), id: \.self) { emoji in
                            Text("\(emoji) \(message.reactions[emoji]?.count ?? 0)")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.wispSurfaceVariant.opacity(0.7),
                                            in: Capsule())
                        }
                    }
                }
            }
            if !isMine { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 12)
        .task(id: message.senderPubkey) {
            profile = ProfileRepository.shared.get(message.senderPubkey)
        }
        .task(id: replyTarget?.senderPubkey) {
            if let pk = replyTarget?.senderPubkey {
                replyProfile = ProfileRepository.shared.get(pk)
            }
        }
    }

    @ViewBuilder
    private var bubbleBody: some View {
        if message.emojiTags.isEmpty {
            Text(message.content)
                .font(.subheadline)
                .foregroundStyle(isMine ? Color.white : Color.wispOnSurface)
        } else {
            // RichContentView handles `:shortcode:` -> inline image substitution
            // via the synthesized NIP-30 emoji tag list. Forcing colorScheme
            // (the previous behavior) made `.primary` text resolve to black on
            // dark wispSurfaceVariant bubbles. Inherit the actual scheme and
            // let the renderer pick the matching tone.
            RichContentView(
                content: message.content,
                tags: emojiTagsForRenderer,
                profiles: [:],
                showLinkPreviews: false
            )
        }
    }

    @ViewBuilder
    private func replyBanner(_ reply: GroupMessage) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(Color.wispPrimary)
                .frame(width: 3)
                .cornerRadius(1.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(replyProfile?.displayString ?? short(reply.senderPubkey))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(reply.content)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func short(_ s: String) -> String {
        s.count >= 8 ? Nip19.shortNpub(hex: s) : s
    }
}
