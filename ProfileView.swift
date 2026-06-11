import SwiftUI

struct ProfileView: View {
    let pubkey: String
    let activeUserPubkey: String
    /// Optional closures the owning NavigationStack supplies so taps inside the
    /// bio (npub mentions, nostr:nevent quotes, #hashtags) push the right
    /// destination onto the local path. Nil = no navigation on tap.
    var onProfileTap: ((String) -> Void)? = nil
    var onNoteTap: ((String) -> Void)? = nil
    var onHashtagTap: ((String) -> Void)? = nil
    /// The owning NavigationStack's path. When provided, the swipe-back gesture
    /// removes the last entry directly (same pattern as ThreadView) so the
    /// NavigationStack doesn't replay its own slide on top of the custom animation.
    var path: Binding<NavigationPath>? = nil

    @State private var viewModel: ProfileViewModel
    @State private var selectedTab: ProfileTab = .notes
    @State private var showAddToList = false
    @State private var showQrSheet = false
    @State private var showEditProfile = false
    @State private var muteRepo = MuteRepository.shared
    @Environment(\.dismiss) private var dismiss

    init(
        pubkey: String,
        activeUserPubkey: String,
        onProfileTap: ((String) -> Void)? = nil,
        onNoteTap: ((String) -> Void)? = nil,
        onHashtagTap: ((String) -> Void)? = nil,
        path: Binding<NavigationPath>? = nil
    ) {
        self.pubkey = pubkey
        self.activeUserPubkey = activeUserPubkey
        self.onProfileTap = onProfileTap
        self.onNoteTap = onNoteTap
        self.onHashtagTap = onHashtagTap
        self.path = path
        _viewModel = State(initialValue: ProfileViewModel(pubkey: pubkey, activeUserPubkey: activeUserPubkey))
    }

