import SwiftUI

/// Trending screen — wraps `feeds.nostrarchives.com` relay feeds. Two modes:
/// trending notes (filtered by metric × timeframe) and trending users
/// ("Up & Coming"). Reuses `PostCardView` and `EngagementRepository` so post
/// cards pick up live engagement counts the same as the follow feed.
struct TrendingFeedView: View {
    let keypair: Keypair
    var onProfileTap: (String) -> Void = { _ in }
    var onNoteTap: (String) -> Void = { _ in }
    var onHashtagTap: (String) -> Void = { _ in }

    @State private var viewModel: TrendingFeedViewModel
    @State private var engagementRepo = EngagementRepository.shared
    @Environment(\.dismiss) private var dismiss

    init(
        keypair: Keypair,
        onProfileTap: @escaping (String) -> Void = { _ in },
        onNoteTap: @escaping (String) -> Void = { _ in },
        onHashtagTap: @escaping (String) -> Void = { _ in }
    ) {
        self.keypair = keypair
        self.onProfileTap = onProfileTap
        self.onNoteTap = onNoteTap
        self.onHashtagTap = onHashtagTap
        _viewModel = State(initialValue: TrendingFeedViewModel(keypair: keypair))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
            filterBar
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
            content
        }
        .background(Color.wispBackground)
        .toolbar(.hidden, for: .navigationBar)
        .task { await viewModel.start() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            BackChevronButton { dismiss() }

            VStack(alignment: .leading, spacing: 2) {
                Text("Trending")
                    .font(.subheadline.weight(.semibold))
                Text(viewModel.displayTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 6) {
            modeChip(
                icon: "person",
                isSelected: viewModel.mode == .users
            ) {
                viewModel.setMode(.users)
            }

            Rectangle()
                .fill(Color.wispSurfaceVariant.opacity(0.5))
                .frame(width: 1, height: 20)

            ForEach(TrendingMetric.allCases, id: \.self) { metric in
                let selected = viewModel.mode == .notes && viewModel.metric == metric
                modeChip(
                    icon: metric.iconName,
                    isSelected: selected
                ) {
                    viewModel.setMetric(metric)
                }
            }

            Spacer(minLength: 4)

            if viewModel.mode == .notes {
                Menu {
                    ForEach(TrendingTimeframe.allCases, id: \.self) { tf in
                        Button {
                            viewModel.setTimeframe(tf)
                        } label: {
                            if tf == viewModel.timeframe {
                                Label(tf.label, systemImage: "checkmark")
                            } else {
                                Text(tf.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(viewModel.timeframe.label)
                            .font(.caption.weight(.medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.primary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func modeChip(icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: 32, height: 28)
                .background(
                    isSelected ? Color.wispPrimary : Color.wispSurfaceVariant,
                    in: RoundedRectangle(cornerRadius: 14)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.events.isEmpty && viewModel.users.isEmpty {
            VStack(spacing: 16) {
                ProgressView()
                Text("Loading trending\u{2026}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch viewModel.mode {
            case .notes:
                notesContent
            case .users:
                usersContent
            }
        }
    }

    // MARK: - Notes

    @ViewBuilder
    private var notesContent: some View {
        if viewModel.events.isEmpty {
            emptyState(
                icon: "flame",
                title: "No trending posts",
                subtitle: viewModel.lastError ?? "Try a different metric or timeframe"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.events, id: \.id) { event in
                        NavigationLink(value: ThreadRoute(eventId: event.id, authorPubkey: event.pubkey)) {
                            PostCardView(
                                event: event,
                                profile: viewModel.profiles[event.pubkey],
                                profiles: viewModel.profiles,
                                engagement: nil,
                                onProfileTap: { _ in },
                                onNoteTap: { _ in },
                                onHashtagTap: { tag in
                                    onHashtagTap(tag)
                                }
                            )
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            engagementRepo.markVisible(eventId: event.id, author: event.pubkey)
                        }
                        Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                    }
                }
            }
            .refreshable { await viewModel.refresh() }
        }
    }

    // MARK: - Users

    @ViewBuilder
    private var usersContent: some View {
        if viewModel.users.isEmpty {
            emptyState(
                icon: "person.2",
                title: "No trending users",
                subtitle: viewModel.lastError ?? "Check back soon"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.users, id: \.pubkey) { profile in
                        userCard(profile: profile)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .refreshable { await viewModel.refresh() }
        }
    }

    private func userCard(profile: ProfileData) -> some View {
        Button {
            onProfileTap(profile.pubkey)
        } label: {
            HStack(spacing: 12) {
                CachedAvatarView(url: profile.picture, size: 56)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayString)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let nip05 = profile.nip05, !nip05.isEmpty {
                        Text(nip05)
                            .font(.caption)
                            .foregroundStyle(Color.wispPrimary)
                            .lineLimit(1)
                    }
                    if let about = profile.about, !about.isEmpty {
                        Text(about)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                Color.wispSurfaceVariant.opacity(0.4),
                in: RoundedRectangle(cornerRadius: 16)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
