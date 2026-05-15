import SwiftUI

/// Feed of notes from members of a `PeopleList`. Mirrors `HashtagFeedView`.
struct PeopleListFeedView: View {
    let keypair: Keypair
    let dTag: String
    var onProfileTap: (String) -> Void = { _ in }
    var onNoteTap: (String) -> Void = { _ in }
    var onHashtagTap: (String) -> Void = { _ in }

    @State private var viewModel: PeopleListFeedViewModel
    @State private var engagementRepo = EngagementRepository.shared
    @Environment(\.dismiss) private var dismiss

    init(
        keypair: Keypair,
        dTag: String,
        onProfileTap: @escaping (String) -> Void = { _ in },
        onNoteTap: @escaping (String) -> Void = { _ in },
        onHashtagTap: @escaping (String) -> Void = { _ in }
    ) {
        self.keypair = keypair
        self.dTag = dTag
        self.onProfileTap = onProfileTap
        self.onNoteTap = onNoteTap
        self.onHashtagTap = onHashtagTap
        _viewModel = State(initialValue: PeopleListFeedViewModel(keypair: keypair, dTag: dTag))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
            content
        }
        .background(Color.wispBackground)
        .toolbar(.hidden, for: .navigationBar)
        .swipeBackFromLeftEdge()
        .task { await viewModel.start() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BackChevronButton { dismiss() }

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let list = PeopleListRepository.shared.list(dTag: dTag) {
                    Text("\(list.allMembers.count) member\(list.allMembers.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.events.isEmpty {
            VStack(spacing: 16) {
                ProgressView()
                Text("Loading list feed\u{2026}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.events.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "person.2")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No posts yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Try refreshing or add more members to this list")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                onProfileTap: onProfileTap,
                                onNoteTap: onNoteTap,
                                onHashtagTap: onHashtagTap
                            )
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            engagementRepo.markVisible(event: event)
                            if event.id == viewModel.events.last?.id {
                                viewModel.loadMore()
                            }
                        }
                        Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                    }
                }
            }
            .refreshable { await viewModel.refresh() }
        }
    }
}