    private var isMe: Bool { pubkey == activeUserPubkey }
    /// The "Conversation" tab shows the public back-and-forth between the
    /// active user and this profile — meaningless on the own profile, so it's
    /// dropped from the tab strip there.
    private var visibleTabs: [ProfileTab] {
        isMe ? ProfileTab.allCases.filter { $0 != .conversation } : ProfileTab.allCases
    }
    private var shareURL: String { "https://wisp.talk/profile/\(pubkey)" }
    private var npub: String? {
        guard let bytes = Hex.decode(pubkey) else { return nil }
        return Nip19.npubEncode(pubkey: Array(bytes))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ProfileHeaderView(
                    viewModel: viewModel,
                    isMe: isMe,
                    isWatchOnly: NostrKey.isWatchOnly(pubkey: activeUserPubkey),
                    onEditProfile: { showEditProfile = true },
                    onProfileTap: onProfileTap,
                    onNoteTap: onNoteTap,
                    onHashtagTap: onHashtagTap
                )
                Section {
                    sortRow
                    tabBody
                } header: {
                    ProfileTabBar(selected: $selectedTab, tabs: visibleTabs)
                        .background(Color.wispBackground.opacity(0.92))
                }
            }
        }
        // The back-button / username row is attached as a top safe-area inset
        // rather than stacked above the ScrollView, so the scroll content
        // (banner photo, notes) slides *underneath* it. That gives the header
        // the exact same translucent treatment as the pinned tab strip below
        // it: both composite the same `wispBackground.opacity(0.92)` over the
        // scrolling photos, so there is no opacity seam between the two bars.
        // The pinned tab bar still anchors directly below this inset.
        .safeAreaInset(edge: .top, spacing: 0) {
            unifiedHeader
        }
        .coordinateSpace(name: "profileScroll")
        .background(Color.wispBackground)
        .toolbar(.hidden, for: .navigationBar)
        .swipeBackFromLeftEdge {
            if let p = path, p.wrappedValue.count > 0 {
                p.wrappedValue.removeLast()
            } else {
                dismiss()
            }
        }
        .sheet(isPresented: $showAddToList) {
            if let keypair = NostrKey.load() {
                NavigationStack {
                    AddProfileToListSheet(keypair: keypair, targetPubkey: pubkey)
                }
            }
        }
        .sheet(isPresented: $showQrSheet) {
            ProfileQrSheet(
                pubkey: pubkey,
                displayName: viewModel.profile?.displayString ?? shortKey(pubkey),
                avatarUrl: viewModel.profile?.picture,
                lud16: viewModel.profile?.lud16,
                clinkOffer: viewModel.profile?.clinkOffer
            )
        }
        .sheet(isPresented: $showEditProfile) {
            if let keypair = NostrKey.load() {
                NavigationStack {
                    ProfileEditView(keypair: keypair) { updated in
                        viewModel.profile = updated
                        viewModel.profiles[updated.pubkey] = updated
                    }
                }
            }
        }
        .task { await viewModel.start() }
        .task(id: selectedTab) {
            await viewModel.loadTab(selectedTab)
        }
    }

    private var unifiedHeader: some View {
        HStack(spacing: 8) {
            BackChevronButton { dismiss() }

            Spacer(minLength: 0)

            EmojiText(
                viewModel.profile?.displayString ?? shortKey(pubkey),
                emojiMap: viewModel.profile?.emojiMap ?? [:],
                textStyle: .subheadline,
                weight: .semibold,
                color: .label,
                lineLimit: 1
            )

            Spacer(minLength: 0)

            Button {
                showQrSheet = true
            } label: {
                Image(systemName: "qrcode")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.wispOnSurface)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }

            Menu {
                ShareLink(item: shareURL) {
                    Label("Share Profile", systemImage: "square.and.arrow.up")
                }
                Button {
                    if let npub {
                        UIPasteboard.general.string = npub
                        QuickFollowToast.shared.show("Copied")
                    }
                } label: {
                    Label("Copy npub", systemImage: "person.text.rectangle")
                }
                if !NostrKey.isWatchOnly(pubkey: activeUserPubkey) {
                    Button {
                        showAddToList = true
                    } label: {
                        Label("Add to List", systemImage: "text.badge.plus")
                    }
                }
                if !isMe {
                    let blocked = muteRepo.isBlocked(pubkey)
                    Button(role: blocked ? nil : .destructive) {
                        if blocked {
                            muteRepo.unblockUser(pubkey)
                        } else {
                            muteRepo.blockUser(pubkey)
                        }
                    } label: {
                        Label(blocked ? "Unblock User" : "Block User",
                              systemImage: blocked ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.wispOnSurface)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // Extend the translucent fill up through the top safe area so the
        // status-bar region reads as the same glass, not bare scrolling photos.
        .background(
            Color.wispBackground.opacity(0.92)
                .ignoresSafeArea(edges: .top)
        )
    }

    /// Notes/Replies sort control, on its own row directly beneath the pinned
    /// tab bar (scrolls up under it). Previously sat in the header's stat row,
    /// where it squished the follow/follower counts; only the sortable tabs
    /// surface it, every other tab collapses this to nothing.
    @ViewBuilder
    private var sortRow: some View {
        switch selectedTab {
        case .notes:
            sortRowBar(selection: viewModel.notesSortMode) { mode in
                Task { await viewModel.setNotesSortMode(mode) }
            }
        case .replies:
            sortRowBar(selection: viewModel.repliesSortMode) { mode in
                Task { await viewModel.setRepliesSortMode(mode) }
            }
        default:
            EmptyView()
        }
    }

    private func sortRowBar(
        selection: ProfileSortMode,
        onSelect: @escaping (ProfileSortMode) -> Void
    ) -> some View {
        HStack {
            Spacer(minLength: 0)
            ProfileSortPicker(selection: selection, onSelect: onSelect)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var tabBody: some View {
        if !isMe && muteRepo.isBlocked(pubkey) {
            blockedBanner
        } else {
            switch selectedTab {
            case .notes:
                NotesTabView(
                    viewModel: viewModel,
                    onProfileTap: onProfileTap,
                    onNoteTap: onNoteTap,
                    onHashtagTap: onHashtagTap
                )
            case .replies:
                RepliesTabView(
                    viewModel: viewModel,
                    onProfileTap: onProfileTap,
                    onNoteTap: onNoteTap,
                    onHashtagTap: onHashtagTap
                )
            case .conversation:
                ConversationTabView(
                    viewModel: viewModel,
                    onProfileTap: onProfileTap,
                    onNoteTap: onNoteTap,
                    onHashtagTap: onHashtagTap
                )
            case .gallery:
                GalleryTabView(viewModel: viewModel, onNoteTap: onNoteTap)
            case .media:
                MediaTabView(viewModel: viewModel, onNoteTap: onNoteTap)
            case .following:
                FollowingTabView(viewModel: viewModel)
            case .followers:
                FollowersTabView(viewModel: viewModel)
            case .groups:
                GroupsTabView(viewModel: viewModel)
            case .relays:
                RelaysTabView(viewModel: viewModel)
            }
        }
    }

    private var blockedBanner: some View {
        VStack(spacing: 16) {
            Image(systemName: "nosign")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("You've blocked this user")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Their posts are hidden. Unblock to see their content.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button {
                muteRepo.unblockUser(pubkey)
            } label: {
                Text("Unblock")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.wispSurfaceVariant, in: Capsule())
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
    }

    private func shortKey(_ pk: String) -> String {
        Nip19.shortNpub(hex: pk)
    }
}

// MARK: - Header

/// Reports the intrinsic body height of the bio's `RichContentView` to the
/// owning `ProfileHeaderView` via SwiftUI preferences. `max`-reducer so a tall
/// inline image inside the bio (rare but possible — npub mention with a
/// thumbnail, etc.) wins over a short sibling.
private struct ProfileBioHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ProfileHeaderView: View {
    @Bindable var viewModel: ProfileViewModel
    var isMe: Bool = false
    var isWatchOnly: Bool = false
    var onEditProfile: () -> Void = {}
    var onProfileTap: ((String) -> Void)? = nil
    var onNoteTap: ((String) -> Void)? = nil
    var onHashtagTap: ((String) -> Void)? = nil

    @Environment(WalletStore.self) private var walletStore: WalletStore?
    @State private var muteRepo = MuteRepository.shared
    @State private var followBusy = false
    @State private var showDmSheet = false
    @State private var showZapSheet = false
    @State private var showOfferSheet = false

    /// Decoded CLINK offer advertised on the profile, when present and valid.
    private var clinkOffer: NofferData? {
        guard let raw = viewModel.profile?.clinkOffer, Noffer.isNofferString(raw) else { return nil }
        return try? Noffer.decode(raw)
    }
    /// Whether the bio is currently shown in full or capped to the
    /// collapsed height. Long bios start collapsed so the lightning
    /// address, follow stats, and tab bar stay above the fold; the
    /// user pulls down a "Read more" to read the rest.
    @State private var bioExpanded = false
    @State private var showAvatarFullScreen = false
    @State private var showBannerFullScreen = false
    /// Latched-largest intrinsic height of the bio's `RichContentView`,
    /// measured via a `GeometryReader` background. `bioIsLong` reads from
    /// this to decide whether to apply the collapse — only grows, so
    /// sub-pixel relayouts don't cause the cap to flicker on and off.
    @State private var naturalBioHeight: CGFloat = 0

    /// Height cap applied to the bio while collapsed. ~6 lines of body
    /// text — enough to glean the gist while keeping the lud16 + stat
    /// row visible without scrolling.
    private static let collapsedBioHeight: CGFloat = 132
    /// Minimum overflow required before "Read more" appears. Small spills
    /// render at full height instead of getting clipped for a few points
    /// of hidden content.
    private static let bioMinOverflow: CGFloat = 24

    private var bioIsLong: Bool {
        naturalBioHeight > Self.collapsedBioHeight + Self.bioMinOverflow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            banner
                .fullScreenCover(isPresented: $showBannerFullScreen) {
                    if let bannerUrl = viewModel.profile?.banner, !bannerUrl.isEmpty {
                        FullScreenImageView(url: bannerUrl)
                    }
                }

            HStack(alignment: .bottom, spacing: 12) {
                CachedAvatarView(url: viewModel.profile?.picture, size: 84)
                    .overlay(Circle().stroke(Color.wispBackground, lineWidth: 4))
                    .quickFollowOnLongPress(pubkey: viewModel.pubkey)
                    .onTapGesture {
                        guard viewModel.profile?.picture != nil else { return }
                        showAvatarFullScreen = true
                    }
                    .fullScreenCover(isPresented: $showAvatarFullScreen) {
                        if let pictureUrl = viewModel.profile?.picture {
                            FullScreenImageView(url: pictureUrl)
                        }
                    }
                    .offset(y: -28)

                Spacer()

                if isMe && !isWatchOnly {
                    Button(action: onEditProfile) {
                        Text("Edit Profile")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.wispSurfaceVariant, in: Capsule())
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .offset(y: -28)
                } else if !isMe && !isWatchOnly {
                    actionButtons
                        .offset(y: -28)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, -16)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    EmojiText(
                        viewModel.profile?.displayString ?? shortKey(viewModel.pubkey),
                        emojiMap: viewModel.profile?.emojiMap ?? [:],
                        textStyle: .title3,
                        weight: .bold,
                        color: .label,
                        lineLimit: 1
                    )
                    if viewModel.followsYou {
                        followsYouBadge
                    }
                    Spacer(minLength: 0)
                }

                if let nip = viewModel.profile?.nip05, !nip.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(Color.wispPrimary)
                        Text(nip)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let about = viewModel.profile?.about, !about.isEmpty {
                    bioBlock(about: about)
                        .padding(.top, 2)
                }

                if let lud16 = viewModel.profile?.lud16, !lud16.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(Color.wispZapColor)
                        Text(lud16)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .onTapGesture {
                        UIPasteboard.general.string = lud16
                        QuickFollowToast.shared.show("Copied")
                    }
                }

                statRow
                    .padding(.top, 6)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
        .sheet(isPresented: $showDmSheet) {
            if let kp = NostrKey.load() {
                NavigationStack {
                    DmConversationView(keypair: kp, participants: [viewModel.pubkey])
                }
            }
        }
        .sheet(isPresented: $showZapSheet) {
            if let store = walletStore {
                ZapSheet(
                    store: store,
                    recipientPubkey: viewModel.pubkey,
                    recipientLud16: viewModel.profile?.lud16,
                    recipientName: viewModel.profile?.displayString,
                    eventId: nil,
                    dismiss: { showZapSheet = false }
                )
            }
        }
        .sheet(isPresented: $showOfferSheet) {
            if let offer = clinkOffer {
                NofferPaySheet(noffer: offer, recipientProfile: viewModel.profile, store: walletStore)
            }
        }
    }

    /// Small pill shown beside the display name when this profile's contact
    /// list p-tags the active user — i.e. they follow you. `fixedSize` keeps it
    /// intact so a long name truncates around it rather than squeezing it out.
    private var followsYouBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.fill.checkmark")
                .font(.system(size: 9, weight: .semibold))
            Text("Follows you")
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.wispSurfaceVariant, in: Capsule())
        .fixedSize()
    }

    @ViewBuilder
    private func bioBlock(about: String) -> some View {
        let collapsed = bioIsLong && !bioExpanded
        VStack(alignment: .leading, spacing: 6) {
            RichContentView(
                content: about,
                tags: [],
                profiles: viewModel.profiles,
                authorPubkey: viewModel.pubkey,
                onProfileTap: onProfileTap,
                onNoteTap: onNoteTap,
                onHashtagTap: onHashtagTap,
                showLinkPreviews: false,
                linksEnabled: true
            )
            // Match the long-post pattern in `PostCardView`: let the body
            // size to its intrinsic height, measure it via a
            // `GeometryReader` background, then cap via `.frame(maxHeight:)`
            // + `.clipped()` when collapsed. The cap is only applied once
            // we know the bio overflows it by more than the minimum spill,
            // so short bios render naturally with no toggle.
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ProfileBioHeightKey.self,
                        value: proxy.size.height
                    )
                }
            )
            .frame(
                maxHeight: collapsed ? Self.collapsedBioHeight : .infinity,
                alignment: .top
            )
            .clipped()
            .onPreferenceChange(ProfileBioHeightKey.self) { h in
                if h > naturalBioHeight + 0.5 {
                    naturalBioHeight = h
                }
            }
            .overlay(alignment: .bottom) {
                if collapsed {
                    LinearGradient(
                        colors: [Color.wispBackground.opacity(0), Color.wispBackground],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 40)
                    .allowsHitTesting(false)
                }
            }
            if bioIsLong {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        bioExpanded.toggle()
                    }
                } label: {
                    Text(bioExpanded ? "Show less" : "Read more")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.wispPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.wispSurfaceVariant.opacity(0.6), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var banner: some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .named("profileScroll")).minY
            let pullDown = max(0, minY)
            let targetHeight = 150 + pullDown
            Group {
                if let banner = viewModel.profile?.banner, !banner.isEmpty,
                   let url = URL(string: banner) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                                .frame(width: geo.size.width, height: targetHeight)
                                .contentShape(Rectangle())
                                .onTapGesture { showBannerFullScreen = true }
                        default:
                            Color.wispSurfaceVariant
                                .frame(width: geo.size.width, height: targetHeight)
                        }
                    }
                } else {
                    Color.wispSurfaceVariant
                        .frame(width: geo.size.width, height: targetHeight)
                }
            }
            .clipped()
            .offset(y: -pullDown)
        }
        .frame(height: 150)
    }

    private var statRow: some View {
        HStack(spacing: 16) {
            statBlock(label: "Following", value: formatCount(viewModel.followingCount))
            statBlock(
                label: "Followers",
                value: viewModel.followersCountIsApprox && viewModel.followersCount == 0
                    ? "∞"
                    : formatCount(viewModel.followersCount)
            )
            Spacer(minLength: 0)
        }
    }

    private func statBlock(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.subheadline.weight(.bold))
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func shortKey(_ pk: String) -> String {
        Nip19.shortNpub(hex: pk)
    }

    private func formatCount(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: String(format: "%.1fk", Double(n) / 1_000)
        default: "\(n)"
        }
    }

    // MARK: - Action buttons (other-user profile)

    /// Follow / Mute icon row that sits to the right of the avatar on a
    /// non-self profile. Mirrors the affordances in
    /// `/Users/daniel/GitHub/resolvr/deadcat-web` —
    /// circular icon-only buttons with a tinted active state. No text labels;
    /// the icons flip and recolor to communicate the toggled state.
    private var actionButtons: some View {
        let blocked = muteRepo.isBlocked(viewModel.pubkey)
        let following = viewModel.youFollow
        return HStack(spacing: 8) {
            iconButton(
                systemName: "bubble.left.fill",
                active: false,
                activeTint: Color.wispPrimary,
                disabled: false,
                accessibilityLabel: "Message",
                action: { showDmSheet = true }
            )
            iconButton(
                systemName: "bolt.fill",
                active: false,
                activeTint: Color.wispZapColor,
                disabled: walletStore == nil,
                accessibilityLabel: "Zap",
                action: { showZapSheet = true }
            )
            if clinkOffer != nil {
                iconButton(
                    systemName: "tag.fill",
                    active: false,
                    activeTint: Color.wispZapColor,
                    disabled: false,
                    accessibilityLabel: "Pay offer",
                    action: { showOfferSheet = true }
                )
            }
            iconButton(
                systemName: following ? "person.fill.checkmark" : "person.badge.plus",
                active: following,
                activeTint: Color.wispPrimary,
                disabled: followBusy,
                accessibilityLabel: following ? "Unfollow" : "Follow",
                action: { Task { await toggleFollow() } }
            )
            iconButton(
                systemName: blocked ? "speaker.slash.fill" : "speaker.slash",
                active: blocked,
                activeTint: .red,
                disabled: false,
                accessibilityLabel: blocked ? "Unblock" : "Block",
                action: { toggleBlock(currentlyBlocked: blocked) }
            )
        }
    }

    private func iconButton(
        systemName: String,
        active: Bool,
        activeTint: Color,
        disabled: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? activeTint : Color.primary)
                .frame(width: 36, height: 36)
                .background(
                    active ? activeTint.opacity(0.15) : Color.wispSurfaceVariant,
                    in: Circle()
                )
                .overlay(
                    Circle().stroke(
                        active ? activeTint.opacity(0.4) : Color.primary.opacity(0.06),
                        lineWidth: 0.5
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private func toggleFollow() async {
        guard !followBusy, let kp = NostrKey.load() else { return }
        followBusy = true
        defer { followBusy = false }
        let target = viewModel.pubkey
        let wasFollowing = viewModel.youFollow
        // Optimistic flip — `FollowSender` writes UserDefaults eagerly so the
        // feed-side read agrees, but `youFollow` is the row's binding for the
        // pill state and needs to update right away too.
        viewModel.youFollow.toggle()
        do {
            if wasFollowing {
                try await FollowSender.shared.unfollow(target, keypair: kp)
            } else {
                try await FollowSender.shared.follow(target, keypair: kp)
            }
        } catch {
            // Revert the optimistic flip on any failure.
            viewModel.youFollow = wasFollowing
        }
    }

    private func toggleBlock(currentlyBlocked: Bool) {
        if currentlyBlocked {
            muteRepo.unblockUser(viewModel.pubkey)
        } else {
            muteRepo.blockUser(viewModel.pubkey)
        }
    }
}

// MARK: - Tab bar

private struct ProfileTabBar: View {
    @Binding var selected: ProfileTab
    let tabs: [ProfileTab]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs, id: \.self) { tab in
                        Button {
                            selected = tab
                            withAnimation { proxy.scrollTo(tab, anchor: .center) }
                        } label: {
                            VStack(spacing: 6) {
                                Text(tab.label)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(tab == selected ? Color.wispPrimary : .secondary)
                                Rectangle()
                                    .fill(tab == selected ? Color.wispPrimary : Color.clear)
                                    .frame(height: 2)
                            }
                            .padding(.horizontal, 14)
                        }
                        .buttonStyle(.plain)
                        .id(tab)
                    }
                }
            }
            // Fades the trailing edge so the user can tell the strip
            // scrolls horizontally past the visible tabs. `.mask` keeps the
            // strip's own background intact and just feathers the alpha at
            // the right ~24pt.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0.0),
                        .init(color: .black, location: 0.9),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.wispSurfaceVariant.opacity(0.4))
                    .frame(height: 1)
            }
        }
    }
}
