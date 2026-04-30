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
        onHashtagTap: ((String) -> Void)? = nil
    ) {
        self.pubkey = pubkey
        self.activeUserPubkey = activeUserPubkey
        self.onProfileTap = onProfileTap
        self.onNoteTap = onNoteTap
        self.onHashtagTap = onHashtagTap
        _viewModel = State(initialValue: ProfileViewModel(pubkey: pubkey, activeUserPubkey: activeUserPubkey))
    }

    private var isMe: Bool { pubkey == activeUserPubkey }
    private var shareURL: String { "https://wisp.talk/profile/\(pubkey)" }
    private var npub: String? {
        guard let bytes = Hex.decode(pubkey) else { return nil }
        return Nip19.npubEncode(pubkey: Array(bytes))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ProfileHeaderView(
                    viewModel: viewModel,
                    isMe: isMe,
                    onEditProfile: { showEditProfile = true },
                    onProfileTap: onProfileTap,
                    onNoteTap: onNoteTap,
                    onHashtagTap: onHashtagTap
                )
                tabBody
            }
        }
        .background(Color.wispBackground)
        // The whole top section (back/title/QR/ellipsis row + tab strip) lives in
        // a single `.safeAreaInset` view with one `.regularMaterial` backdrop, so
        // every control reads as one continuous unit and scrolling content blurs
        // uniformly behind the entire header instead of through two stacked
        // backdrop layers (nav-bar material + bar-button capsule blur + tab-strip
        // material).
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            unifiedHeader
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
                lud16: viewModel.profile?.lud16
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
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }

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
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }

                Menu {
                    ShareLink(item: shareURL) {
                        Label("Share Profile", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        if let npub { UIPasteboard.general.string = npub }
                    } label: {
                        Label("Copy npub", systemImage: "person.text.rectangle")
                    }
                    Button {
                        showAddToList = true
                    } label: {
                        Label("Add to List", systemImage: "text.badge.plus")
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
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            ProfileTabBar(selected: $selectedTab)
        }
        .background(Color.wispBackground.opacity(0.92))
    }

    @ViewBuilder
    private var tabBody: some View {
        if !isMe && muteRepo.isBlocked(pubkey) {
            blockedBanner
        } else {
            switch selectedTab {
            case .notes:
                NotesTabView(viewModel: viewModel)
            case .replies:
                RepliesTabView(viewModel: viewModel)
            case .gallery:
                GalleryTabView(viewModel: viewModel)
            case .media:
                MediaTabView(viewModel: viewModel)
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
        String(pk.prefix(8)) + "\u{2026}"
    }
}

// MARK: - Header

private struct ProfileHeaderView: View {
    @Bindable var viewModel: ProfileViewModel
    var isMe: Bool = false
    var onEditProfile: () -> Void = {}
    var onProfileTap: ((String) -> Void)? = nil
    var onNoteTap: ((String) -> Void)? = nil
    var onHashtagTap: ((String) -> Void)? = nil

    @State private var muteRepo = MuteRepository.shared
    @State private var followBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            banner

            HStack(alignment: .bottom, spacing: 12) {
                CachedAvatarView(url: viewModel.profile?.picture, size: 84)
                    .overlay(Circle().stroke(Color.wispBackground, lineWidth: 4))
                    .offset(y: -28)

                Spacer()

                if isMe {
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
                } else {
                    VStack(alignment: .trailing, spacing: 4) {
                        actionButtons
                        if viewModel.followsYou {
                            Text("Follows you")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .offset(y: -28)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, -16)

            VStack(alignment: .leading, spacing: 6) {
                EmojiText(
                    viewModel.profile?.displayString ?? shortKey(viewModel.pubkey),
                    emojiMap: viewModel.profile?.emojiMap ?? [:],
                    textStyle: .title3,
                    weight: .bold,
                    color: .label,
                    lineLimit: 1
                )

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
                    RichContentView(
                        content: about,
                        tags: [],
                        profiles: viewModel.profiles,
                        onProfileTap: onProfileTap,
                        onNoteTap: onNoteTap,
                        onHashtagTap: onHashtagTap,
                        showLinkPreviews: false,
                        linksEnabled: true
                    )
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
                    }
                }

                statRow
                    .padding(.top, 6)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)
        }
    }

    private var banner: some View {
        Group {
            if let banner = viewModel.profile?.banner, !banner.isEmpty,
               let url = URL(string: banner) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Color.wispSurfaceVariant
                    }
                }
            } else {
                Color.wispSurfaceVariant
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .clipped()
    }

    private var statRow: some View {
        HStack(spacing: 16) {
            statBlock(label: "Following", value: formatCount(viewModel.followingCount))
            statBlock(
                label: "Followers",
                value: viewModel.followersCountIsApprox && viewModel.followersCount == 0
                    ? "—"
                    : formatCount(viewModel.followersCount)
            )
            Spacer()
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
        String(pk.prefix(8)) + "\u{2026}"
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(ProfileTab.allCases, id: \.self) { tab in
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
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.wispSurfaceVariant.opacity(0.4))
                    .frame(height: 1)
            }
        }
    }
}
