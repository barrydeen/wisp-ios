import SwiftUI

/// Tabbed list view for the user's drafts (NIP-37 on write relays) and
/// scheduled posts (parked on `scheduler.nostrarchives.com`).
struct DraftsScheduledView: View {
    let keypair: Keypair

    @State private var viewModel: DraftsViewModel
    @State private var openedDraft: Nip37.Draft?
    @Environment(\.dismiss) private var dismiss

    init(keypair: Keypair) {
        self.keypair = keypair
        _viewModel = State(initialValue: DraftsViewModel(keypair: keypair))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.wispBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    Picker("", selection: $viewModel.selectedTab) {
                        Text("Drafts").tag(DraftsViewModel.Tab.drafts)
                        Text("Scheduled").tag(DraftsViewModel.Tab.scheduled)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                    Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))

                    switch viewModel.selectedTab {
                    case .drafts:
                        draftsList
                    case .scheduled:
                        scheduledList
                    }
                }
            }
            .navigationTitle("Drafts & Scheduled")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            await viewModel.loadDrafts()
            await viewModel.loadScheduledPosts()
        }
        .sheet(item: $openedDraft) { draft in
            ComposeView(keypair: keypair, draft: draft)
                .id(draft.dTag)
                .onDisappear {
                    Task { await viewModel.loadDrafts() }
                }
        }
        .onChange(of: viewModel.selectedTab) { _, tab in
            switch tab {
            case .drafts where viewModel.drafts.isEmpty && !viewModel.isLoadingDrafts:
                Task { await viewModel.loadDrafts() }
            case .scheduled where viewModel.scheduledPosts.isEmpty && !viewModel.isLoadingScheduled:
                Task { await viewModel.loadScheduledPosts() }
            default:
                break
            }
        }
    }

    // MARK: - Drafts tab

    @ViewBuilder
    private var draftsList: some View {
        if viewModel.isLoadingDrafts && viewModel.drafts.isEmpty {
            loadingView
        } else if viewModel.drafts.isEmpty {
            emptyState(icon: "doc.text", title: "No drafts", subtitle: "Drafts you save while composing will appear here.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.drafts, id: \.dTag) { draft in
                        DraftRow(
                            draft: draft,
                            authorPubkey: keypair.pubkey,
                            onOpen: { openedDraft = draft },
                            onDelete: {
                                Task { await viewModel.deleteDraft(dTag: draft.dTag) }
                            }
                        )
                        Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                    }
                }
            }
            .refreshable { await viewModel.loadDrafts() }
        }
    }

    // MARK: - Scheduled tab

    @ViewBuilder
    private var scheduledList: some View {
        if viewModel.isLoadingScheduled && viewModel.scheduledPosts.isEmpty {
            loadingView
        } else if viewModel.scheduledPosts.isEmpty {
            emptyState(icon: "clock", title: "No scheduled posts", subtitle: "Posts you schedule will appear here until they're broadcast.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.scheduledPosts, id: \.id) { event in
                        ScheduledPostRow(
                            event: event,
                            onDelete: {
                                Task { await viewModel.deleteScheduledPost(eventId: event.id) }
                            }
                        )
                        Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                    }
                }
            }
            .refreshable { await viewModel.loadScheduledPosts() }
        }
    }

    // MARK: - Shared

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading\u{2026}").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
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

// MARK: - Draft row

private struct DraftRow: View {
    let draft: Nip37.Draft
    let authorPubkey: String
    let onOpen: () -> Void
    let onDelete: () -> Void

    private var profile: ProfileData? { ProfileRepository.shared.get(authorPubkey) }
    private var isReply: Bool {
        draft.tags.contains { $0.count >= 2 && $0[0] == "e" }
    }
    private var formattedTimestamp: String {
        let date = Date(timeIntervalSince1970: TimeInterval(draft.createdAt))
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CachedAvatarView(url: profile?.picture, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile?.displayString ?? String(authorPubkey.prefix(8)) + "\u{2026}")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if isReply {
                        Text("REPLY")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.wispSurfaceVariant, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formattedTimestamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                RichContentView(
                    content: draft.content,
                    tags: draft.tags,
                    profiles: ProfileRepository.shared.getAll(referencedPubkeys(in: draft)),
                    showLinkPreviews: false
                )
                .lineLimit(6)
            }

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(Color.wispSurfaceVariant.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }

    private func referencedPubkeys(in draft: Nip37.Draft) -> [String] {
        draft.tags.compactMap { tag in
            guard tag.count >= 2, tag[0] == "p" else { return nil }
            return tag[1]
        }
    }
}

// MARK: - Scheduled post row

private struct ScheduledPostRow: View {
    let event: NostrEvent
    let onDelete: () -> Void

    private var profile: ProfileData? { ProfileRepository.shared.get(event.pubkey) }
    private var isFuture: Bool { event.createdAt > Int(Date().timeIntervalSince1970) }
    private var formattedTime: String {
        let date = Date(timeIntervalSince1970: TimeInterval(event.createdAt))
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
        }
        return formatter.string(from: date)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CachedAvatarView(url: profile?.picture, size: 36)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(profile?.displayString ?? String(event.pubkey.prefix(8)) + "\u{2026}")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    timeChip
                }
                RichContentView(
                    content: event.content,
                    tags: event.tags,
                    profiles: ProfileRepository.shared.getAll(referencedPubkeys),
                    showLinkPreviews: false
                )
                .lineLimit(6)
            }
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(Color.wispSurfaceVariant.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var timeChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .semibold))
            Text(formattedTime)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (isFuture ? Color.green : Color.red).opacity(0.15),
            in: Capsule()
        )
        .foregroundStyle(isFuture ? Color.green : Color.red)
    }

    private var referencedPubkeys: [String] {
        event.tags.compactMap { tag in
            guard tag.count >= 2, tag[0] == "p" else { return nil }
            return tag[1]
        }
    }
}
