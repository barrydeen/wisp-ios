import SwiftUI
import PhotosUI

struct DmConversationView: View {
    let keypair: Keypair
    let participants: [String]

    @State private var viewModel: DmConversationViewModel
    @State private var profiles: [String: ProfileData] = [:]
    @State private var photoItem: PhotosPickerItem?
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
                        let parent = msg.replyToId.flatMap { rid in
                            viewModel.messages.first { $0.rumorId == rid }
                        }
                        DmMessageBubbleView(
                            message: msg,
                            isMine: msg.senderPubkey == keypair.pubkey,
                            myPubkey: keypair.pubkey,
                            senderProfile: profiles[msg.senderPubkey],
                            parent: parent,
                            parentName: parent.map { displayName(for: $0.senderPubkey) },
                            onReply: { viewModel.replyingTo = msg },
                            onReact: { picked in Task { await viewModel.react(to: msg, picked: picked) } }
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
                    Text("Replying to: \(replyPreview(reply))")
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
                PhotosPicker(selection: $photoItem, matching: .any(of: [.images, .videos])) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.wispPrimary)
                        .padding(.bottom, 8)
                }
                .disabled(viewModel.isSending)

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
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let media = try? await MediaPicker.load(newItem) {
                    await viewModel.sendFile(media)
                    viewModel.refresh()
                }
                photoItem = nil
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

    private func displayName(for pubkey: String) -> String {
        if pubkey == keypair.pubkey { return "You" }
        return profiles[pubkey]?.displayString ?? shortPubkey(pubkey)
    }

    private func replyPreview(_ msg: DmMessage) -> String {
        if msg.isFile { return msg.fileMetadata?.mimeType.hasPrefix("video/") == true ? "Video" : "Photo" }
        return msg.content
    }

    private func shortPubkey(_ hex: String) -> String {
        guard hex.count >= 8 else { return hex }
        return Nip19.shortNpub(hex: hex)
    }
}

struct DmMessageBubbleView: View {
    let message: DmMessage
    let isMine: Bool
    let myPubkey: String
    let senderProfile: ProfileData?
    let parent: DmMessage?
    let parentName: String?
    let onReply: () -> Void
    let onReact: (PickedEmoji) -> Void

    @State private var showActions = false
    @State private var showEmojiLibrary = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMine { Spacer(minLength: 40) }
            if !isMine {
                CachedAvatarView(url: senderProfile?.picture, size: 28)
                    .quickFollowOnLongPress(pubkey: message.senderPubkey)
            }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                bubble
                reactionChips
            }
            .onLongPressGesture { showActions = true }
            .popover(isPresented: $showActions) { actionsPopover }
            .sheet(isPresented: $showEmojiLibrary) {
                EmojiLibrarySheet(mode: .pickForReaction { picked in
                    showEmojiLibrary = false
                    onReact(picked)
                })
            }
            if !isMine { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        .swipeToReply { onReply() }
    }

    @ViewBuilder
    private var bubble: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
            if let parent {
                quotedParent(parent)
            }
            if let meta = message.fileMetadata {
                EncryptedMediaView(metadata: meta, cacheKey: message.rumorId)
            } else {
                Text(message.content)
                    .font(.subheadline)
                    .foregroundStyle(isMine ? Color.white : Color.wispOnSurface)
            }
        }
        .padding(.horizontal, message.fileMetadata == nil ? 12 : 6)
        .padding(.vertical, message.fileMetadata == nil ? 8 : 6)
        .background(
            isMine ? Color.wispPrimary : Color.wispSurfaceVariant,
            in: RoundedRectangle(cornerRadius: 18)
        )
    }

    private func quotedParent(_ parent: DmMessage) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isMine ? Color.white.opacity(0.7) : Color.wispPrimary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(parentName ?? "")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isMine ? Color.white.opacity(0.9) : Color.wispPrimary)
                Text(quotedText(parent))
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(isMine ? Color.white.opacity(0.8) : .secondary)
            }
        }
        .padding(6)
        .frame(maxWidth: 220, alignment: .leading)
        .background(
            (isMine ? Color.white.opacity(0.12) : Color.black.opacity(0.06)),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func quotedText(_ parent: DmMessage) -> String {
        if parent.isFile { return parent.fileMetadata?.mimeType.hasPrefix("video/") == true ? "Video" : "Photo" }
        return parent.content
    }

    // MARK: - Reactions

    @ViewBuilder
    private var reactionChips: some View {
        let groups = groupedReactions
        if !groups.isEmpty {
            HStack(spacing: 4) {
                ForEach(groups) { g in
                    Button { onReact(picked(for: g)) } label: { chip(g) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func chip(_ g: GroupedReaction) -> some View {
        HStack(spacing: 3) {
            if let url = g.url, g.emoji.hasPrefix(":"), let u = URL(string: url) {
                AsyncImage(url: u) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    Text(g.emoji).font(.system(size: 12))
                }
                .frame(width: 16, height: 16)
            } else {
                Text(g.emoji).font(.system(size: 14))
            }
            if g.count > 1 {
                Text("\(g.count)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            g.mine ? Color.wispPrimary.opacity(0.18) : Color.wispSurfaceVariant,
            in: Capsule()
        )
        .overlay(
            Capsule().strokeBorder(g.mine ? Color.wispPrimary.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    private struct GroupedReaction: Identifiable {
        let id: String
        var emoji: String { id }
        let url: String?
        let count: Int
        let mine: Bool
    }

    private var groupedReactions: [GroupedReaction] {
        var order: [String] = []
        var url: [String: String?] = [:]
        var count: [String: Int] = [:]
        var mine: [String: Bool] = [:]
        for r in message.reactions {
            if count[r.emoji] == nil { order.append(r.emoji); url[r.emoji] = r.emojiUrl }
            count[r.emoji, default: 0] += 1
            if r.authorPubkey == myPubkey { mine[r.emoji] = true }
            if url[r.emoji] == nil || url[r.emoji] == .some(nil) { url[r.emoji] = r.emojiUrl }
        }
        return order.map { GroupedReaction(id: $0, url: url[$0] ?? nil, count: count[$0] ?? 1, mine: mine[$0] ?? false) }
    }

    private func picked(for g: GroupedReaction) -> PickedEmoji {
        if g.emoji.hasPrefix(":"), g.emoji.hasSuffix(":"), let url = g.url {
            return .custom(shortcode: String(g.emoji.dropFirst().dropLast()), url: url)
        }
        return .unicode(g.emoji)
    }

    // MARK: - Actions popover (long-press)

    private var actionsPopover: some View {
        VStack(spacing: 0) {
            EmojiReactionPicker(
                onSelect: { picked in showActions = false; onReact(picked) },
                onPlus: { showActions = false; showEmojiLibrary = true }
            )
            Divider()
            actionRow("Reply", systemImage: "arrowshape.turn.up.left") {
                showActions = false
                onReply()
            }
            if !message.isFile && !message.content.isEmpty {
                Divider()
                actionRow("Copy", systemImage: "doc.on.doc") {
                    showActions = false
                    UIPasteboard.general.string = message.content
                }
            }
        }
        .presentationCompactAdaptation(.popover)
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}
