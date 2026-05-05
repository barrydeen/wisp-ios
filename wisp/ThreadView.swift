import SwiftUI

struct ThreadView: View {
    @State private var viewModel: ThreadViewModel
    @State private var showError: Bool = false
    @State private var showHiddenSpam: Bool = false
    @State private var showReplyCompose: Bool = false
    @State private var didScrollToFocal: Bool = false

    /// The active tab's NavigationStack path. Mutated directly by smart-pop so a
    /// tap on an ancestor that's already in the back stack pops to it instead of
    /// pushing a duplicate ThreadView for the same eventId.
    @Binding var path: NavigationPath
    /// Side-channel mirror of the eventIds of every ThreadRoute on `path`, in
    /// stack order. Maintained by `.task` (append) + `.onDisappear` (remove-tail)
    /// so smart-pop can compute how many levels to pop.
    @Binding var chain: [String]

    init(seedEventId: String, authorHint: String?, keypair: Keypair,
         path: Binding<NavigationPath>, chain: Binding<[String]>) {
        _viewModel = State(initialValue: ThreadViewModel(
            seedEventId: seedEventId,
            authorHint: authorHint,
            keypair: keypair
        ))
        _path = path
        _chain = chain
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Ancestors — chain from root → focal-1, each tappable to push
                        // a new ThreadView focused on that ancestor. Plain divider
                        // separation between rows; no connector line.
                        if !viewModel.ancestors.isEmpty {
                            ForEach(viewModel.ancestors) { row in
                                ancestorRow(row)
                                    .id(row.id)
                                Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                            }
                        }

                        // Focal — the post this screen is "about". Not tappable;
                        // surrounding dividers + tinted background distinguish it.
                        if let focal = viewModel.focal {
                            focalRow(focal)
                                .id(focal.id)
                        } else if viewModel.isLoading {
                            loadingHeader
                        }

                        // Section header for replies — replaces the previous
                        // "X replies" caption tucked under the focal card.
                        // Hidden when every direct reply is from a blocked
                        // author so the thread reads as no-replies.
                        if viewModel.visibleRepliesCount > 0 {
                            repliesSectionHeader
                        }

                        // Replies — direct children of the focal, each tappable to push.
                        // Blocked rows are dropped entirely (no placeholder) so a
                        // mixed thread doesn't show "Post from blocked user" entries
                        // alongside the visible ones.
                        ForEach(viewModel.replies.filter { !$0.isBlocked }) { row in
                            replyRow(row)
                                .id(row.id)
                            Divider()
                                .overlay(Color.wispSurfaceVariant.opacity(0.3))
                        }

                        if !viewModel.hiddenSpamReplies.isEmpty {
                            hiddenSpamSection
                        }

                        if !viewModel.isLoading
                            && viewModel.visibleRepliesCount == 0
                            && viewModel.focal != nil {
                            emptyState
                        }
                    }
                }
                .refreshable { await viewModel.refresh() }
                .onChange(of: viewModel.focal?.id) { _, _ in scrollToFocalIfNeeded(proxy: proxy) }
                .onChange(of: viewModel.ancestors.count) { _, _ in scrollToFocalIfNeeded(proxy: proxy) }
            }
            composer
        }
        .background(Color.wispBackground)
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Register this thread on the side-channel chain so deeper
            // ThreadViews can smart-pop back to it. The contains-guard keeps
            // duplicate entries out if `.task` re-fires on the same view.
            if !chain.contains(viewModel.seedEventId) {
                chain.append(viewModel.seedEventId)
            }
            await viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
            // Pop our entry off the tail. This handles natural back / swipe-back
            // and the cascading disappears that follow a smart-pop's
            // `path.removeLast(N)`.
            if chain.last == viewModel.seedEventId {
                chain.removeLast()
            }
        }
        .onChange(of: viewModel.errorMessage) { _, new in showError = new != nil }
        .alert("Reply failed", isPresented: $showError, presenting: viewModel.errorMessage) { _ in
            Button("OK") { viewModel.errorMessage = nil }
        } message: { msg in Text(msg) }
        .sheet(isPresented: $showReplyCompose) {
            if let focalEvent = viewModel.focal?.event {
                ComposeView(
                    keypair: viewModel.keypair,
                    mode: .reply(parent: focalEvent, root: viewModel.rootEvent)
                )
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
                        .padding(.leading, 16)
                        .padding(.bottom, 4)
                    }
                    Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
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

    // MARK: - Rows

    @ViewBuilder
    private func ancestorRow(_ row: ThreadRow) -> some View {
        if row.isBlocked {
            blockedPlaceholder
        } else {
            Button {
                navigateToThread(eventId: row.event.id, authorPubkey: row.event.pubkey)
            } label: {
                PostCardView(
                    event: row.event,
                    profile: viewModel.profiles[row.event.pubkey],
                    profiles: viewModel.profiles,
                    engagement: viewModel.engagement[row.event.id],
                    ancestorCompact: true,
                    onProfileTap: { _ in },
                    onNoteTap: { _ in },
                    onHashtagTap: { _ in }
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func focalRow(_ row: ThreadRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
            if row.isBlocked {
                blockedPlaceholder
            } else {
                PostCardView(
                    event: row.event,
                    profile: viewModel.profiles[row.event.pubkey],
                    profiles: viewModel.profiles,
                    engagement: engagement(for: row.event.id),
                    useAbsoluteTimestamp: true,
                    forcedReplyCount: viewModel.visibleRepliesCount,
                    onProfileTap: { _ in },
                    // Tapping a quoted note inside the focal pushes that
                    // note as its own focal, same as tapping a reply row.
                    onNoteTap: { quotedId in
                        navigateToThread(eventId: quotedId, authorPubkey: row.event.pubkey)
                    },
                    onHashtagTap: { _ in }
                )
            }
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
        }
        .background(Color.wispSurfaceVariant.opacity(0.25))
    }

    /// Section header above the replies list. Replaces the previous "X replies"
    /// caption stuffed under the focal card so the boundary between focal and
    /// replies reads as a real section break instead of orphan meta text.
    private var repliesSectionHeader: some View {
        HStack(spacing: 6) {
            Text("REPLIES")
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.secondary)
            Text("\(viewModel.visibleRepliesCount)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func replyRow(_ row: ThreadRow) -> some View {
        if row.isBlocked {
            blockedPlaceholder
        } else {
            // The whole card is the tap target. The action-bar bubble
            // shows the network reply count for this reply — tapping
            // pushes a new ThreadView with this reply as its focal,
            // where those deeper replies are loaded and shown.
            Button {
                navigateToThread(eventId: row.event.id, authorPubkey: row.event.pubkey)
            } label: {
                PostCardView(
                    event: row.event,
                    profile: viewModel.profiles[row.event.pubkey],
                    profiles: viewModel.profiles,
                    engagement: engagement(for: row.event.id),
                    onProfileTap: { _ in },
                    // Tap on an embedded quoted note pushes that note as
                    // its own focal. SwiftUI's nested-Button hit-testing
                    // gives the inner QuotedNoteView's tap area priority,
                    // so this fires before the surrounding row Button.
                    onNoteTap: { quotedId in
                        navigateToThread(eventId: quotedId, authorPubkey: row.event.pubkey)
                    },
                    onHashtagTap: { _ in }
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// Smart-nav: if the tapped event is already on the back stack, pop back
    /// to it (skipping every level above) instead of pushing a duplicate
    /// ThreadView. Tapping the current focal is a no-op. Otherwise push.
    private func navigateToThread(eventId: String, authorPubkey: String) {
        if eventId == viewModel.seedEventId { return }
        if let idx = chain.firstIndex(of: eventId), idx < chain.count - 1 {
            // Pop every level between the current tail and the target's level.
            // Clamp to `path.count` defensively in case the path and chain
            // ever drift out of sync (e.g. profile routes interleaved).
            let popLevels = min(chain.count - idx - 1, path.count)
            path.removeLast(popLevels)
        } else {
            path.append(ThreadRoute(eventId: eventId, authorPubkey: authorPubkey))
        }
    }

    /// Larger of locally-known direct children or the relay engagement count.
    /// Local count surfaces the moment a descendant is in the cache; the
    /// engagement number catches descendants we haven't fetched yet.
    private func effectiveReplyCount(for eventId: String) -> Int {
        let local = viewModel.childCounts[eventId] ?? 0
        let remote = viewModel.engagement[eventId]?.replies ?? 0
        return max(local, remote)
    }

    /// Engagement passed to PostCardView, with `replies` bumped to the
    /// effective count so the action-bar bubble shows a number even before
    /// the engagement subscription returns.
    private func engagement(for eventId: String) -> EngagementCounts? {
        var counts = viewModel.engagement[eventId] ?? EngagementCounts()
        let effective = effectiveReplyCount(for: eventId)
        guard effective > 0 || counts.reactions > 0 || counts.reposts > 0
              || counts.zapSats > 0 || counts.zapCount > 0 else {
            return nil
        }
        counts.replies = effective
        return counts
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

    /// Scroll the focal post to the top once both it and its ancestors have resolved.
    /// Fires once per ThreadView lifetime so the user can scroll up freely afterward.
    private func scrollToFocalIfNeeded(proxy: ScrollViewProxy) {
        guard !didScrollToFocal else { return }
        guard let focalId = viewModel.focal?.id else { return }
        // No ancestors yet AND the focal is the root → nothing to scroll past, mark done.
        if viewModel.ancestors.isEmpty && viewModel.rootId == focalId {
            didScrollToFocal = true
            return
        }
        // Otherwise wait for at least one ancestor to render before scrolling, so the
        // focal lands at the top instead of in the middle of an empty view.
        guard !viewModel.ancestors.isEmpty else { return }
        didScrollToFocal = true
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(focalId, anchor: .top)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
            Button { showReplyCompose = true } label: {
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
            .disabled(viewModel.focal == nil)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.wispBackground)
    }
}
