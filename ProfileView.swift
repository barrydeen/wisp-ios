import SwiftUI

struct ProfileView: View {
    let pubkey: String
    let activeUserPubkey: String

    @State private var viewModel: ProfileViewModel
    @State private var selectedTab: ProfileTab = .notes
    @State private var showAddToList = false

    init(pubkey: String, activeUserPubkey: String) {
        self.pubkey = pubkey
        self.activeUserPubkey = activeUserPubkey
        _viewModel = State(initialValue: ProfileViewModel(pubkey: pubkey, activeUserPubkey: activeUserPubkey))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ProfileHeaderView(viewModel: viewModel)
                Section {
                    tabBody
                } header: {
                    ProfileTabBar(selected: $selectedTab)
                        .background(Color.wispBackground)
                }
            }
        }
        .background(Color.wispBackground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                EmojiText(
                    viewModel.profile?.displayString ?? shortKey(pubkey),
                    emojiMap: viewModel.profile?.emojiMap ?? [:],
                    textStyle: .subheadline,
                    weight: .semibold,
                    color: .label,
                    lineLimit: 1
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddToList = true
                } label: {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 17))
                }
            }
        }
        .sheet(isPresented: $showAddToList) {
            if let keypair = NostrKey.load() {
                NavigationStack {
                    AddProfileToListSheet(keypair: keypair, targetPubkey: pubkey)
                }
            }
        }
        .task { await viewModel.start() }
        .task(id: selectedTab) {
            await viewModel.loadTab(selectedTab)
        }
    }

    @ViewBuilder
    private var tabBody: some View {
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

    private func shortKey(_ pk: String) -> String {
        String(pk.prefix(8)) + "\u{2026}"
    }
}

// MARK: - Header

private struct ProfileHeaderView: View {
    @Bindable var viewModel: ProfileViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            banner

            HStack(alignment: .bottom, spacing: 12) {
                CachedAvatarView(url: viewModel.profile?.picture, size: 84)
                    .overlay(Circle().stroke(Color.wispBackground, lineWidth: 4))
                    .offset(y: -28)

                Spacer()

                if viewModel.followsYou {
                    Text("Follows you")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.wispSurfaceVariant, in: Capsule())
                        .foregroundStyle(.secondary)
                        .offset(y: -2)
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
                        showLinkPreviews: false
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
