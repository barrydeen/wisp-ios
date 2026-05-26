import SwiftUI

/// "My Polls" sheet. Two tabs: polls the user authored, and polls the
/// user has voted in. Rows show the question/options, live tally counts,
/// and a status chip (active / ended). Tap to open the poll's thread.
struct PollsView: View {
    let keypair: Keypair
    let onOpenPoll: (String, String) -> Void

    @State private var viewModel: PollsViewModel
    @State private var tallyRepo = PollTallyRepository.shared
    @Environment(\.dismiss) private var dismiss

    init(keypair: Keypair, onOpenPoll: @escaping (String, String) -> Void) {
        self.keypair = keypair
        self.onOpenPoll = onOpenPoll
        _viewModel = State(initialValue: PollsViewModel(keypair: keypair))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.wispBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    Picker("", selection: $viewModel.selectedTab) {
                        Text("Mine").tag(PollsViewModel.Tab.mine)
                        Text("Voted").tag(PollsViewModel.Tab.voted)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                    Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))

                    switch viewModel.selectedTab {
                    case .mine:
                        list(
                            polls: viewModel.minePolls,
                            isLoading: viewModel.isLoadingMine,
                            empty: ("chart.bar", "No polls yet", "Polls you create from the composer will appear here."),
                            refresh: { await viewModel.loadMine() }
                        )
                    case .voted:
                        list(
                            polls: viewModel.votedPolls,
                            isLoading: viewModel.isLoadingVoted,
                            empty: ("checkmark.circle", "No votes yet", "Polls you've voted in will appear here."),
                            refresh: { await viewModel.loadVoted() }
                        )
                    }
                }
            }
            .navigationTitle("My Polls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            await viewModel.loadMine()
        }
        .onChange(of: viewModel.selectedTab) { _, tab in
            switch tab {
            case .voted where viewModel.votedPolls.isEmpty && !viewModel.isLoadingVoted:
                Task { await viewModel.loadVoted() }
            default:
                break
            }
        }
    }

    @ViewBuilder
    private func list(
        polls: [NostrEvent],
        isLoading: Bool,
        empty: (icon: String, title: String, subtitle: String),
        refresh: @escaping () async -> Void
    ) -> some View {
        if isLoading && polls.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading\u{2026}").font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if polls.isEmpty {
            emptyState(icon: empty.icon, title: empty.title, subtitle: empty.subtitle)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(polls, id: \.id) { poll in
                        PollSummaryRow(
                            poll: poll,
                            tallyVersion: tallyRepo.version,
                            isAuthor: poll.pubkey == keypair.pubkey
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { onOpenPoll(poll.id, poll.pubkey) }
                        .onAppear { tallyRepo.markVisible(pollEvent: poll) }
                        Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                    }
                }
            }
            .refreshable { await refresh() }
        }
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

// MARK: - Row

private struct PollSummaryRow: View {
    let poll: NostrEvent
    /// Bumped on every `PollTallyRepository` mutation. Reading it makes the
    /// row re-render when live vote counts arrive without subscribing to
    /// the whole tallies dictionary.
    let tallyVersion: Int
    let isAuthor: Bool

    /// Resolves the poll author from `ProfileRepository`. Only shown on
    /// the Voted tab (`!isAuthor`) — on the Mine tab every poll is by
    /// the current user, so a "by @you" line would be noise.
    private var authorDisplayName: String? {
        guard !isAuthor else { return nil }
        if let profile = ProfileRepository.shared.get(poll.pubkey),
           !profile.displayString.isEmpty {
            return profile.displayString
        }
        return Nip19.shortNpub(hex: poll.pubkey)
    }

    private var isZap: Bool { poll.kind == Nip69.kindZapPoll }

    private var endsAt: Int? {
        isZap ? Nip69.parseClosedAt(poll) : Nip88.parseEndsAt(poll)
    }

    private var ended: Bool {
        isZap ? Nip69.isZapPollClosed(poll) : Nip88.isPollEnded(poll)
    }

    private var tally: PollTally {
        _ = tallyVersion
        return PollTallyRepository.shared.tally(for: poll.id)
    }

    private var formattedCreated: String {
        let date = Date(timeIntervalSince1970: TimeInterval(poll.createdAt))
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: date)
    }

    private var endLabel: String? {
        guard let endsAt else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(endsAt))
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return (ended ? "Ended " : "Ends ") + f.string(from: date)
    }

    private var totalsText: String {
        if isZap {
            return "\(tally.totalSats) sats"
        }
        return "\(tally.totalVotes) \(tally.totalVotes == 1 ? "vote" : "votes")"
    }

    private var question: String {
        let trimmed = poll.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(no question)" : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: isZap ? "bolt.fill" : "chart.bar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isZap ? Color.wispZapColor : Color.wispPrimary)
                statusChip
                Spacer()
                Text(formattedCreated)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(question)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(3)
            if let authorDisplayName {
                HStack(spacing: 6) {
                    CachedAvatarView(
                        url: ProfileRepository.shared.get(poll.pubkey)?.picture,
                        size: 16
                    )
                    Text("by \(authorDisplayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            optionsPreview
            HStack(spacing: 6) {
                Text(totalsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let endLabel {
                    Text("·").font(.caption).foregroundStyle(.secondary)
                    Text(endLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusChip: some View {
        let label = ended ? "Ended" : "Active"
        let tint: Color = ended ? .secondary : .green
        Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }

    @ViewBuilder
    private var optionsPreview: some View {
        // Pull `(id, label)` pairs instead of just labels — we need the
        // ids to match against `PollTally.userVotes` and mark which
        // option(s) the current user picked. Zap polls only carry
        // `(index, label)` so we synthesize a stable string id from
        // the index for the dictionary lookup.
        let options: [(id: String, label: String)] = isZap
            ? Nip69.parseZapPollOptions(poll).map { (String($0.index), $0.label) }
            : Nip88.parsePollOptions(poll).map { ($0.id, $0.label) }
        if !options.isEmpty {
            let userVotes = Set(PollTallyRepository.shared.tally(for: poll.id).userVotes)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(options.prefix(3).enumerated()), id: \.offset) { _, option in
                    let chose = userVotes.contains(option.id)
                    HStack(spacing: 6) {
                        Image(systemName: chose ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: chose ? 11 : 8))
                            .foregroundStyle(chose ? Color.wispPrimary : .secondary)
                        Text(option.label)
                            .font(.caption)
                            .foregroundStyle(chose ? .primary : .secondary)
                            .fontWeight(chose ? .semibold : .regular)
                            .lineLimit(1)
                    }
                }
                if options.count > 3 {
                    Text("+ \(options.count - 3) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
