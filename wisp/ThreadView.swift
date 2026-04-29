import SwiftUI

struct ThreadView: View {
    @State private var viewModel: ThreadViewModel
    @State private var showError: Bool = false
    @State private var showHiddenSpam: Bool = false
    @State private var showReplyCompose: Bool = false
    /// True once we've auto-scrolled to the seed event id. Stops the scroll
    /// from re-firing every time the reply tree updates.
    @State private var didScrollToSeed: Bool = false

    init(seedEventId: String, authorHint: String?, keypair: Keypair) {
        _viewModel = State(initialValue: ThreadViewModel(
            seedEventId: seedEventId,
            authorHint: authorHint,
            keypair: keypair
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
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
                            .id(root.id)
                            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                        } else if viewModel.isLoading {
                            loadingHeader
                        }

                        ForEach(viewModel.flat) { row in
                            replyRow(row)
                                .id(row.event.id)
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
                .onChange(of: viewModel.rootEvent?.id) { _, _ in
                    scrollToSeedIfNeeded(proxy: proxy)
                }
                .onChange(of: viewModel.flat.count) { _, _ in
                    scrollToSeedIfNeeded(proxy: proxy)
                }
            }

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
        .sheet(isPresented: $showReplyCompose) {
            if let root = viewModel.rootEvent {
                ComposeView(keypair: viewModel.keypair, mode: .reply(parent: root, root: root))
            }
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
            if row.isBlocked {
                blockedPlaceholder
            } else {
                PostCardView(
                    event: row.event,
                    profile: viewModel.profiles[row.event.pubkey],
                    profiles: viewModel.profiles,
                    engagement: viewModel.engagement[row.event.id],
                    expandOnTap: true,
                    onProfileTap: { _ in },
                    onNoteTap: { _ in },
                    onHashtagTap: { _ in }
                )
            }
        }
    }

    private var blockedPlaceholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "nosign")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            Text("Post from blocked user")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Scrolls the thread to the seed event id (the specific reply / mention
    /// the user navigated from — typically a notification tap). Fires only
    /// once per thread session and only after the seed is actually rendered
    /// in the LazyVStack, so the scroll target exists.
    private func scrollToSeedIfNeeded(proxy: ScrollViewProxy) {
        guard !didScrollToSeed else { return }
        let seed = viewModel.seedEventId
        // Already at the top — the root is the seed, no scroll needed.
        if seed == viewModel.rootId || seed == viewModel.rootEvent?.id {
            didScrollToSeed = true
            return
        }
        // Wait until the seed event has been ingested into the visible tree
        // before trying to scroll, otherwise `proxy.scrollTo` is a no-op.
        let seedRendered = viewModel.flat.contains(where: { $0.event.id == seed })
        guard seedRendered else { return }
        didScrollToSeed = true
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(seed, anchor: .top)
            }
        }
    }

    /// Tap-to-open affordance that hands off to the full ComposeView in `.reply` mode.
    /// Matches the Android pattern — same composer for new posts and replies, so mentions,
    /// emoji, media, polls, hashtags, and the 10-second undo countdown all work uniformly.
    private var composer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
            Button {
                showReplyCompose = true
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
            .disabled(viewModel.rootEvent == nil)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.wispBackground)
    }
}
