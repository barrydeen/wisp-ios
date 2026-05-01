import SwiftUI

struct PostCardView: View {
    let event: NostrEvent
    let profile: ProfileData?
    let profiles: [String: ProfileData]
    var engagement: EngagementCounts? = nil
    /// When true, tapping the card body toggles the expanded details panel
    /// instead of navigating. Used by ThreadView reply rows so taps don't push
    /// a redundant ThreadRoute that just resolves back to the same thread root.
    var expandOnTap: Bool = false
    var onProfileTap: ((String) -> Void)? = nil
    var onNoteTap: ((String) -> Void)? = nil
    var onHashtagTap: ((String) -> Void)? = nil
    @Environment(WalletStore.self) private var walletStore: WalletStore?
    @State private var expanded = false
    @State private var contentExpanded = false
    @State private var showReactionPicker = false
    @State private var showEmojiLibrary = false
    /// Cached global frame of the heart button, used to flip the popover
    /// arrow edge so the picker never opens off-screen. When the heart sits
    /// in the lower half of the screen the popover anchors above it
    /// (`arrowEdge: .bottom`); otherwise it anchors below (`.top`).
    @State private var heartButtonFrame: CGRect = .zero
    @State private var reactionArrowEdge: Edge = .top
    @State private var showDeleteConfirm = false
    @State private var actionAlert: ActionAlert?
    /// Single source of truth for every body-level sheet on the card. Stacking
    /// multiple `.sheet(isPresented:)` modifiers on the same view is a known
    /// SwiftUI antipattern that loops on real devices — a sheet's `dismiss()`
    /// races with sibling presentations and the binding flips back, repeatedly
    /// reopening the just-published reply / zap. One `.sheet(item:)` keyed on
    /// this enum sidesteps the conflict.
    @State private var activeSheet: ActiveSheet?

    private enum ActiveSheet: Identifiable {
        case zap
        case addToList
        case quoteCompose
        case replyCompose

        var id: Int {
            switch self {
            case .zap: return 0
            case .addToList: return 1
            case .quoteCompose: return 2
            case .replyCompose: return 3
            }
        }
    }
    @State private var zapPollOptionIndex: Int? = nil
    @State private var noteListRepo = NoteListRepository.shared
    @State private var sourceTracker = NoteSourceTracker.shared
    @State private var engagementRepo = EngagementRepository.shared

    /// Threshold above which a kind-1 body gets a "Show more" toggle. Tuned for
    /// roughly the height of a 12-line post — anything longer dominates the feed.
    private static let longPostCharThreshold = 600
    private static let longPostCollapsedHeight: CGFloat = 280

    private struct ActionAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private var myPubkey: String? { NostrKey.load()?.pubkey }

    /// Event id reactions and reposts target — the inner note for kind-6
    /// reposts, otherwise the post's own id.
    private var displayEventId: String { resolveRepost().event.id }

    /// Per-event observable box. Accessing this creates a SwiftUI tracking dependency
    /// only on this card's box, not on the entire EngagementRepository dict.
    private var repoBox: EngagementBox { engagementRepo.box(for: displayEventId) }

    private var myReactor: Reactor? {
        guard let me = myPubkey else { return nil }
        // Read the shared repo first so optimistic reactions reflect immediately.
        if let mine = repoBox.counts.reactors.first(where: { $0.pubkey == me }) {
            return mine
        }
        return engagement?.reactors.first(where: { $0.pubkey == me })
    }
    private var iReactedEmoji: String? { myReactor?.emoji }
    private var iReposted: Bool {
        guard let me = myPubkey else { return false }
        if repoBox.counts.reposters.contains(me) { return true }
        return engagement?.reposters.contains(me) == true
    }

