import SwiftUI

enum ProfileTab: String, CaseIterable, Hashable {
    case notes
    case replies
    case conversation
    case gallery
    case media
    case following
    case followers
    case groups
    case relays

    var label: String {
        switch self {
        case .notes: return "Notes"
        case .replies: return "Replies"
        case .conversation: return "Conversation"
        case .gallery: return "Gallery"
        case .media: return "Media"
        case .following: return "Following"
        case .followers: return "Followers"
        case .groups: return "Chat Rooms"
        case .relays: return "Relays"
        }
    }
}

// MARK: - Notes / Replies

struct NotesTabView: View {
    @Bindable var viewModel: ProfileViewModel
    var onProfileTap: ((String) -> Void)? = nil
    var onNoteTap: ((String) -> Void)? = nil
    var onHashtagTap: ((String) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            sortRow

            if viewModel.notesSortMode == .recency {
                if viewModel.isLoadingNotes && viewModel.rootNotes.isEmpty {
                    loading("Loading notes…")
                } else if viewModel.rootNotes.isEmpty {
                    emptyState("No notes yet")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.rootNotes, id: \.id) { event in
                            NavigationLink(value: ThreadRoute(eventId: event.id, authorPubkey: event.pubkey)) {
                                PostCardView(
                                    event: event,
                                    profile: viewModel.profiles[event.pubkey],
                                    profiles: viewModel.profiles,
                                    engagement: viewModel.engagement[event.id],
                                    onProfileTap: onProfileTap,
                                    onNoteTap: onNoteTap,
                                    onHashtagTap: onHashtagTap
                                )
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                        }
                        loadMoreFooter {
                            await viewModel.loadMoreNotes()
                        }
                    }
                }
            } else {
                if viewModel.isLoadingSortedNotes && viewModel.sortedNotes.isEmpty {
                    loading("Loading notes…")
                } else if viewModel.sortedNotes.isEmpty {
                    emptyState("Feed crawling…")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.sortedNotes, id: \.id) { event in
                            NavigationLink(value: ThreadRoute(eventId: event.id, authorPubkey: event.pubkey)) {
                                PostCardView(
                                    event: event,
                                    profile: viewModel.profiles[event.pubkey],
                                    profiles: viewModel.profiles,
                                    engagement: viewModel.engagement[event.id],
                                    onProfileTap: onProfileTap,
                                    onNoteTap: onNoteTap,
                                    onHashtagTap: onHashtagTap
                                )
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                        }
                    }
                }
            }
        }
    }

    private var sortRow: some View {
        ProfileSortPicker(
            selection: viewModel.notesSortMode,
            onSelect: { mode in
                Task { await viewModel.setNotesSortMode(mode) }
            }
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct RepliesTabView: View {
    @Bindable var viewModel: ProfileViewModel
    var onProfileTap: ((String) -> Void)? = nil
    var onNoteTap: ((String) -> Void)? = nil
    var onHashtagTap: ((String) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ProfileSortPicker(
                selection: viewModel.repliesSortMode,
                onSelect: { mode in
                    Task { await viewModel.setRepliesSortMode(mode) }
                }
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if viewModel.repliesSortMode == .recency {
                if viewModel.isLoadingReplies && viewModel.replies.isEmpty {
                    loading("Loading replies…")
                } else if viewModel.replies.isEmpty {
                    emptyState("No replies yet")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.replies, id: \.id) { event in
                            NavigationLink(value: ThreadRoute(eventId: event.id, authorPubkey: event.pubkey)) {
                                PostCardView(
                                    event: event,
                                    profile: viewModel.profiles[event.pubkey],
                                    profiles: viewModel.profiles,
                                    engagement: viewModel.engagement[event.id],
                                    onProfileTap: onProfileTap,
                                    onNoteTap: onNoteTap,
                                    onHashtagTap: onHashtagTap
                                )
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                        }
                        loadMoreFooter {
                            await viewModel.loadMoreReplies()
                        }
                    }
                }
            } else {
                if viewModel.isLoadingSortedReplies && viewModel.sortedReplies.isEmpty {
                    loading("Loading replies…")
                } else if viewModel.sortedReplies.isEmpty {
                    emptyState("Feed crawling…")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.sortedReplies, id: \.id) { event in
                            NavigationLink(value: ThreadRoute(eventId: event.id, authorPubkey: event.pubkey)) {
                                PostCardView(
                                    event: event,
                                    profile: viewModel.profiles[event.pubkey],
                                    profiles: viewModel.profiles,
                                    engagement: viewModel.engagement[event.id],
                                    onProfileTap: onProfileTap,
                                    onNoteTap: onNoteTap,
                                    onHashtagTap: onHashtagTap
                                )
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                        }
                    }
                }
            }
        }
    }
}

