import SwiftUI

struct SafetySettingsView: View {
    let keypair: Keypair

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var prefs = SafetyPreferences.shared
    @State private var mutes = MuteRepository.shared
    @State private var selectedTab: Tab = .filters

    @State private var newWord: String = ""
    @State private var wotState: WotDiscoveryState = .idle
    @State private var wotSummary: (qualifiedCount: Int, computedAt: Int) = (0, 0)
    @State private var wotStateTask: Task<Void, Never>?

    enum Tab: String, CaseIterable, Identifiable {
        case filters = "Filters"
        case words = "Words"
        case users = "Users"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().overlay(theme.palette.surfaceVariant.opacity(0.5))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTab {
                    case .filters: filtersTab
                    case .words: wordsTab
                    case .users: usersTab
                    }
                }
                .padding(20)
            }
        }
        .background(theme.palette.background.ignoresSafeArea())
        .navigationTitle("Safety")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await ExtendedNetworkRepository.shared.bind(activePubkey: keypair.pubkey)
            wotSummary = await ExtendedNetworkRepository.shared.summary()
            wotStateTask = Task {
                for await state in ExtendedNetworkRepository.shared.stateStream {
                    await MainActor.run { self.wotState = state }
                    if case .complete = state {
                        let s = await ExtendedNetworkRepository.shared.summary()
                        await MainActor.run { self.wotSummary = s }
                    }
                }
            }
        }
        .onDisappear { wotStateTask?.cancel() }
    }

    // MARK: - Filters tab

    private var filtersTab: some View {
        @Bindable var prefs = prefs
        return VStack(alignment: .leading, spacing: 16) {
            section(title: "Filters") {
                Toggle("Spam filter", isOn: $prefs.spamFilterEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                Text("Hides replies in notifications and threads when an on-device classifier flags the author as a spammer. Replies stay scoreable; only display is gated.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.onSurfaceVariant)
                    .padding(.bottom, 4)

                Toggle("Web of Trust", isOn: $prefs.wotFilterEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: theme.primary))
                Text("Drops events from authors outside your extended network (your follows + their follows, threshold 10). Profiles, follow lists, and DMs are exempt.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            }

            section(title: "Network") {
                wotStatusRow
                Button {
                    Task { await ExtendedNetworkRepository.shared.recompute() }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Recompute network")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.primary)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .disabled(wotIsRunning)
            }
        }
    }

    private var wotIsRunning: Bool {
        switch wotState {
        case .fetchingFollowLists, .buildingGraph: return true
        case .idle, .complete, .failed: return false
        }
    }

    private var wotStatusRow: some View {
        HStack(spacing: 8) {
            switch wotState {
            case .idle:
                if wotSummary.computedAt == 0 {
                    Text("Not computed yet").foregroundStyle(theme.palette.onSurfaceVariant)
                } else {
                    Text("\(wotSummary.qualifiedCount) qualified · computed \(timeAgo(wotSummary.computedAt))")
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                }
            case .fetchingFollowLists(let fetched, let total):
                ProgressView()
                Text("Fetching follow lists \(fetched)/\(total)")
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            case .buildingGraph(let processed, let total):
                ProgressView()
                Text("Building graph \(processed)/\(total)")
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            case .complete(let n):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Complete · \(n) qualified")
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason).foregroundStyle(theme.palette.onSurfaceVariant)
            }
            Spacer()
        }
        .font(.system(size: 13))
    }

    // MARK: - Words tab

    private var wordsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            section(title: "Add muted word") {
                HStack(spacing: 8) {
                    TextField("e.g. crypto", text: $newWord)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(theme.palette.surfaceVariant)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Button("Add") {
                        let word = newWord
                        newWord = ""
                        mutes.addMutedWord(word)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(theme.primary)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Substring match on note content; case-insensitive. Hidden in feed and notifications.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            }

            section(title: "Muted words") {
                if mutes.mutedWords.isEmpty {
                    Text("No muted words")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                } else {
                    ForEach(Array(mutes.mutedWords).sorted(), id: \.self) { word in
                        HStack {
                            Text(word).font(.system(size: 15))
                            Spacer()
                            Button {
                                mutes.removeMutedWord(word)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(theme.palette.onSurfaceVariant)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    // MARK: - Users tab

    private var usersTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            section(title: "Blocked users") {
                if mutes.blockedPubkeys.isEmpty {
                    Text("No blocked users")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                } else {
                    ForEach(Array(mutes.blockedPubkeys).sorted(), id: \.self) { pk in
                        blockedRow(pk)
                    }
                }
            }
        }
    }

    private func blockedRow(_ pubkey: String) -> some View {
        let profile = ProfileRepository.shared.get(pubkey)
        return HStack(spacing: 12) {
            CachedAvatarView(url: profile?.picture, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.displayString ?? truncated(pubkey))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(truncated(pubkey))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.palette.onSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer()
            Button("Unblock") {
                mutes.unblockUser(pubkey)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.primary)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func truncated(_ pubkey: String) -> String {
        guard pubkey.count > 16 else { return pubkey }
        return Nip19.shortNpub(hex: pubkey)
    }

    private func timeAgo(_ epoch: Int) -> String {
        let seconds = Int(Date().timeIntervalSince1970) - epoch
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.onSurfaceVariant)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
