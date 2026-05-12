import SwiftUI

/// Reports the intrinsic body height of a post card up to the
/// `naturalContentHeight` state. Defined as a `max` reducer so a tall
/// child (an image grid, a quoted-note image) wins over a short sibling
/// when the body holds multiple groups.
private struct PostBodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct PostCardView: View {
    let event: NostrEvent
    let profile: ProfileData?
    let profiles: [String: ProfileData]
    var engagement: EngagementCounts? = nil
    /// When true, tapping the card body toggles the expanded details panel
    /// instead of navigating. Used by ThreadView reply rows so taps don't push
    /// a redundant ThreadRoute that just resolves back to the same thread root.
    var expandOnTap: Bool = false
    /// When true, render a tightened ancestor variant: small avatar, no action bar,
    /// no media expansion, no inner profile NavigationLink. Used by ThreadView for
    /// the chain of parent posts above the focal so the outer ThreadRoute link
    /// owns every tap on the card.
    var ancestorCompact: Bool = false
    /// When true, the timestamp in the header renders as a full date/time
    /// ("Mar 5, 2026 · 8:52 PM") instead of a relative offset. Used by
    /// ThreadView's focal row to flag it as the canonical post for the screen.
    var useAbsoluteTimestamp: Bool = false
    /// When set, overrides every other reply-count source for the action-bar
    /// chat bubble. ThreadView passes the focal's non-blocked direct-reply
    /// count so the bubble matches the visible REPLIES list — without it
    /// the engagement repo / network total would still show blocked authors.
    var forcedReplyCount: Int? = nil
    var onProfileTap: ((String) -> Void)? = nil
    var onNoteTap: ((String) -> Void)? = nil
    var onHashtagTap: ((String) -> Void)? = nil
    @Environment(WalletStore.self) private var walletStore: WalletStore?
    @Environment(AppSettings.self) private var settings
    @State private var expanded = false
    @State private var contentExpanded = false
    /// Largest intrinsic height we've observed for the body content.
    /// Latched (only grows) so the cap stays applied once the post is
    /// known to overflow, even if a sub-pixel relayout reports a slightly
    /// smaller value on a subsequent pass. Drives the "Show more" toggle
    /// — text-only posts trigger via the char-count heuristic, anything
    /// that *renders* taller than `longPostCollapsedHeight` (tall image,
    /// quoted note with media, image grid, etc.) triggers via this.
    @State private var naturalContentHeight: CGFloat = 0
    @State private var showReactionPicker = false
    @State private var showEmojiLibrary = false
    /// Cached global frame of the heart button, used to flip the popover
    /// arrow edge so the picker never opens off-screen. When the heart sits
    /// in the lower half of the screen the popover anchors above it
    /// (`arrowEdge: .bottom`); otherwise it anchors below (`.top`).
    @State private var heartButtonFrame: CGRect = .zero
    @State private var reactionArrowEdge: Edge = .top
    @State private var showDeleteConfirm = false
    @State private var showMuteUserConfirm = false
    /// True when the user tapped Zap but no wallet is configured. Surfaces a
    /// confirmation prompt that can launch the Wallet tab to set one up.
    @State private var showWalletSetupPrompt = false
    /// Cached pubkey + display name of the user about to be muted, captured
    /// when the menu item is tapped so the confirmation dialog has stable
    /// values to render and act on regardless of whether the underlying
    /// PostCardView re-renders during the dialog.
    @State private var muteCandidate: MuteCandidate?
    @State private var actionAlert: ActionAlert?

    private struct MuteCandidate: Equatable {
        let pubkey: String
        let displayName: String
    }
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
    @State private var zapStore = ZapAnimationStore.shared

