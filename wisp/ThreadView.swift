import SwiftUI

struct ThreadView: View {
    @State private var viewModel: ThreadViewModel
    @State private var showError: Bool = false
    @State private var showHiddenSpam: Bool = false
    @State private var showReplyCompose: Bool = false
    @State private var didScrollToFocal: Bool = false
    @State private var suppressNextDisappearChainRemoval: Bool = false
    /// Hosts keyboard-using sheets (emoji library, reply / quote composer)
    /// at the ThreadView level — outside the `LazyVStack` — so their
    /// presentation isn't recycled when the keyboard shrinks the visible
    /// area and a focal / ancestor / reply row gets re-windowed by the
    /// lazy stack. Tap-time state captures the target event so any row's
    /// action bar can route through a single shared sheet anchor.
    @State private var showEmojiLibrary: Bool = false
    @State private var emojiPickCallback: ((PickedEmoji) -> Void)?
    @State private var pendingReplyTarget: PendingReplyTarget?
    @State private var pendingQuoteTarget: PendingQuoteTarget?
    @Environment(\.dismiss) private var dismiss

    private struct PendingReplyTarget: Identifiable {
        let parent: NostrEvent
        let root: NostrEvent?
        var id: String { parent.id }
    }

    private struct PendingQuoteTarget: Identifiable {
        let event: NostrEvent
        var id: String { event.id }
    }

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
            header
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Ancestors — chain from root → focal-1, each tappable to push
                        // a new ThreadView focused on that ancestor. Plain divider
                        // separation between rows; no connector line.
                        if viewModel.isSearchingAncestors {
                            searchingAncestorRow
                            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                        } else if let missingId = viewModel.missingAncestorId {
                            missingAncestorPlaceholder(eventId: missingId)
                            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                        }
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

                        // Replies — full descendant tree of the focal, rendered
                        // inline with depth-based indentation. Tap still pushes
                        // a focused sub-thread, but it's no longer the only way
                        // to see grandchildren.
                        ForEach(viewModel.nestedReplies) { item in
                            nestedReplyRow(item)
                                .id(item.row.id)
                        }

                        if !viewModel.hiddenSpamReplies.isEmpty {
                            hiddenSpamSection
                        }