struct ConversationTabView: View {
    @Bindable var viewModel: ProfileViewModel
    var onProfileTap: ((String) -> Void)? = nil
    var onNoteTap: ((String) -> Void)? = nil
    var onHashtagTap: ((String) -> Void)? = nil

    var body: some View {
        Group {
            if viewModel.isLoadingConversation && viewModel.conversationNotes.isEmpty {
                loading("Loading conversation…")
            } else if viewModel.conversationNotes.isEmpty {
                emptyState("No public conversation with this user yet")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.conversationNotes, id: \.id) { event in
                        NavigationLink(value: ThreadRoute(eventId: event.id, authorPubkey: event.pubkey)) {
                            PostCardView(
                                event: event,
                                profile: viewModel.profiles[event.pubkey],
                                profiles: viewModel.profiles,
                                engagement: viewModel.engagement[event.id],
                                onProfileTap: onProfileTap,
                                onNoteTap: onNoteTap,
                                onHashtagTap: onHashtagTap
                            )
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                    }
                }
            }
        }
    }
}

private struct ProfileSortPicker: View {
    let selection: ProfileSortMode
    let onSelect: (ProfileSortMode) -> Void

    var body: some View {
        Menu {
            ForEach(ProfileSortMode.allCases, id: \.self) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    if mode == selection {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 13))
                Text(selection.label)
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color.wispPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 16))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Gallery / Media grid tabs

struct GalleryTabView: View {
    @Bindable var viewModel: ProfileViewModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 2)

    var body: some View {
        Group {
            if viewModel.isLoadingGallery && viewModel.galleryPosts.isEmpty {
                loading("Loading gallery…")
            } else if viewModel.galleryPosts.isEmpty {
                emptyState("No picture or video posts")
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(viewModel.galleryPosts, id: \.id) { event in
                        GalleryTile(event: event)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }
}

private struct GalleryTile: View {
    let event: NostrEvent

    var body: some View {
        let metas = ContentParser.parseImetaTags(event.tags)
        let firstUrl = firstImetaUrl(metas) ?? firstUrlFromContent(event.content)
        let isVideo = [21, 22].contains(event.kind)

        ZStack(alignment: .center) {
            if let url = firstUrl, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .failure:
                        Color.wispSurfaceVariant
                    default:
                        Color.wispSurfaceVariant
                    }
                }
            } else {
                Color.wispSurfaceVariant
            }

            if isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipped()
    }

    private func firstImetaUrl(_ metas: [String: MediaMeta]) -> String? {
        // imeta map preserves whichever URL was added last; fine for tile preview.
        metas.values.first?.url
    }

    private func firstUrlFromContent(_ content: String) -> String? {
        for seg in ContentParser.parse(content: content, tags: []) {
            switch seg {
            case .image(let m), .video(let m), .unknownMedia(let m):
                return m.url
            default: break
            }
        }
        return nil
    }
}

struct MediaTabView: View {
    @Bindable var viewModel: ProfileViewModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        let items = viewModel.mediaItems()

        if items.isEmpty {
            emptyState("No images or videos yet")
        } else {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(items, id: \.url) { item in
                    MediaTile(item: item)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct MediaTile: View {
    let item: MediaItem

    var body: some View {
        ZStack {
            if let url = URL(string: item.url) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .failure:
                        Color.wispSurfaceVariant
                    default:
                        Color.wispSurfaceVariant
                    }
                }
            } else {
                Color.wispSurfaceVariant
            }
            if item.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipped()
    }
}

// MARK: - Following / Followers

struct FollowingTabView: View {
    @Bindable var viewModel: ProfileViewModel