    /// Height at which a post body is collapsed. ~66% of screen height gives
    /// enough context without dominating the feed.
    private static var longPostCollapsedHeight: CGFloat {
        UIScreen.main.bounds.height * 0.66
    }
    /// Minimum overflow required before "Show more" appears. Posts that
    /// exceed the collapsed cap by less than this render at full height
    /// instead of being clipped for a trivial amount of hidden content.
    /// ~5 lines of body text — meaningful enough to be worth a tap.
    private static let longPostMinOverflow: CGFloat = 72

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
    private var iZapped: Bool {
        guard let me = myPubkey else { return false }
        if repoBox.counts.zappers.contains(where: { $0.pubkey == me }) { return true }
        return engagement?.zappers.contains(where: { $0.pubkey == me }) == true
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
            // align with the avatar. In ancestor-compact mode the inner profile
            // links are dropped so the outer ThreadRoute link owns every tap.
            HStack(alignment: .top, spacing: 12) {
                if ancestorCompact {
                    CachedAvatarView(url: displayProfile?.picture, size: 24)
                } else {
                    NavigationLink(value: ProfileRoute(pubkey: displayEvent.pubkey)) {
                        avatar(picture: displayProfile?.picture)
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Group {
                            if ancestorCompact {
                                EmojiText(
                                    displayProfile?.displayString ?? npubShort(displayEvent.pubkey),
                                    emojiMap: displayProfile?.emojiMap ?? [:],
                                    textStyle: .subheadline,
                                    weight: .semibold,
                                    color: .label,
                                    lineLimit: 1
                                )
                            } else {
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
                            }
                        }

                        Spacer(minLength: 0)

                        let powBits = Nip13.verifyDifficulty(displayEvent)
                        if powBits >= 16 {
                            PowBadge(bits: powBits)
                        }

                        Text(useAbsoluteTimestamp
                             ? absoluteTimestamp(displayEvent.createdAt)
                             : relativeTime(from: displayEvent.createdAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !ancestorCompact, let nip05 = displayProfile?.nip05, !nip05.isEmpty {
                        Nip05Badge(nip05: nip05, pubkey: displayEvent.pubkey)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Post body — full card width, not indented under the avatar. Lets
            // long text breathe and gives the media gallery room to bleed off
            // the screen's right edge. Matches the Android client's layout.
            // Ancestor-compact mode still uses RichContentView (so npub
            // mentions resolve and inline images render) but caps the body
            // height with clipping and drops polls, top-zapper, and the
            // action bar. Tap callbacks are nil because the outer
            // NavigationLink owns the row-level tap.
            if ancestorCompact {
                // No height cap: the cap forced `.aspectRatio(.fit)` images to
                // shrink, which left InlineImageView's clipShape rounding the
                // empty parent frame instead of the image edges. Render at
                // natural size so corner rounding actually shows.
                RichContentView(
                    content: displayEvent.content,
                    tags: displayEvent.tags,
                    profiles: profiles,
                    authorPubkey: displayEvent.pubkey,
                    onProfileTap: nil,
                    onNoteTap: nil,
                    onHashtagTap: nil
                )
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 12)
            } else {
            VStack(alignment: .leading, spacing: 8) {
                if !displayEvent.content.isEmpty || !displayEvent.tags.isEmpty {
                    let cap = Self.longPostCollapsedHeight
                    let isLong = naturalContentHeight > cap + Self.longPostMinOverflow
                    let collapsed = isLong && !contentExpanded
                    VStack(alignment: .leading, spacing: 6) {
                        RichContentView(
                            content: displayEvent.content,
                            tags: displayEvent.tags,
                            profiles: profiles,
                            authorPubkey: displayEvent.pubkey,
                            onProfileTap: onProfileTap,
                            onNoteTap: onNoteTap,
                            onHashtagTap: onHashtagTap,
                            linksEnabled: true
                        )
                        // `.fixedSize(vertical: true)` so inline media render
                        // at their natural intrinsic height (parent_width ÷
                        // aspect) instead of getting scaled down by the
                        // parent's `maxHeight` constraint. The outer
                        // `.frame(maxHeight:)` + `.clipped()` then crops
                        // anything past the threshold rather than shrinking
                        // a portrait video into an unreadable thumbnail.
                        .fixedSize(horizontal: false, vertical: true)
                        // Measure the intrinsic body height *before* the
                        // maxHeight cap is applied. With `.fixedSize` upstream,
                        // the inner content keeps its full intrinsic size even
                        // when the outer frame is capped — so the GeometryReader
                        // here reports e.g. 1000pt for a tall quoted-note image
                        // post, even while the outer `.frame(maxHeight:)` clips
                        // visible drawing to 615pt. Latching to the largest
                        // observed value avoids feedback loops from sub-pixel
                        // relayout passes.
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(key: PostBodyHeightKey.self, value: proxy.size.height)
                            }
                        )
                        .frame(
                            maxHeight: collapsed ? cap : .infinity,
                            alignment: .top
                        )
                        .clipped()
                        .onPreferenceChange(PostBodyHeightKey.self) { h in
                            if h > naturalContentHeight + 0.5 {
                                naturalContentHeight = h
                            }
                        }
                        // Pin the hit-test area to the clipped rectangle.
                        // `.clipped()` clips drawing but NOT taps, so a
                        // tile (or any other inner Button) that overflows
                        // past the height cap still receives taps in its
                        // natural frame — including the y range where the
                        // action bar sits below this body. Without this
                        // tapping the heart icon on a collapsed
                        // gallery-overflowing post would open the gallery
                        // fullscreen instead.
                        .contentShape(Rectangle())
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
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(Color.wispSurfaceVariant.opacity(0.6), in: Capsule())
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 4)
                        }
                    }
                }

                if displayEvent.kind == Nip88.kindPoll || displayEvent.kind == Nip69.kindZapPoll {
                    PollSection(
                        pollEvent: displayEvent,
                        onCastVote: { optionIds in handleCastVote(displayEvent, optionIds: optionIds) },
                        onZapVote: { idx in
                            zapPollOptionIndex = idx
                            triggerZapOrWalletSetup()
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
                        quoters: repoBox.counts.quoters.isEmpty ? (engagement?.quoters ?? []) : repoBox.counts.quoters,
                        relays: combinedRelays(for: displayEvent.id),
                        tags: displayEvent.tags,
                        createdAt: displayEvent.createdAt,
                        profiles: profiles,
                        onProfileTap: onProfileTap,
                        onNoteTap: onNoteTap
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
        }
        .contentShape(Rectangle())
        .modifier(TapToExpand(enabled: expandOnTap && !ancestorCompact, expanded: $expanded))
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
        .confirmationDialog(
            muteCandidate.map { "Mute \($0.displayName)?" } ?? "Mute this user?",
            isPresented: $showMuteUserConfirm,
            titleVisibility: .visible
        ) {
            Button("Mute", role: .destructive) {
                if let pk = muteCandidate?.pubkey {
                    MuteRepository.shared.blockUser(pk)
                }
                muteCandidate = nil
            }
            Button("Cancel", role: .cancel) { muteCandidate = nil }
        } message: {
            Text("Their posts will be hidden from your feed and replaced with a placeholder in threads.")
        }
        .confirmationDialog(
            settings.fiatModeEnabled ? "Set up a wallet to send money" : "Set up a wallet to send zaps",
            isPresented: $showWalletSetupPrompt,
            titleVisibility: .visible
        ) {
            Button("Set Up Wallet") {
                NotificationCenter.default.post(name: .openWalletTab, object: nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(settings.fiatModeEnabled
                 ? "Connect a Lightning wallet (Spark or NWC) from the Wallet tab to send money."
                 : "Connect a Lightning wallet (Spark or NWC) from the Wallet tab to send zaps.")
        }
        .alert(item: $actionAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        // Hoist a zap failure into the existing single-alert binding. We clear
        // the store entry as soon as we read it so the alert doesn't re-fire
        // on subsequent renders of the same value.
        .onChange(of: zapStore.errors[displayEventId]) { _, message in
            guard let message else { return }
            actionAlert = ActionAlert(title: "Zap Failed", message: message)
            zapStore.clearError(eventId: displayEventId)
        }
    }

    // MARK: - Repost Banner

    /// "Reposted by …" header, ported from the Android app. Pulls the
    /// aggregated reposter list out of `EngagementBox.counts.reposters`
    /// (populated by `EngagementRepository`'s engagement subscription
    /// against the inner kind-1 id) and stacks up to 5 overlapping
    /// avatars with a count-aware label.
    private var repostBanner: some View {
        // Seed the wrapper's pubkey so the row paints with at least one
        // avatar before the engagement query returns. The wrapper itself
        // is one of the reposters, so this isn't optimistic — it's just
        // making the local truth visible on first frame.
        let wrapperPubkey = event.pubkey
        let aggregated = repoBox.counts.reposters
        // Wrapper-first ordering so the avatar we always have a profile
        // for shows up leftmost. The aggregated list may not include
        // the wrapper yet on the first frame.
        var ordered: [String] = [wrapperPubkey]
        for pk in aggregated where pk != wrapperPubkey {
            ordered.append(pk)
        }
        let maxAvatars = 5
        let visible = Array(ordered.prefix(maxAvatars))
        let total = ordered.count
        let firstName: String? = profiles[wrapperPubkey]?.displayString
            ?? profile?.displayString
        let label: String = {
            if total <= 1 {
                return "\(firstName ?? "Someone") reposted"
            } else if let firstName {
                return "\(firstName) and \(total - 1) others reposted"
            } else {
                return "\(total) people reposted"
            }
        }()
        let avatarSize: CGFloat = 18
        let stackOffset: CGFloat = 12  // 6pt overlap between adjacent 18pt circles

        return HStack(spacing: 6) {
            Image(systemName: "arrow.2.squarepath")
                .font(.system(size: 12, weight: .semibold))
            ZStack(alignment: .leading) {
                ForEach(Array(visible.enumerated()), id: \.offset) { index, pk in
                    NavigationLink(value: ProfileRoute(pubkey: pk)) {
                        CachedAvatarView(url: profiles[pk]?.picture, size: avatarSize)
                            .overlay(
                                Circle().stroke(Color.wispBackground, lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .offset(x: CGFloat(index) * stackOffset)
                }
            }
            // Reserve the stacked-row width: leftmost avatar at 0, each next
            // shifted by `stackOffset`, plus the trailing avatar's full size.
            .frame(
                width: visible.isEmpty
                    ? 0
                    : CGFloat(visible.count - 1) * stackOffset + avatarSize,
                height: avatarSize,
                alignment: .leading
            )
            Text(label)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .onAppear {
            engagementRepo.seedReposter(eventId: displayEventId, reposterPubkey: wrapperPubkey)
        }
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
                // Display the highest count we know about across the three
                // sources so cold opens get a count from the engagement
                // network query instantly, without waiting for every reply
                // event to stream in. `forcedReplyCount` (the in-thread
                // visible count, blocked-author-aware) wins as more local
                // replies arrive.
                let networkCount = max(repoBox.counts.replies, engagement?.replies ?? 0)
                let replyCount = max(forcedReplyCount ?? 0, networkCount)
                actionItem(
                    icon: "bubble.right",
                    count: replyCount > 0 ? replyCount : nil
                )
            }
            .buttonStyle(.plain)
            Spacer()
            heartAction
            Spacer()
            repostAction
            Spacer()
            zapAction
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

    /// Zap button with the in-flight pulse + success burst overlay. While
    /// `ZapAnimationStore.shared.inFlight` contains this card's event id the
    /// label is replaced by a pulsing bolt and the sats label is hidden
    /// (matches Android `ActionBar.kt:221`). The 160-pt burst overlay is always
    /// mounted (`isActive` toggles the animation) so SwiftUI doesn't have to
    /// race view-creation against the 1.1 s burst window. `.zIndex(1)` lifts
    /// the burst above neighbouring action-bar items so the particles aren't
    /// clipped by sibling Buttons / their own overlays.
    private var zapAction: some View {
        let eventId = displayEventId
        let isFlying = zapStore.inFlight.contains(eventId)
        let isBursting = zapStore.bursting.contains(eventId)
        return Button {
            triggerZapOrWalletSetup()
        } label: {
            ZStack {
                if isFlying {
                    LightningPulseView()
                        .frame(width: 18, height: 18)
                        .frame(height: 28)
                        .foregroundStyle(Color.wispZapColor)
                } else {
                    actionItem(
                        image: settings.zapImage,
                        label: zapLabel(repoBox.counts.zapSats > 0 ? repoBox.counts.zapSats : (engagement?.zapSats ?? 0)),
                        tint: iZapped ? Color.wispZapColor : nil
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isFlying)
        .overlay(alignment: .center) {
            ZapBurstView(isActive: isBursting)
                .frame(width: 160, height: 160)
                .allowsHitTesting(false)
        }
        .zIndex(1)
    }

    private var repostAction: some View {
        let count = resolvedRepostCount
        let tint: Color? = iReposted ? Color.wispRepostColor : nil
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
                    if userMuted {
                        muteRepo.unblockUser(target.pubkey)
                    } else {
                        // Confirmation prompt before muting — direct mute
                        // can collapse the thread the user is reading
                        // (per #69) and is hard to discover how to undo.
                        let displayed = profiles[target.pubkey]?.displayString
                            ?? profile?.displayString
                            ?? Nip19.shortNpub(hex: target.pubkey)
                        muteCandidate = MuteCandidate(pubkey: target.pubkey, displayName: displayed)
                        showMuteUserConfirm = true
                    }
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
                    .frame(width: 18, height: 18)
                    if resolvedReactionCount > 0 {
                        Text(formatCount(resolvedReactionCount))
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

    /// SF Symbol action item. Sizes via `.font(.system(size:))` so each
    /// symbol picks its natural visual weight — `arrow.2.squarepath` and
    /// other wider glyphs were rendering visibly smaller under the prior
    /// `.resizable().scaledToFit().frame(15x15)` because scaledToFit shrunk
    /// the height to keep the aspect ratio.
    private func actionItem(icon: String, count: Int? = nil, label: String? = nil, tint: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .frame(width: 22, height: 17, alignment: .center)
            if let label, !label.isEmpty {
                Text(label).font(.caption)
            } else if let count, count > 0 {
                Text(formatCount(count)).font(.caption)
            }
        }
        .foregroundStyle(tint ?? .secondary)
        .frame(height: 28)
    }

    /// Bitmap-image action item (zap glyph swap, custom emoji reactions).
    /// Keeps the resize/frame path because asset / emoji images don't
    /// participate in the SF Symbol weight system.
    private func actionItem(image: Image, count: Int? = nil, label: String? = nil, tint: Color? = nil) -> some View {
        HStack(spacing: 4) {
            image
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
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
        Nip19.shortNpub(hex: pubkey)
    }

    private func handleCastVote(_ pollEvent: NostrEvent, optionIds: [String]) {
        guard let keypair = NostrKey.load() else { return }
        Task { _ = await PollVoteSender.castVote(pollEvent: pollEvent, optionIds: optionIds, keypair: keypair) }
    }

    /// Open the zap composer if a wallet is configured. Otherwise surface a
    /// confirmation prompt that suggests setting one up — without it the
    /// zap button was a silent no-op (the `.zap` sheet renders nothing
    /// when `walletStore` is unset, leaving the user wondering whether
    /// the tap registered).
    private func triggerZapOrWalletSetup() {
        if let store = walletStore, store.mode != nil {
            activeSheet = .zap
        } else {
            showWalletSetupPrompt = true
        }
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
    let quoters: [Quoter]
    let relays: [String]
    let tags: [[String]]
    let createdAt: Int
    let profiles: [String: ProfileData]
    let onProfileTap: ((String) -> Void)?
    /// Tap on a quote-post avatar navigates to that quote's thread. Wired
    /// from `PostCardView.onNoteTap` — falls back to no-op when nil.
    let onNoteTap: ((String) -> Void)?

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
            if !quoters.isEmpty {
                quotesSection
            }
            if !reactors.isEmpty {
                reactionsSection
            }
            if !relays.isEmpty {
                seenOnSection
            }
            postedAtSection
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

    /// "Quoted by" — NIP-18 quote reposts of this note. Stacked avatars are the
    /// quote-post authors; tapping a row navigates to the quote post itself
    /// (via `onNoteTap`), not the author's profile, because a "find what people
    /// said about this" affordance is the whole point of the section.
    private var quotesSection: some View {
        let unique = Array(NSOrderedSet(array: quoters.sorted { $0.createdAt > $1.createdAt })) as? [Quoter] ?? quoters
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 17))
                .foregroundStyle(Color.wispPrimary)
                .frame(width: 22)
            StackedAvatarRow(
                pubkeys: unique.map(\.pubkey),
                profiles: profiles,
                onProfileTap: { pubkey in
                    guard let quote = unique.first(where: { $0.pubkey == pubkey }) else { return }
                    onNoteTap?(quote.eventId)
                }
            )
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var reactionsSection: some View {
        let grouped = Dictionary(grouping: reactors, by: { $0.emoji })
        // Stable order: count desc, then emoji string asc as a tiebreaker.
        // `Dictionary.keys` iteration is non-deterministic between renders, so
        // ties were reshuffling every time the panel re-evaluated — visible as
        // emoji icons rapidly swapping while avatars streamed in.
        let sortedKeys = grouped.keys.sorted { lhs, rhs in
            let lc = grouped[lhs]?.count ?? 0
            let rc = grouped[rhs]?.count ?? 0
            if lc != rc { return lc > rc }
            return lhs < rhs
        }
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

    private var postedAtSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(absoluteTimestamp(createdAt))
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
        Nip19.shortNpub(hex: pubkey)
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

/// Twitter-style "Mar 5, 2026 · 8:52 PM" — used by ThreadView's focal post.
func absoluteTimestamp(_ timestamp: Int) -> String {
    let date = Date(timeIntervalSince1970: Double(timestamp))
    let dateFmt = DateFormatter()
    dateFmt.dateFormat = "MMM d, yyyy"
    let timeFmt = DateFormatter()
    timeFmt.timeStyle = .short
    return "\(dateFmt.string(from: date)) · \(timeFmt.string(from: date))"
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