                        if !viewModel.isLoading
                            && viewModel.nestedReplies.isEmpty
                            && viewModel.focal != nil {
                            emptyState
                        }
                    }
                }
                .refreshable { await viewModel.refresh() }
                .onChange(of: viewModel.focal?.id) { _, _ in scrollToFocalIfNeeded(proxy: proxy) }
                .onChange(of: viewModel.ancestors.count) { _, _ in scrollToFocalIfNeeded(proxy: proxy) }
            }
            if !viewModel.keypair.isWatchOnly {
                composer
            }
        }
        .background(Color.wispBackground)
        .toolbar(.hidden, for: .navigationBar)
        .swipeBackFromLeftEdge {
            popCurrentThread()
        }
        .onAppear {
            suppressNextDisappearChainRemoval = false
        }
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
            if suppressNextDisappearChainRemoval {
                suppressNextDisappearChainRemoval = false
                return
            }
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
        .sheet(isPresented: $showEmojiLibrary) {
            EmojiLibrarySheet(mode: .pickForReaction { picked in
                emojiPickCallback?(picked)
                emojiPickCallback = nil
                showEmojiLibrary = false
            })
        }
        .sheet(item: $pendingReplyTarget) { target in
            ComposeView(
                keypair: viewModel.keypair,
                mode: .reply(parent: target.parent, root: target.root)
            )
        }
        .sheet(item: $pendingQuoteTarget) { target in
            ComposeView(keypair: viewModel.keypair, mode: .quote(target.event))
        }
    }

    private func openEmojiLibrary(callback: @escaping (PickedEmoji) -> Void) {
        emojiPickCallback = callback
        showEmojiLibrary = true
    }

    private func openReplyCompose(parent: NostrEvent, root: NostrEvent?) {
        pendingReplyTarget = PendingReplyTarget(parent: parent, root: root)
    }

    private func openQuoteCompose(event: NostrEvent) {
        pendingQuoteTarget = PendingQuoteTarget(event: event)
    }

    // MARK: - Subviews

    private var header: some View {
        ZStack {
            Text("Thread")
                .font(.subheadline.weight(.semibold))
            HStack {
                BackChevronButton { dismiss() }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

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
            // See `replyRow` for the rationale on `.onTapGesture` vs a
            // wrapping `Button` — same nested-button hit-test issue on
            // real devices. `onNoteTap` is wired so a quoted note embedded
            // inside an ancestor opens that note's thread; the surrounding
            // row tap still pushes the ancestor itself.
            PostCardView(
                event: row.event,
                profile: viewModel.profiles[row.event.pubkey],
                profiles: viewModel.profiles,
                engagement: viewModel.engagement[row.event.id],
                ancestorCompact: true,
                onProfileTap: { _ in },
                onNoteTap: { quotedId in
                    navigateToThread(eventId: quotedId, authorPubkey: row.event.pubkey)
                },
                onHashtagTap: { _ in },
                onOpenEmojiLibrary: openEmojiLibrary,
                onOpenReplyCompose: openReplyCompose,
                onOpenQuoteCompose: openQuoteCompose
            )
            .contentShape(Rectangle())
            .onTapGesture {
                navigateToThread(eventId: row.event.id, authorPubkey: row.event.pubkey)
            }
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
                    forcedReplyCount: viewModel.visibleRepliesCount,
                    onProfileTap: { pk in push(ProfileRoute(pubkey: pk)) },
                    // Tapping a quoted note inside the focal pushes that
                    // note as its own focal, same as tapping a reply row.
                    onNoteTap: { quotedId in
                        navigateToThread(eventId: quotedId, authorPubkey: row.event.pubkey)
                    },
                    onHashtagTap: { tag in push(HashtagFeedRoute(tag: tag)) },
                    onOpenEmojiLibrary: openEmojiLibrary,
                    onOpenReplyCompose: openReplyCompose,
                    onOpenQuoteCompose: openQuoteCompose
                )
            }
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
        }
        .background(Color.wispSurfaceVariant.opacity(0.25))
    }

    /// Wrap a reply row with depth-based leading indentation. The connector
    /// shape draws both the gutter vertical AND the bottom divider as one
    /// continuous stroke so their line weights match exactly, with a rounded
    /// inside fillet at the bottom-left where they meet. Top-left stays a
    /// sharp continuation of the vertical above.
    @ViewBuilder
    private func nestedReplyRow(_ item: NestedReplyRow) -> some View {
        ZStack(alignment: .leading) {
            ReplyConnectorShape(
                cornerRadius: 8,
                showVertical: item.depth > 0
            )
            .stroke(
                Color.wispSurfaceVariant.opacity(0.5),
                style: StrokeStyle(lineWidth: 1, lineCap: .butt, lineJoin: .round)
            )
            .padding(.leading, item.depth > 0 ? indentationWidth(for: item.depth) - 8 : indentationWidth(for: item.depth))

            replyRow(item.row)
                .padding(.leading, indentationWidth(for: item.depth))
        }
    }

    /// Per-level indent. Smaller step + cap of 5 keeps deep chains readable
    /// on phones without compressing the post body.
    private func indentationWidth(for depth: Int) -> CGFloat {
        CGFloat(min(depth, 5)) * 12
    }

    @ViewBuilder
    private func replyRow(_ row: ThreadRow) -> some View {
        if row.isBlocked {
            blockedPlaceholder
        } else {
            // The whole card is the tap target — tapping pushes a new
            // ThreadView with this reply as its focal. Use
            // `.onTapGesture` rather than a `Button` wrapper so inner
            // action-bar buttons + inline `@mention` link taps hit-test
            // correctly on real devices. With a nested `Button`, real
            // hardware fires both the inner and outer actions on the same
            // touch — the comment icon opened compose AND triggered a
            // push, which then dismissed the compose sheet and caused it
            // to reopen in a tight loop.
            PostCardView(
                event: row.event,
                profile: viewModel.profiles[row.event.pubkey],
                profiles: viewModel.profiles,
                engagement: engagement(for: row.event.id),
                showReplyContext: false,
                onProfileTap: { pk in push(ProfileRoute(pubkey: pk)) },
                // Tap on an embedded quoted note pushes that note as
                // its own focal. SwiftUI's nested-Button hit-testing
                // gives the inner QuotedNoteView's tap area priority,
                // so this fires before the surrounding row tap.
                onNoteTap: { quotedId in
                    navigateToThread(eventId: quotedId, authorPubkey: row.event.pubkey)
                },
                onHashtagTap: { tag in push(HashtagFeedRoute(tag: tag)) },
                onOpenEmojiLibrary: openEmojiLibrary,
                onOpenReplyCompose: openReplyCompose,
                onOpenQuoteCompose: openQuoteCompose
            )
            .contentShape(Rectangle())
            .onTapGesture {
                navigateToThread(eventId: row.event.id, authorPubkey: row.event.pubkey)
            }
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
            let threadPopLevels = chain.count - idx - 1
            if threadPopLevels > 0 {
                chain.removeLast(threadPopLevels)
            }
            let popLevels = min(threadPopLevels, path.count)
            path.removeLast(popLevels)
        } else {
            chain.append(eventId)
            push(ThreadRoute(eventId: eventId, authorPubkey: authorPubkey))
        }
    }

    private func push<Route: Hashable>(_ route: Route) {
        suppressNextDisappearChainRemoval = true
        path.append(route)
    }

    private func popCurrentThread() {
        if chain.last == viewModel.seedEventId {
            chain.removeLast()
        } else if let idx = chain.lastIndex(of: viewModel.seedEventId) {
            chain.removeSubrange(idx..<chain.endIndex)
        }

        if path.count > 0 {
            path.removeLast()
        } else {
            dismiss()
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

    private var searchingAncestorRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.secondary)
                .scaleEffect(0.8)
            Text("Looking for parent note…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func missingAncestorPlaceholder(eventId: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Note not found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("The parent note could not be loaded")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                viewModel.retryMissingAncestor()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
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

/// Connector + bottom divider for a nested reply row, drawn as one
/// continuous stroke so the line weights match. Top-left is sharp
/// (the vertical continues from the previous row); bottom-left is
/// a rounded inside fillet where the vertical meets the horizontal.
/// At the root depth, only the horizontal divider is drawn.
private struct ReplyConnectorShape: Shape {
    var cornerRadius: CGFloat = 8
    var showVertical: Bool = true

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if showVertical {
            // Continuous vertical down the gutter, full row height. Adjacent
            // rows' verticals butt together for a seamless chain.
            path.move(to: CGPoint(x: 1, y: 0))
            path.addLine(to: CGPoint(x: 1, y: rect.height - cornerRadius))
            // Rounded inside fillet from vertical → horizontal.
            path.addQuadCurve(
                to: CGPoint(x: 1 + cornerRadius, y: rect.height),
                control: CGPoint(x: 1, y: rect.height)
            )
            // Horizontal across to the right edge.
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        } else {
            // Just the horizontal divider — used at the root depth where
            // there's no parent column to connect to.
            path.move(to: CGPoint(x: 0, y: rect.height))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        }
        return path
    }
}
