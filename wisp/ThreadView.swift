import SwiftUI

struct ThreadView: View {
    @State private var viewModel: ThreadViewModel
    @State private var showError: Bool = false
    @State private var showHiddenSpam: Bool = false
    /// Focal reply bar at the bottom of the thread. This composer is presented
    /// from ThreadView's own root (a sibling of the `LazyVStack`, not a row
    /// inside it), so it's already stable. Per-card reply / quote / emoji-react
    /// instead route through the app-level `ComposePresenter` in the
    /// environment (injected at `MainView`'s root).
    @State private var showReplyCompose: Bool = false
    @State private var suppressNextDisappearChainRemoval: Bool = false
    @Environment(\.dismiss) private var dismiss

    /// The active tab's NavigationStack path. Mutated directly by smart-pop so a
    /// tap on an ancestor that's already in the back stack pops to it instead of
    /// pushing a duplicate ThreadView for the same eventId.
    @Binding var path: NavigationPath
    /// Side-channel mirror of the eventIds of every ThreadRoute on `path`, in
    /// stack order. Maintained by `.task` (append) + `.onDisappear` (remove-tail)
    /// so smart-pop can compute how many levels to pop.
    @Binding var chain: [String]

    init(seedEventId: String, authorHint: String?, keypair: Keypair,
         path: Binding<NavigationPath>, chain: Binding<[String]>,
         scrollToId: String? = nil) {
        _viewModel = State(initialValue: ThreadViewModel(
            seedEventId: seedEventId,
            authorHint: authorHint,
            keypair: keypair,
            scrollToId: scrollToId
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
                        } else if viewModel.isLoading && viewModel.nestedReplies.isEmpty {
                            // On a cold deep-link the focal (now the conversation
                            // root) may not be cached yet; don't float a spinner
                            // above an already-populated tree — the tapped note
                            // already renders (and highlights) as a row below.
                            loadingHeader
                        }

                        // Replies — full descendant tree of the focal, rendered
                        // inline with depth-based indentation. Tap still pushes
                        // a focused sub-thread, but it's no longer the only way
                        // to see grandchildren.
                        ForEach(groupedNestedReplies) { item in
                            switch item {
                            case .single(let row):
                                nestedReplyRow(row).id(row.id)
                            case .wotGroup(let count, let depth, _):
                                nestedWotGroupRow(count: count, depth: depth)
                            }
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
                .onChange(of: viewModel.scrollTargetId) { _, targetId in
                    guard let targetId else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(targetId, anchor: .center)
                    }
                    viewModel.scrollTargetId = nil
                }
                .onChange(of: viewModel.highlightId) { _, newId in
                    guard let newId else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1500))
                        // Same-id guard: don't let an old timer clear a newer flash.
                        if viewModel.highlightId == newId {
                            withAnimation(.easeOut(duration: 0.4)) { viewModel.highlightId = nil }
                        }
                    }
                }
                // Stable thread layout while sheets presented from a
                // PostCardView row raise the keyboard — see
                // NoteListFeedView for the full rationale. The reply
                // `composer` below is a sibling, so it still dodges the
                // keyboard normally.
                .ignoresSafeArea(.keyboard, edges: .bottom)
            }
            if !viewModel.keypair.isWatchOnly {
                composer
            }
        }
        .background(Color.wispBackground)
        .wispTopHeader { header }
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
            // Reply to the note the user opened the thread on, not the re-rooted
            // focal (which is now the conversation root).
            if let parent = viewModel.composerDefaultParent ?? viewModel.focal?.event {
                ComposeView(
                    keypair: viewModel.keypair,
                    mode: .reply(parent: parent, root: viewModel.rootEvent)
                )
            }
        }
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
            Image("NoReplies")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .foregroundStyle(.tertiary)
            Text("No replies yet")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Rows

    @ViewBuilder
    private func ancestorRow(_ row: ThreadRow) -> some View {
        if row.isBlocked {
            blockedPlaceholder
        } else if row.isWotHidden {
            wotHiddenPlaceholder
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
                isPrivate: row.isPrivate,
                onProfileTap: { _ in },
                onNoteTap: { quotedId in
                    navigateToThread(eventId: quotedId, authorPubkey: row.event.pubkey)
                },
                onHashtagTap: { _ in }
            )
            // Gate row re-renders: the thread's `engagement` dict mutates per
            // inbound reaction/zap/reply, which re-evaluates ThreadView.body.
            // Without `==`, every visible row re-ran its full body each tick.
            // PostCardView's `==` re-renders only the row whose engagement /
            // profile actually changed — same as the feed.
            .equatable()
            .contentShape(Rectangle())
            // Ancestors are empty after re-root (focal == root), so this is
            // effectively unreachable; kept consistent with reply rows —
            // scroll in place rather than push.
            .onTapGesture {
                viewModel.scrollTargetId = row.event.id
                viewModel.highlightId = row.event.id
            }
        }
    }

    @ViewBuilder
    private func focalRow(_ row: ThreadRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
            if row.isBlocked {
                blockedPlaceholder
            } else if row.isWotHidden {
                wotHiddenPlaceholder
            } else {
                PostCardView(
                    event: row.event,
                    profile: viewModel.profiles[row.event.pubkey],
                    profiles: viewModel.profiles,
                    engagement: engagement(for: row.event.id),
                    forcedReplyCount: viewModel.visibleRepliesCount,
                    isPrivate: row.isPrivate,
                    onProfileTap: { pk in push(ProfileRoute(pubkey: pk)) },
                    // Tapping a quoted note inside the focal pushes that
                    // note as its own focal, same as tapping a reply row.
                    onNoteTap: { quotedId in
                        navigateToThread(eventId: quotedId, authorPubkey: row.event.pubkey)
                    },
                    onHashtagTap: { tag in push(HashtagFeedRoute(tag: tag)) }
                )
                .equatable()
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
        // Brief highlight of the note the user came from (or an in-place tap
        // target). Applied on the row CONTAINER — outside the `.equatable()`
        // PostCardView — so PostCardView's `==` re-render gate is untouched.
        // The animation value MUST be the per-row Bool, not the optional, or
        // every visible row would animate on any highlight change.
        .background(viewModel.highlightId == item.row.id ? Color.wispPrimary.opacity(0.14) : Color.clear)
        .animation(.easeInOut(duration: 0.3), value: viewModel.highlightId == item.row.id)
    }

    @ViewBuilder
    private func nestedWotGroupRow(count: Int, depth: Int) -> some View {
        ZStack(alignment: .leading) {
            ReplyConnectorShape(cornerRadius: 8, showVertical: depth > 0)
                .stroke(
                    Color.wispSurfaceVariant.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1, lineCap: .butt, lineJoin: .round)
                )
                .padding(.leading, depth > 0 ? indentationWidth(for: depth) - 8 : indentationWidth(for: depth))
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                Text(count == 1 ? "Post hidden by WoT filter" : "\(count) posts hidden by WoT filter")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, indentationWidth(for: depth))
        }
    }

    /// Per-level indent. Smaller step + cap of 5 keeps deep chains readable
    /// on phones without compressing the post body.
    private func indentationWidth(for depth: Int) -> CGFloat {
        CGFloat(min(depth, 5)) * 12
    }

    private enum NestedReplyDisplayItem: Identifiable {
        case single(NestedReplyRow)
        case wotGroup(count: Int, depth: Int, id: String)
        var id: String {
            switch self {
            case .single(let r): return r.id
            case .wotGroup(_, _, let gid): return "wot-\(gid)"
            }
        }
    }

    private var groupedNestedReplies: [NestedReplyDisplayItem] {
        var result: [NestedReplyDisplayItem] = []
        let items = viewModel.nestedReplies
        var i = 0
        while i < items.count {
            let item = items[i]
            if item.row.isWotHidden {
                let groupDepth = item.depth
                let groupId = item.id
                var count = 1
                var j = i + 1
                while j < items.count && items[j].row.isWotHidden && items[j].depth == groupDepth {
                    count += 1
                    j += 1
                }
                result.append(.wotGroup(count: count, depth: groupDepth, id: groupId))
                i = j
            } else {
                result.append(.single(item))
                i += 1
            }
        }
        return result
    }

    @ViewBuilder
    private func replyRow(_ row: ThreadRow) -> some View {
        if row.isBlocked {
            blockedPlaceholder
        } else if row.isWotHidden {
            // Replies normally drop outright before reaching a row; this only
            // renders if a WoT-hidden id slips into a slice (belt-and-
            // suspenders — never show the content either way).
            wotHiddenPlaceholder
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
                isPrivate: row.isPrivate,
                onProfileTap: { pk in push(ProfileRoute(pubkey: pk)) },
                // Tap on an embedded quoted note pushes that note as
                // its own focal. SwiftUI's nested-Button hit-testing
                // gives the inner QuotedNoteView's tap area priority,
                // so this fires before the surrounding row tap.
                onNoteTap: { quotedId in
                    navigateToThread(eventId: quotedId, authorPubkey: row.event.pubkey)
                },
                onHashtagTap: { tag in push(HashtagFeedRoute(tag: tag)) }
            )
            .equatable()
            .contentShape(Rectangle())
            // Tap a reply row to scroll to it in place + flash it — the whole
            // conversation is already on screen, so we never push a sub-thread.
            // (Embedded quoted-note taps above still push: different conversation.)
            .onTapGesture {
                viewModel.scrollTargetId = row.event.id
                viewModel.highlightId = row.event.id
            }
        }
    }

    /// Smart-nav for opening a DIFFERENT conversation (an embedded quoted note).
    /// Reply/ancestor ROW taps no longer call this — they scroll in place — so
    /// this is now reached only from quoted-note `onNoteTap` closures.
    /// If the tapped event is already on the back stack, pop back to it (skipping
    /// every level above) instead of pushing a duplicate ThreadView. Tapping the
    /// current focal is a no-op. Otherwise push.
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
              || counts.zapSats > 0 || counts.zapCount > 0
              || !counts.quoters.isEmpty else {
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

    /// Structural stand-in for a root/focal/ancestor the Web-of-Trust filter
    /// hides. Deliberately renders NOTHING from the event — no content, no
    /// author, no media, and no reveal affordance — the filter gates
    /// potentially graphic content, so the placeholder only preserves the
    /// thread's shape.
    private var wotHiddenPlaceholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            Text("Hidden by Web of Trust filter")
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

    private var composer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
            Button { showReplyCompose = true } label: {
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
            .disabled(viewModel.composerDefaultParent == nil)
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
