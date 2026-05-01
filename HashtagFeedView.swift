import SwiftUI

/// Feed of notes for a single hashtag or a hashtag set.
///
/// Reuses `PostCardView` and `RichContentView` verbatim. Hashtag taps inside
/// posts push another `HashtagFeedRoute`, allowing chained navigation.
struct HashtagFeedView: View {
    let keypair: Keypair
    let source: HashtagFeedViewModel.Source
    var onHashtagTap: (String) -> Void = { _ in }

    @State private var viewModel: HashtagFeedViewModel
    @State private var showAddToSet = false
    @State private var engagementRepo = EngagementRepository.shared
    @Environment(\.dismiss) private var dismiss

    init(
        keypair: Keypair,
        source: HashtagFeedViewModel.Source,
        onHashtagTap: @escaping (String) -> Void = { _ in }
    ) {
        self.keypair = keypair
        self.source = source
        self.onHashtagTap = onHashtagTap
        _viewModel = State(initialValue: HashtagFeedViewModel(keypair: keypair, source: source))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
            content
        }
        .background(Color.wispBackground)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await viewModel.start()
        }
        .sheet(isPresented: $showAddToSet) {
            if case .single(let tag) = viewModel.source {
                NavigationStack {
                    HashtagSetPickerSheet(hashtag: tag, keypair: keypair)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            BackChevronButton { dismiss() }

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if case .set(let set) = viewModel.source, !set.hashtags.isEmpty {
                    Text(set.hashtags.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if case .single = viewModel.source {
                Button {
                    showAddToSet = true
                } label: {
                    Image(systemName: "bookmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.wispPrimary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.events.isEmpty {
            VStack(spacing: 16) {
                ProgressView()
                Text("Loading hashtag feed\u{2026}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.events.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "number")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No posts yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Try refreshing or pick a different hashtag")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
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
}