    /// Engagement counts merged across the parent-passed `engagement` and the
    /// shared optimistic state in `EngagementRepository`. Keeps reaction /
    /// repost counters in sync with `iReactedEmoji` / `iReposted` so the
    /// number bumps the moment the user reacts in any view, not just the feed.
    private var resolvedReactionCount: Int {
        max(engagement?.reactions ?? 0, repoBox.counts.reactions)
    }
    private var resolvedRepostCount: Int {
        max(engagement?.reposts ?? 0, repoBox.counts.reposts)
    }
    /// The user's reacted emoji as a displayable Unicode character, or nil for shortcode
    /// reactions (which the heart action renders as an inline image instead) or no
    /// reaction. Maps the legacy NIP-25 `+` / empty content to ❤️.
    private var displayReactedEmoji: String? {
        guard let raw = iReactedEmoji else { return nil }
        if raw == "+" || raw.isEmpty { return "\u{2764}\u{FE0F}" }
        if raw.hasPrefix(":") && raw.hasSuffix(":") && raw.count > 2 { return nil }
        return raw
    }
    /// `(shortcode, url)` for the user's reaction when it's a NIP-30 custom emoji and
    /// the reactor included the matching `["emoji", shortcode, url]` tag.
    private var displayReactedCustomEmoji: (shortcode: String, url: String)? {
        guard let raw = iReactedEmoji,
              raw.hasPrefix(":"), raw.hasSuffix(":"), raw.count > 2,
              let url = myReactor?.customEmojiUrl else { return nil }
        return (String(raw.dropFirst().dropLast()), url)
    }

