import SwiftUI

struct ThreadView: View {
    @State private var viewModel: ThreadViewModel
    @State private var replyText: String = ""
    @State private var showError: Bool = false
    @State private var showHiddenSpam: Bool = false
    @State private var showGifPicker: Bool = false
    @State private var gifUploading: Bool = false
    @FocusState private var composerFocused: Bool

    init(seedEventId: String, authorHint: String?, keypair: Keypair) {
        _viewModel = State(initialValue: ThreadViewModel(
            seedEventId: seedEventId,
            authorHint: authorHint,
            keypair: keypair
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let root = viewModel.rootEvent {
                        PostCardView(
                            event: root,
                            profile: viewModel.profiles[root.pubkey],
                            profiles: viewModel.profiles,
                            engagement: viewModel.engagement[root.id],
                            onProfileTap: { _ in },
                            onNoteTap: { _ in },
                            onHashtagTap: { _ in }
                        )
                        Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                    } else if viewModel.isLoading {
                        loadingHeader
                    }

                    ForEach(viewModel.flat) { row in
                        replyRow(row)
                        Divider()
                            .overlay(Color.wispSurfaceVariant.opacity(0.3))
                            .padding(.leading, indent(for: row.depth))
                    }

                    if !viewModel.hiddenSpamReplies.isEmpty {
                        hiddenSpamSection
                    }

                    if !viewModel.isLoading && viewModel.flat.isEmpty && viewModel.rootEvent != nil {
                        emptyState
                    }
                }
            }
            .refreshable { await viewModel.refresh() }

            composer
        }
        .background(Color.wispBackground)
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
        .onChange(of: viewModel.errorMessage) { _, new in
            showError = new != nil
        }
        .alert("Reply failed", isPresented: $showError, presenting: viewModel.errorMessage) { _ in
            Button("OK") { viewModel.errorMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Subviews

    private var loadingHeader: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading thread\u{2026}")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var hiddenSpamSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showHiddenSpam.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showHiddenSpam ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(viewModel.hiddenSpamReplies.count) hidden \(viewModel.hiddenSpamReplies.count == 1 ? "reply" : "replies")")
                        .font(.caption.weight(.medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showHiddenSpam {
                ForEach(viewModel.hiddenSpamReplies) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        replyRow(row)
                        Button("Mark not spam") {
                            viewModel.revealHiddenSpamAuthor(row.event.pubkey)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.wispPrimary)
                        .padding(.leading, indent(for: row.depth) + 16)
                        .padding(.bottom, 4)
                    }
                    Divider()
                        .overlay(Color.wispSurfaceVariant.opacity(0.3))
                        .padding(.leading, indent(for: row.depth))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No replies yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func replyRow(_ row: ThreadRow) -> some View {
        HStack(alignment: .top, spacing: 0) {
            depthGuides(row.depth)
            NavigationLink(value: ThreadRoute(eventId: row.event.id, authorPubkey: row.event.pubkey)) {
                PostCardView(
                    event: row.event,
                    profile: viewModel.profiles[row.event.pubkey],
                    profiles: viewModel.profiles,
                    engagement: viewModel.engagement[row.event.id],
                    onProfileTap: { _ in },
                    onNoteTap: { _ in },
                    onHashtagTap: { _ in }
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func depthGuides(_ depth: Int) -> some View {
        let clamped = min(depth, 8)
        return HStack(spacing: 0) {
            ForEach(0..<clamped, id: \.self) { _ in
                Rectangle()
                    .fill(Color.wispSurfaceVariant.opacity(0.5))
                    .frame(width: 2)
                    .padding(.horizontal, 5)
            }
        }
        .frame(width: indent(for: depth))
    }

    private func indent(for depth: Int) -> CGFloat {
        CGFloat(min(depth, 8)) * 12
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
            HStack(spacing: 8) {
                Button {
                    showGifPicker = true
                } label: {
                    if gifUploading {
                        ProgressView().frame(width: 28, height: 28)
                    } else {
                        Text("GIF")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary, lineWidth: 1.5)
                            )
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Add GIF")
                .disabled(viewModel.isSending || gifUploading)

                TextField("Reply\u{2026}", text: $replyText, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.wispSurfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                    .focused($composerFocused)
                    .disabled(viewModel.isSending)

                if let countdown = viewModel.replyCountdown {
                    Button(role: .destructive) {
                        viewModel.cancelReply()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .foregroundStyle(.secondary)

                    Button {
                        viewModel.publishReplyNow()
                    } label: {
                        Text("Send (\(countdown))")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Color.wispPrimary, in: Capsule())
                            .foregroundStyle(.white)
                    }
                } else {
                    Button {
                        sendReply()
                    } label: {
                        if viewModel.isSending {
                            ProgressView()
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 28, height: 28)
                        }
                    }
                    .disabled(viewModel.isSending || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.rootEvent == nil)
                    .foregroundStyle(Color.wispPrimary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.wispBackground)
        .sheet(isPresented: $showGifPicker) {
            GifPickerView { giphyURL in
                Task { await attachGif(giphyURL) }
            }
        }
    }

    /// Re-host the picked Giphy GIF on the user's Blossom servers, then drop
    /// the resulting URL into the reply text on its own line.
    private func attachGif(_ giphyURL: String) async {
        gifUploading = true
        defer { gifUploading = false }
        var servers = BlossomServerList.cached(for: viewModel.keypair.pubkey)
        if servers.isEmpty {
            servers = [BlossomServerList.defaultServer]
        }
        let outcome = await GifBlossomUploader.rehost(
            giphyURL: giphyURL,
            keypair: viewModel.keypair,
            servers: servers
        )
        if !replyText.isEmpty, !replyText.hasSuffix("\n") { replyText += "\n" }
        replyText += outcome.url
        replyText += "\n"
    }

    private func sendReply() {
        let text = replyText
        viewModel.publishReply(content: text)
        if viewModel.errorMessage == nil && viewModel.replyCountdown != nil {
            replyText = ""
            composerFocused = false
        }
    }
}