    var body: some View {
        Group {
            if viewModel.isLoadingFollowing && viewModel.followingProfiles.isEmpty {
                loading("Loading following…")
            } else if viewModel.followingProfiles.isEmpty {
                emptyState("Not following anyone")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.followingProfiles, id: \.pubkey) { profile in
                        ProfileRow(profile: profile)
                        Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                    }
                }
            }
        }
    }
}

struct FollowersTabView: View {
    @Bindable var viewModel: ProfileViewModel

    var body: some View {
        Group {
            if viewModel.isLoadingFollowers && viewModel.followerProfiles.isEmpty {
                loading("Loading followers…")
            } else if viewModel.followerProfiles.isEmpty {
                emptyState("No followers found")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.followerProfiles, id: \.pubkey) { profile in
                        ProfileRow(profile: profile)
                        Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                    }
                }
            }
        }
    }
}

private struct ProfileRow: View {
    let profile: ProfileData

    var body: some View {
        NavigationLink(value: ProfileRoute(pubkey: profile.pubkey)) {
            HStack(spacing: 12) {
                CachedAvatarView(url: profile.picture, size: 44)
                    .quickFollowOnLongPress(pubkey: profile.pubkey)
                VStack(alignment: .leading, spacing: 2) {
                    EmojiText(
                        profile.displayString,
                        emojiMap: profile.emojiMap,
                        textStyle: .subheadline,
                        weight: .semibold
                    )
                    if let nip = profile.nip05, !nip.isEmpty {
                        Text(nip)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let about = profile.about, !about.isEmpty {
                        Text(about)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Groups

struct GroupsTabView: View {
    @Bindable var viewModel: ProfileViewModel

    var body: some View {
        Group {
            if viewModel.isLoadingGroups && viewModel.groups.isEmpty {
                loading("Loading chat rooms…")
            } else if viewModel.groups.isEmpty {
                emptyState("No chat rooms")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.groups, id: \.self) { group in
                        GroupRow(group: group)
                        Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                    }
                }
            }
        }
    }
}

private struct GroupRow: View {
    let group: SimpleGroup

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.wispSurfaceVariant)
                    .frame(width: 44, height: 44)
                Image(systemName: "person.3.fill")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name ?? group.groupId)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(group.relayUrl)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Relays

struct RelaysTabView: View {
    @Bindable var viewModel: ProfileViewModel

    var body: some View {
        Group {
            if viewModel.isLoadingRelays && viewModel.relayList.isEmpty {
                loading("Loading relays…")
            } else if viewModel.relayList.isEmpty {
                emptyState("No relay list published")
            } else {
                let read = viewModel.relayList.filter(\.read)
                let write = viewModel.relayList.filter(\.write)
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !read.isEmpty {
                        relaySection(title: "Read", entries: read)
                    }
                    if !write.isEmpty {
                        relaySection(title: "Write", entries: write)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func relaySection(title: String, entries: [RelayConfigEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            ForEach(entries, id: \.url) { entry in
                HStack(spacing: 12) {
                    Image(systemName: "network")
                        .foregroundStyle(Color.wispPrimary)
                    Text(entry.url)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
            }
        }
    }
}

// MARK: - Shared bits

private func loading(_ label: String = "Loading…") -> some View {
    VStack(spacing: 10) {
        ProgressView()
            .tint(Color.wispPrimary)
        Text(label)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
    .padding(.top, 40)
    .frame(maxWidth: .infinity)
}

private func emptyState(_ text: String) -> some View {
    VStack(spacing: 8) {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.top, 40)
        Spacer()
    }
    .frame(maxWidth: .infinity)
}

private struct LoadMoreFooter: View {
    let action: () async -> Void
    @State private var loading = false

    var body: some View {
        Button {
            Task {
                loading = true
                await action()
                loading = false
            }
        } label: {
            HStack {
                Spacer()
                if loading {
                    ProgressView()
                        .tint(Color.wispPrimary)
                } else {
                    Text("Load more")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.wispPrimary)
                }
                Spacer()
            }
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }
}

@ViewBuilder
private func loadMoreFooter(_ action: @escaping () async -> Void) -> some View {
    LoadMoreFooter(action: action)
}