    var body: some View {
        let resolved = resolveRepost()
        let displayEvent = resolved.event
        let displayProfile = resolved.profile

        VStack(alignment: .leading, spacing: 0) {
            if resolved.isRepost {
                repostBanner
            }

            // Header row — avatar + name + nip05 + badges/time. Indented to
            // align with the avatar.
            HStack(alignment: .top, spacing: 12) {
                NavigationLink(value: ProfileRoute(pubkey: displayEvent.pubkey)) {
                    avatar(picture: displayProfile?.picture)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        NavigationLink(value: ProfileRoute(pubkey: displayEvent.pubkey)) {
                            EmojiText(
                                displayProfile?.displayString ?? npubShort(displayEvent.pubkey),
                                emojiMap: displayProfile?.emojiMap ?? [:],
                                textStyle: .subheadline,
                                weight: .semibold,
                                color: .label,
                                lineLimit: 1
                            )
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 0)

                        let powBits = Nip13.verifyDifficulty(displayEvent)
                        if powBits >= 16 {
                            PowBadge(bits: powBits)
                        }

                        Text(relativeTime(from: displayEvent.createdAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let nip05 = displayProfile?.nip05, !nip05.isEmpty {
                        Nip05Badge(nip05: nip05, pubkey: displayEvent.pubkey)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Post body — full card width, not indented under the avatar. Lets
            // long text breathe and gives the media gallery room to bleed off
            // the screen's right edge. Matches the Android client's layout.
            VStack(alignment: .leading, spacing: 8) {
                if !displayEvent.content.isEmpty || !displayEvent.tags.isEmpty {
                    let isLong = displayEvent.content.count > Self.longPostCharThreshold
                    let collapsed = isLong && !contentExpanded
                    VStack(alignment: .leading, spacing: 6) {
                        RichContentView(
                            content: displayEvent.content,
                            tags: displayEvent.tags,
                            profiles: profiles,
                            onProfileTap: onProfileTap,
                            onNoteTap: onNoteTap,
                            onHashtagTap: onHashtagTap
                        )
                        .frame(
                            maxHeight: collapsed ? Self.longPostCollapsedHeight : .infinity,
                            alignment: .top
                        )
                        .clipped()
                        .overlay(alignment: .bottom) {
                            if collapsed {
                                LinearGradient(
                                    colors: [Color.wispBackground.opacity(0), Color.wispBackground],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: 48)
                                .allowsHitTesting(false)
                            }
                        }
                        if isLong {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    contentExpanded.toggle()
                                }
                            } label: {
                                Text(contentExpanded ? "Show less" : "Show more")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.wispPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if displayEvent.kind == Nip88.kindPoll || displayEvent.kind == Nip69.kindZapPoll {
                    PollSection(
                        pollEvent: displayEvent,
                        onCastVote: { optionIds in handleCastVote(displayEvent, optionIds: optionIds) },
                        onZapVote: { idx in
                            zapPollOptionIndex = idx
                            activeSheet = .zap
                        }
                    )
                }

                if let topZapper = engagement?.zappers.max(by: { $0.sats < $1.sats }) {
                    TopZapperPill(
                        zapper: topZapper,
                        profile: profiles[topZapper.pubkey]
                    ) {
                        onProfileTap?(topZapper.pubkey)
                    }
                }

                actionBar

                if expanded {
                    NoteDetailsPanel(
                        zappers: repoBox.counts.zappers.isEmpty ? (engagement?.zappers ?? []) : repoBox.counts.zappers,
                        reactors: repoBox.counts.reactors.isEmpty ? (engagement?.reactors ?? []) : repoBox.counts.reactors,
                        reposters: repoBox.counts.reposters.isEmpty ? (engagement?.reposters ?? []) : repoBox.counts.reposters,
                        relays: combinedRelays(for: displayEvent.id),
                        tags: displayEvent.tags,
                        profiles: profiles,
                        onProfileTap: onProfileTap
                    )
                    // Pure fade — the prior `.move(edge: .top)` made the
                    // top-of-panel content (the reactor avatar row) settle
                    // into place before the rows below caught up, so the
                    // expansion read as two staggered animations instead of
                    // one card revealing.
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .contentShape(Rectangle())
        .modifier(TapToExpand(enabled: expandOnTap, expanded: $expanded))
        .onAppear {
            let displayed = resolveRepost().event
            if displayed.kind == Nip88.kindPoll || displayed.kind == Nip69.kindZapPoll {
                PollTallyRepository.shared.markVisible(pollEvent: displayed)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .zap:
                if let store = walletStore {
                    let target = resolveRepost().event
                    let targetProfile = resolveRepost().profile
                    let extraTags: [[String]] = zapPollOptionIndex.map { [["poll_option", String($0)]] } ?? []
                    let pollOptionIdx = zapPollOptionIndex
                    ZapSheet(
                        store: store,
                        recipientPubkey: target.pubkey,
                        recipientLud16: targetProfile?.lud16,
                        recipientName: targetProfile?.displayString,
                        eventId: target.id,
                        extraTags: extraTags,
                        onSuccess: { sats in
                            if target.kind == Nip69.kindZapPoll, let idx = pollOptionIdx,
                               let me = NostrKey.load() {
                                PollTallyRepository.shared.applyOptimisticZapVote(
                                    pollEvent: target,
                                    optionIndex: idx,
                                    voterPubkey: me.pubkey,
                                    sats: sats,
                                    ts: Int(Date().timeIntervalSince1970)
                                )
                            }
                        },
                        dismiss: {
                            activeSheet = nil
                            zapPollOptionIndex = nil
                        }
                    )
                }
            case .addToList:
                if let keypair = NostrKey.load() {
                    NavigationStack {
                        AddToNoteListSheet(keypair: keypair, event: resolveRepost().event)
                    }
                }
            case .quoteCompose:
                if let keypair = NostrKey.load() {
                    ComposeView(keypair: keypair, mode: .quote(resolveRepost().event))
                }
            case .replyCompose:
                if let keypair = NostrKey.load() {
                    let target = resolveRepost().event
                    ComposeView(keypair: keypair, mode: .reply(parent: target, root: replyRootStub(for: target)))
                }
            }
        }
        .confirmationDialog(
            "Delete this note?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteNote(resolveRepost().event)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Publishes a NIP-09 deletion request. Relays may keep their copy.")
        }
        .alert(item: $actionAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    // MARK: - Repost Banner

    private var repostBanner: some View {
        HStack(spacing: 6) {
            CachedAvatarView(url: profile?.picture, size: 16)
            Image(systemName: "arrow.2.squarepath")
                .font(.system(size: 12))
            Text("\(profile?.displayString ?? "Someone") reposted")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 16)
        .padding(.top, 8)
    }

    // MARK: - Avatar

    private func avatar(picture: String?) -> some View {
        CachedAvatarView(url: picture, size: 40)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 0) {
            Button {
                activeSheet = .replyCompose
            } label: {
                actionItem(icon: "bubble.right", count: repoBox.counts.replies > 0 ? repoBox.counts.replies : engagement?.replies)
            }
            .buttonStyle(.plain)
            Spacer()
            heartAction
            Spacer()
            repostAction
            Spacer()
            Button {
                activeSheet = .zap
            } label: {
                actionItem(
                    icon: "bolt.fill",
                    label: zapLabel(repoBox.counts.zapSats > 0 ? repoBox.counts.zapSats : (engagement?.zapSats ?? 0)),
                    tint: (repoBox.counts.zapSats > 0 || (engagement?.zapSats ?? 0) > 0) ? Color.wispZapColor : nil
                )
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                activeSheet = .addToList
            } label: {
                let target = resolveRepost().event
                let isBookmarked = !noteListRepo.listsContaining(noteId: target.id).isEmpty
                actionItem(
                    icon: isBookmarked ? "bookmark.fill" : "bookmark",
                    count: nil,
                    tint: isBookmarked ? Color.wispPrimary : nil
                )
            }
            .buttonStyle(.plain)
            Spacer()
            overflowMenu
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.secondary)
    }

    private var repostAction: some View {
        let count = resolvedRepostCount
        let tint: Color? = iReposted ? Color.wispRepostColor : (count > 0 ? Color.wispRepostColor : nil)
        return Menu {
            Button {
                sendRepost()
            } label: {
                Label(iReposted ? "Reposted" : "Repost", systemImage: "arrow.2.squarepath")
            }
            .disabled(iReposted)

            Button {
                activeSheet = .quoteCompose
            } label: {
                Label("Quote", systemImage: "quote.bubble")
            }
        } label: {
            actionItem(icon: "arrow.2.squarepath", count: count > 0 ? count : nil, tint: tint)
        }
        .menuStyle(.borderlessButton)
    }

    private var overflowMenu: some View {
        let target = resolveRepost().event
        let isMine = (myPubkey != nil) && (myPubkey == target.pubkey)
        let shareItem = shareURI(for: target)
        let threadRoot = Nip10.rootId(of: target) ?? target.id
        let muteRepo = MuteRepository.shared
        let userMuted = muteRepo.isBlocked(target.pubkey)
        let threadMuted = muteRepo.isThreadMuted(threadRoot)

        return Menu {
            Button {
                activeSheet = .addToList
            } label: {
                Label("Add to List", systemImage: "bookmark")
            }

            if isMine {
                Button {
                    pinNote(target)
                } label: {
                    Label("Pin to Profile", systemImage: "pin")
                }
            }

            if !isMine {
                Button {
                    if userMuted { muteRepo.unblockUser(target.pubkey) } else { muteRepo.blockUser(target.pubkey) }
                } label: {
                    Label(userMuted ? "Unmute User" : "Mute User", systemImage: "speaker.slash")
                }

                Button {
                    if threadMuted { muteRepo.unmuteThread(threadRoot) } else { muteRepo.muteThread(threadRoot) }
                } label: {
                    Label(threadMuted ? "Unmute Thread" : "Mute Thread", systemImage: "bell.slash")
                }
            }

            ShareLink(item: shareItem) {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            Button {
                copyNoteId(target)
            } label: {
                Label("Copy Note ID", systemImage: "doc.on.doc")
            }

            Button {
                copyNoteJson(target)
            } label: {
                Label("Copy Note JSON", systemImage: "curlybraces")
            }

            Button {
                copyNpub(target)
            } label: {
                Label("Copy npub", systemImage: "person.text.rectangle")
            }

            Button {
                broadcast(target)
            } label: {
                Label("Broadcast", systemImage: "antenna.radiowaves.left.and.right")
            }

            if isMine {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15))
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .tint(.secondary)
    }

    private var heartAction: some View {
        let displayed = displayReactedEmoji
        let custom = displayReactedCustomEmoji
        return Button {
            // Flip the popover above the heart when it sits below the
            // vertical midpoint of the screen — keeps the picker on-screen
            // for posts near the bottom of the feed (or in modal sheets where
            // the action bar is closer to the bottom edge).
            let screenHeight = UIScreen.main.bounds.height
            reactionArrowEdge = heartButtonFrame.midY > screenHeight * 0.5 ? .bottom : .top
            showReactionPicker = true
        } label: {
            if let emoji = displayed {
                HStack(spacing: 4) {
                    Text(emoji)
                        .font(.system(size: 16))
                    if resolvedReactionCount > 0 {
                        Text(formatCount(resolvedReactionCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 28)
            } else if let custom {
                HStack(spacing: 4) {
                    EmojiText(
                        ":\(custom.shortcode):",
                        emojiMap: [custom.shortcode: custom.url],
                        textStyle: .body,
                        lineLimit: 1
                    )
                    .frame(height: 18)
                    if let count = engagement?.reactions, count > 0 {
                        Text(formatCount(count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 28)
            } else {
                actionItem(
                    icon: iReactedEmoji != nil ? "heart.fill" : "heart",
                    count: resolvedReactionCount > 0 ? resolvedReactionCount : nil,
                    tint: iReactedEmoji != nil ? .pink : nil
                )
            }
        }
        .buttonStyle(.plain)
        // Capture the heart button's global frame on first appearance only.
        // Reading it on every scroll-frame `onChange` writes to `@State` and
        // triggers a re-render of every visible PostCardView — devastating
        // for scroll smoothness. The cached frame is good enough for the
        // popover's binary above-or-below decision.
        .background(
            GeometryReader { geo in
                Color.clear.onAppear {
                    if heartButtonFrame == .zero {
                        heartButtonFrame = geo.frame(in: .global)
                    }
                }
            }
        )
        .popover(isPresented: $showReactionPicker, arrowEdge: reactionArrowEdge) {
            EmojiReactionPicker(
                onSelect: { picked in
                    showReactionPicker = false
                    sendReaction(picked)
                },
                onPlus: {
                    showReactionPicker = false
                    showEmojiLibrary = true
                }
            )
            .presentationCompactAdaptation(.popover)
        }
        .sheet(isPresented: $showEmojiLibrary) {
            EmojiLibrarySheet(mode: .pickForReaction { picked in
                showEmojiLibrary = false
                sendReaction(picked)
            })
        }
    }

    private func sendReaction(_ picked: PickedEmoji) {
        guard let keypair = NostrKey.load() else { return }
        let target = resolveRepost().event
        NSLog("[Reaction] sendReaction picked=%@ targetId=%@", picked.frequencyKey, target.id.prefix(8) as CVarArg)
        Task {
            do {
                try await ReactionSender.shared.react(to: target, keypair: keypair, picked: picked)
                Haptics.shared.blip()
                NSLog("[Reaction] react succeeded")
            } catch {
                NSLog("[Reaction] react failed: %@", String(describing: error))
            }
        }
    }

    private func sendRepost() {
        guard let keypair = NostrKey.load() else { return }
        let target = resolveRepost().event
        Task {
            do {
                try await RepostSender.shared.repost(target, keypair: keypair)
            } catch RepostSender.SendError.alreadyReposted {
                // No-op: button is also disabled in this state.
            } catch {
                actionAlert = ActionAlert(title: "Repost failed", message: String(describing: error))
            }
        }
    }

    private func pinNote(_ target: NostrEvent) {
        guard let keypair = NostrKey.load() else { return }
        Task {
            do {
                _ = try await PinNoteSender.shared.setPinned(noteId: target.id, pinned: true, keypair: keypair)
                actionAlert = ActionAlert(title: "Pinned", message: "Added to your profile pins.")
            } catch {
                actionAlert = ActionAlert(title: "Pin failed", message: String(describing: error))
            }
        }
    }

    private func deleteNote(_ target: NostrEvent) {
        guard let keypair = NostrKey.load() else { return }
        Task {
            do {
                try await DeletionSender.shared.delete(target, keypair: keypair)
                actionAlert = ActionAlert(title: "Delete request sent", message: "Relays may take a moment to honor it.")
            } catch {
                actionAlert = ActionAlert(title: "Delete failed", message: String(describing: error))
            }
        }
    }

    private func broadcast(_ target: NostrEvent) {
        guard let me = myPubkey else { return }
        Task {
            let writes = await RelayListRepository.shared.getWriteRelays(me)
            var set = Set(writes)
            if let board = RelayScoreBoard.load(pubkey: me) {
                for entry in board.scoredRelays.prefix(5) { set.insert(entry.url) }
            }
            if set.isEmpty {
                set = ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
            }
            let succeeded = await RelayPool.publish(event: target, to: Array(set), timeout: 8)
            actionAlert = ActionAlert(
                title: succeeded.isEmpty ? "Broadcast failed" : "Broadcasted",
                message: succeeded.isEmpty
                    ? "No relays accepted the event."
                    : "Re-published to \(succeeded.count) relay\(succeeded.count == 1 ? "" : "s")."
            )
        }
    }

    private func copyNoteId(_ target: NostrEvent) {
        guard let bytes = Hex.decode(target.id),
              let bech = Nip19.noteEncode(eventId: Array(bytes)) else { return }
        UIPasteboard.general.string = bech
    }

    private func copyNpub(_ target: NostrEvent) {
        guard let bytes = Hex.decode(target.pubkey),
              let bech = Nip19.npubEncode(pubkey: Array(bytes)) else { return }
        UIPasteboard.general.string = bech
    }

    private func copyNoteJson(_ target: NostrEvent) {
        UIPasteboard.general.string = target.toJSON()
    }

    /// Resolve the thread root for a reply to `target`. If `target` is itself a reply,
    /// build a minimal stub event for its NIP-10 `root` so ComposeView can emit a proper
    /// `["e", root, "", "root"]` tag. If `target` is the root, return `target` directly.
    private func replyRootStub(for target: NostrEvent) -> NostrEvent? {
        guard let rootId = Nip10.rootId(of: target), rootId != target.id else {
            return target
        }
        return NostrEvent(
            id: rootId, pubkey: "", kind: 1,
            createdAt: 0, tags: [], content: "", sig: ""
        )
    }

    private func shareURI(for target: NostrEvent) -> String {
        let relays = Array(NoteSourceTracker.shared.relays(for: target.id).prefix(2))
        guard let idBytes = Hex.decode(target.id),
              let authorBytes = Hex.decode(target.pubkey),
              let nevent = Nip19.neventEncode(eventId32: Array(idBytes), relays: relays, author32: Array(authorBytes))
        else {
            return "https://wisp.talk/thread/\(target.id)"
        }
        return "https://wisp.talk/thread/\(nevent)"
    }

    private func combinedRelays(for eventId: String) -> [String] {
        var seenHosts = Set<String>()
        var ordered: [String] = []
        let raw = (engagement?.seenRelays ?? []).union(sourceTracker.relays(for: eventId))
        for url in raw {
            let host = (URL(string: url)?.host ?? url).lowercased()
            if seenHosts.insert(host).inserted { ordered.append(url) }
        }
        return ordered.sorted { ($0.lowercased()) < ($1.lowercased()) }
    }

    private func actionItem(icon: String, count: Int? = nil, label: String? = nil, tint: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 15))
            if let label, !label.isEmpty {
                Text(label).font(.caption)
            } else if let count, count > 0 {
                Text(formatCount(count)).font(.caption)
            }
        }
        .foregroundStyle(tint ?? .secondary)
        .frame(height: 28)
    }

    private func zapLabel(_ sats: Int64?) -> String? {
        guard let sats, sats > 0 else { return nil }
        return CurrencyFormatter.short(sats: sats)
    }

    private func formatCount(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: String(format: "%.1fk", Double(n) / 1_000)
        default: "\(n)"
        }
    }

    // MARK: - Helpers

    private struct ResolvedPost {
        let event: NostrEvent
        let profile: ProfileData?
        let isRepost: Bool
    }

    /// Process-wide cache for the JSON-parsed inner event of kind-6 reposts.
    /// `resolveRepost()` is called many times per render (once in `body`, plus
    /// indirectly via every computed property that reads `displayEventId`,
    /// `myReactor`, `iReposted`, the action bar, the share menu, etc.). Re-
    /// parsing the event JSON on each call is a measurable scroll-frame cost
    /// in long threads. Event ids are immutable so caching is safe.
    private final class InnerEventBox {
        let event: NostrEvent
        init(_ event: NostrEvent) { self.event = event }
    }
    private static let innerEventCache: NSCache<NSString, InnerEventBox> = {
        let cache = NSCache<NSString, InnerEventBox>()
        cache.countLimit = 256
        return cache
    }()

    private func resolveRepost() -> ResolvedPost {
        if event.kind == 6, !event.content.isEmpty {
            let key = event.id as NSString
            let inner: NostrEvent? = {
                if let box = Self.innerEventCache.object(forKey: key) { return box.event }
                guard let data = event.content.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let parsed = NostrEvent(json: json)
                else { return nil }
                Self.innerEventCache.setObject(InnerEventBox(parsed), forKey: key)
                return parsed
            }()
            if let inner {
                return ResolvedPost(
                    event: inner,
                    profile: profiles[inner.pubkey] ?? ProfileRepository.shared.get(inner.pubkey),
                    isRepost: true
                )
            }
        }
        return ResolvedPost(
            event: event,
            profile: profile ?? ProfileRepository.shared.get(event.pubkey),
            isRepost: false
        )
    }

    private func npubShort(_ pubkey: String) -> String {
        String(pubkey.prefix(8)) + "\u{2026}"
    }

    private func handleCastVote(_ pollEvent: NostrEvent, optionIds: [String]) {
        guard let keypair = NostrKey.load() else { return }
        Task { _ = await PollVoteSender.castVote(pollEvent: pollEvent, optionIds: optionIds, keypair: keypair) }
    }
}

// MARK: - Tap-to-Expand Modifier

private struct TapToExpand: ViewModifier {
    let enabled: Bool
    @Binding var expanded: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            }
        } else {
            content
        }
    }
}

// MARK: - Top Zapper Pill

private struct TopZapperPill: View {
    let zapper: Zapper
    let profile: ProfileData?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                CachedAvatarView(url: profile?.picture, size: 18)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11))
                Text(CurrencyFormatter.short(sats: zapper.sats))
                    .font(.caption2.weight(.semibold))
                if !zapper.message.isEmpty {
                    Text(zapper.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(
                Capsule().stroke(Color.wispZapColor.opacity(0.3), lineWidth: 1)
            )
            .foregroundStyle(Color.wispZapColor)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Note Details Panel

private struct NoteDetailsPanel: View {
    let zappers: [Zapper]
    let reactors: [Reactor]
    let reposters: [String]
    let relays: [String]
    let tags: [[String]]
    let profiles: [String: ProfileData]
    let onProfileTap: ((String) -> Void)?

    @State private var relaysExpanded = false

    private static let relayChipLimit = 6

    private var clientName: String? {
        guard let tag = tags.first(where: { $0.count >= 2 && $0[0] == "client" }) else { return nil }
        let value = tag[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !zappers.isEmpty {
                zapsSection
            }
            if !reposters.isEmpty {
                repostsSection
            }
            if !reactors.isEmpty {
                reactionsSection
            }
            if !relays.isEmpty {
                seenOnSection
            }
            if let name = clientName {
                postedViaSection(name: name)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var zapsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(zappers.sorted(by: { $0.sats > $1.sats }), id: \.self) { zap in
                let zapProfile = profiles[zap.pubkey] ?? ProfileRepository.shared.get(zap.pubkey)
                Button {
                    onProfileTap?(zap.pubkey)
                } label: {
                    HStack(spacing: 8) {
                        CachedAvatarView(url: zapProfile?.picture, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            let label = !zap.message.isEmpty
                                ? zap.message
                                : (zapProfile?.displayString ?? short(zap.pubkey))
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 3) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 11))
                            Text(CurrencyFormatter.short(sats: zap.sats))
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(Color.wispZapColor)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var repostsSection: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.2.squarepath")
                .font(.system(size: 14))
                .foregroundStyle(Color.wispRepostColor)
                .frame(width: 22)
            StackedAvatarRow(
                pubkeys: reposters,
                profiles: profiles,
                onProfileTap: onProfileTap
            )
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var reactionsSection: some View {
        let grouped = Dictionary(grouping: reactors, by: { $0.emoji })
        let sortedKeys = grouped.keys.sorted { (grouped[$0]?.count ?? 0) > (grouped[$1]?.count ?? 0) }
        // Build a per-reaction emoji map so each row resolves its own shortcode against the
        // URL the reactor included in their kind-7 NIP-30 `emoji` tag. Falls back to the
        // local user's emoji set for shortcodes the reactor didn't tag (rare).
        let localMap = EmojiRepository.shared.resolvedCustomMap
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(sortedKeys, id: \.self) { emoji in
                let group = grouped[emoji] ?? []
                let reactionMap = perReactionEmojiMap(for: group, fallback: localMap)
                HStack(alignment: .center, spacing: 8) {
                    EmojiText(
                        displayEmoji(emoji),
                        emojiMap: reactionMap,
                        textStyle: .body,
                        lineLimit: 1
                    )
                    .frame(width: 22)
                    StackedAvatarRow(
                        pubkeys: group.map(\.pubkey),
                        profiles: profiles,
                        onProfileTap: onProfileTap
                    )
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func perReactionEmojiMap(for group: [Reactor], fallback: [String: String]) -> [String: String] {
        var map = fallback
        for reactor in group {
            guard let url = reactor.customEmojiUrl,
                  reactor.emoji.hasPrefix(":"), reactor.emoji.hasSuffix(":"), reactor.emoji.count > 2
            else { continue }
            let shortcode = String(reactor.emoji.dropFirst().dropLast())
            map[shortcode] = url
        }
        return map
    }

    private var seenOnSection: some View {
        let hosts = relays.map { hostname(of: $0) }
        let limit = Self.relayChipLimit
        let visible = (relaysExpanded || hosts.count <= limit) ? hosts : Array(hosts.prefix(limit))
        let hidden = max(0, hosts.count - visible.count)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Seen on")
                .font(.caption2)
                .foregroundStyle(.secondary)
            FlowingChips(items: visible)
            if hidden > 0 || (relaysExpanded && hosts.count > limit) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { relaysExpanded.toggle() }
                } label: {
                    Text(relaysExpanded ? "Show less" : "+\(hidden) more")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.wispPrimary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    private func postedViaSection(name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "app.badge")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Posted via \(name)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func displayEmoji(_ raw: String) -> String {
        switch raw {
        case "+", "": return "❤️"
        case "-": return "👎"
        default: return raw
        }
    }

    private func short(_ pubkey: String) -> String {
        String(pubkey.prefix(8)) + "\u{2026}"
    }

    private func hostname(of relay: String) -> String {
        URL(string: relay)?.host ?? relay
    }
}

// MARK: - Stacked Avatars

private struct StackedAvatarRow: View {
    let pubkeys: [String]
    let profiles: [String: ProfileData]
    let onProfileTap: ((String) -> Void)?
    var max: Int = 5
    var size: CGFloat = 24
    var overlap: CGFloat = 10

    var body: some View {
        let visible = Array(pubkeys.prefix(max))
        let extra = pubkeys.count - visible.count
        HStack(spacing: -overlap) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, pk in
                let picture = profiles[pk]?.picture ?? ProfileRepository.shared.get(pk)?.picture
                Button {
                    onProfileTap?(pk)
                } label: {
                    CachedAvatarView(url: picture, size: size)
                        .overlay(
                            Circle().stroke(Color.wispBackground, lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, overlap + 4)
            }
        }
    }
}

// MARK: - Simple wrapping row of small text chips (for relay hostnames)

private struct FlowingChips: View {
    let items: [String]

    var body: some View {
        ChipFlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.15))
                    )
                    .lineLimit(1)
            }
        }
    }
}

private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        // Mirror `placeSubviews` exactly: `lineWidth` always carries the trailing spacing
        // after each chip, so the wrap check `lineWidth + size > maxWidth` matches the
        // placement-time check `x + size > maxX`. Earlier this used a different formula
        // here vs. in placement, so the reported height was one row short and any
        // following sibling (e.g. the "Show less" button) overlapped the last chip.
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if lineWidth + size.width > maxWidth, lineWidth > 0 {
                totalHeight += lineHeight + lineSpacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        totalHeight += lineHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : lineWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

func relativeTime(from timestamp: Int) -> String {
    let seconds = Int(Date().timeIntervalSince1970) - timestamp
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return "\(seconds / 3600)h" }
    if seconds < 604_800 { return "\(seconds / 86400)d" }
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))
}

