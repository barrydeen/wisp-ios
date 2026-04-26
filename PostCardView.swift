import SwiftUI

struct PostCardView: View {
    let event: NostrEvent
    let profile: ProfileData?
    let profiles: [String: ProfileData]
    var engagement: EngagementCounts? = nil
    var onProfileTap: ((String) -> Void)? = nil
    var onNoteTap: ((String) -> Void)? = nil
    var onHashtagTap: ((String) -> Void)? = nil
    @Environment(WalletStore.self) private var walletStore: WalletStore?
    @State private var showZap = false
    @State private var expanded = false
    @State private var showReactionPicker = false
    @State private var showEmojiLibrary = false
    @State private var showAddToList = false
    @State private var zapPollOptionIndex: Int? = nil
    @State private var noteListRepo = NoteListRepository.shared
    @State private var sourceTracker = NoteSourceTracker.shared
    @State private var engagementRepo = EngagementRepository.shared

    private var myPubkey: String? { NostrKey.load()?.pubkey }
    private var iReactedEmoji: String? {
        guard let me = myPubkey,
              let counts = engagement else { return nil }
        return counts.reactors.first(where: { $0.pubkey == me })?.emoji
    }

    var body: some View {
        let resolved = resolveRepost()
        let displayEvent = resolved.event
        let displayProfile = resolved.profile

        VStack(alignment: .leading, spacing: 0) {
            if resolved.isRepost {
                repostBanner
            }

            HStack(alignment: .top, spacing: 12) {
                NavigationLink(value: ProfileRoute(pubkey: displayEvent.pubkey)) {
                    avatar(picture: displayProfile?.picture)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        NavigationLink(value: ProfileRoute(pubkey: displayEvent.pubkey)) {
                            EmojiText(
                                displayProfile?.displayString ?? npubShort(displayEvent.pubkey),
                                emojiMap: displayProfile?.emojiMap ?? [:],
                                textStyle: .subheadline,
                                weight: .semibold,
                                color: .label,
                                lineLimit: 1
                            )
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 0)

                        let powBits = Nip13.verifyDifficulty(displayEvent)
                        if powBits >= 16 {
                            PowBadge(bits: powBits)
                        }

                        Text(relativeTime(from: displayEvent.createdAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let nip05 = displayProfile?.nip05, !nip05.isEmpty {
                        Nip05Badge(nip05: nip05, pubkey: displayEvent.pubkey)
                    }

                    if !displayEvent.content.isEmpty || !displayEvent.tags.isEmpty {
                        RichContentView(
                            content: displayEvent.content,
                            tags: displayEvent.tags,
                            profiles: profiles,
                            onProfileTap: onProfileTap,
                            onNoteTap: onNoteTap,
                            onHashtagTap: onHashtagTap
                        )
                        .padding(.top, 2)
                    }

                    if displayEvent.kind == Nip88.kindPoll || displayEvent.kind == Nip69.kindZapPoll {
                        PollSection(
                            pollEvent: displayEvent,
                            onCastVote: { optionIds in handleCastVote(displayEvent, optionIds: optionIds) },
                            onZapVote: { idx in
                                zapPollOptionIndex = idx
                                showZap = true
                            }
                        )
                    }

                    if let topZapper = engagement?.zappers.max(by: { $0.sats < $1.sats }) {
                        TopZapperPill(
                            zapper: topZapper,
                            profile: profiles[topZapper.pubkey]
                        ) {
                            onProfileTap?(topZapper.pubkey)
                        }
                        .padding(.top, 8)
                    }

                    actionBar
                        .padding(.top, 8)

                    if expanded {
                        NoteDetailsPanel(
                            zappers: engagement?.zappers ?? [],
                            reactors: engagement?.reactors ?? [],
                            reposters: engagement?.reposters ?? [],
                            relays: combinedRelays(for: displayEvent.id),
                            profiles: profiles,
                            onProfileTap: onProfileTap
                        )
                        .padding(.top, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .contentShape(Rectangle())
        .onAppear {
            let displayed = resolveRepost().event
            if displayed.kind == Nip88.kindPoll || displayed.kind == Nip69.kindZapPoll {
                PollTallyRepository.shared.markVisible(pollEvent: displayed)
            }
        }
        .sheet(isPresented: $showZap) {
            if let store = walletStore {
                let target = resolveRepost().event
                let targetProfile = resolveRepost().profile
                let extraTags: [[String]] = zapPollOptionIndex.map { [["poll_option", String($0)]] } ?? []
                let pollOptionIdx = zapPollOptionIndex
                ZapSheet(
                    store: store,
                    recipientPubkey: target.pubkey,
                    recipientLud16: targetProfile?.lud16,
                    recipientName: targetProfile?.displayString,
                    eventId: target.id,
                    extraTags: extraTags,
                    onSuccess: { sats in
                        if target.kind == Nip69.kindZapPoll, let idx = pollOptionIdx,
                           let me = NostrKey.load() {
                            PollTallyRepository.shared.applyOptimisticZapVote(
                                pollEvent: target,
                                optionIndex: idx,
                                voterPubkey: me.pubkey,
                                sats: sats,
                                ts: Int(Date().timeIntervalSince1970)
                            )
                        }
                    },
                    dismiss: {
                        showZap = false
                        zapPollOptionIndex = nil
                    }
                )
            }
        }
        .sheet(isPresented: $showAddToList) {
            if let keypair = NostrKey.load() {
                NavigationStack {
                    AddToNoteListSheet(keypair: keypair, event: resolveRepost().event)
                }
            }
        }
    }

    // MARK: - Repost Banner

    private var repostBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.2.squarepath")
                .font(.system(size: 12))
            Text("\(profile?.displayString ?? "Someone") reposted")
                .font(.caption)
        }
        .foregroundStyle(Color.wispRepostColor)
        .padding(.leading, 68)
        .padding(.top, 8)
    }

    // MARK: - Avatar

    private func avatar(picture: String?) -> some View {
        CachedAvatarView(url: picture, size: 40)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 0) {
            actionItem(icon: "bubble.right", count: engagement?.replies)
            Spacer()
            heartAction
            Spacer()
            actionItem(
                icon: "arrow.2.squarepath",
                count: engagement?.reposts,
                tint: (engagement?.reposts ?? 0) > 0 ? Color.wispRepostColor : nil
            )
            Spacer()
            Button {
                showZap = true
            } label: {
                actionItem(
                    icon: "bolt.fill",
                    label: zapLabel(engagement?.zapSats),
                    tint: (engagement?.zapSats ?? 0) > 0 ? Color.wispZapColor : nil
                )
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                showAddToList = true
            } label: {
                let target = resolveRepost().event
                let isBookmarked = !noteListRepo.listsContaining(noteId: target.id).isEmpty
                actionItem(
                    icon: isBookmarked ? "bookmark.fill" : "bookmark",
                    count: nil,
                    tint: isBookmarked ? Color.wispPrimary : nil
                )
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.secondary)
    }

    private var heartAction: some View {
        let reacted = iReactedEmoji != nil
        return Button {
            showReactionPicker = true
        } label: {
            actionItem(
                icon: reacted ? "heart.fill" : "heart",
                count: engagement?.reactions,
                tint: reacted ? .pink : nil
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showReactionPicker, arrowEdge: .top) {
            EmojiReactionPicker(
                onSelect: { picked in
                    showReactionPicker = false
                    sendReaction(picked)
                },
                onPlus: {
                    showReactionPicker = false
                    showEmojiLibrary = true
                }
            )
            .presentationCompactAdaptation(.popover)
        }
        .sheet(isPresented: $showEmojiLibrary) {
            EmojiLibrarySheet(mode: .pickForReaction { picked in
                showEmojiLibrary = false
                sendReaction(picked)
            })
        }
    }

    private func sendReaction(_ picked: PickedEmoji) {
        guard let keypair = NostrKey.load() else { return }
        let target = resolveRepost().event
        NSLog("[Reaction] sendReaction picked=%@ targetId=%@", picked.frequencyKey, target.id.prefix(8) as CVarArg)
        Task {
            do {
                try await ReactionSender.shared.react(to: target, keypair: keypair, picked: picked)
                NSLog("[Reaction] react succeeded")
            } catch {
                NSLog("[Reaction] react failed: %@", String(describing: error))
            }
        }
    }

    private func combinedRelays(for eventId: String) -> [String] {
        var seenHosts = Set<String>()
        var ordered: [String] = []
        let raw = (engagement?.seenRelays ?? []).union(sourceTracker.relays(for: eventId))
        for url in raw {
            let host = (URL(string: url)?.host ?? url).lowercased()
            if seenHosts.insert(host).inserted { ordered.append(url) }
        }
        return ordered.sorted { ($0.lowercased()) < ($1.lowercased()) }
    }

    private func actionItem(icon: String, count: Int? = nil, label: String? = nil, tint: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 15))
            if let label, !label.isEmpty {
                Text(label).font(.caption)
            } else if let count, count > 0 {
                Text(formatCount(count)).font(.caption)
            }
        }
        .foregroundStyle(tint ?? .secondary)
        .frame(height: 28)
    }

    private func zapLabel(_ sats: Int64?) -> String? {
        guard let sats, sats > 0 else { return nil }
        return CurrencyFormatter.short(sats: sats)
    }

    private func formatCount(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: String(format: "%.1fk", Double(n) / 1_000)
        default: "\(n)"
        }
    }

    // MARK: - Helpers

    private struct ResolvedPost {
        let event: NostrEvent
        let profile: ProfileData?
        let isRepost: Bool
    }

    private func resolveRepost() -> ResolvedPost {
        if event.kind == 6, !event.content.isEmpty,
           let data = event.content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = NostrEvent(json: json) {
            return ResolvedPost(
                event: inner,
                profile: profiles[inner.pubkey],
                isRepost: true
            )
        }
        return ResolvedPost(event: event, profile: profile, isRepost: false)
    }

    private func npubShort(_ pubkey: String) -> String {
        String(pubkey.prefix(8)) + "\u{2026}"
    }

    private func handleCastVote(_ pollEvent: NostrEvent, optionIds: [String]) {
        guard let keypair = NostrKey.load() else { return }
        Task { _ = await PollVoteSender.castVote(pollEvent: pollEvent, optionIds: optionIds, keypair: keypair) }
    }
}

// MARK: - Top Zapper Pill

private struct TopZapperPill: View {
    let zapper: Zapper
    let profile: ProfileData?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                CachedAvatarView(url: profile?.picture, size: 18)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11))
                Text(CurrencyFormatter.short(sats: zapper.sats))
                    .font(.caption2.weight(.semibold))
                if !zapper.message.isEmpty {
                    Text(zapper.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(
                Capsule().stroke(Color.wispZapColor.opacity(0.3), lineWidth: 1)
            )
            .foregroundStyle(Color.wispZapColor)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Note Details Panel

private struct NoteDetailsPanel: View {
    let zappers: [Zapper]
    let reactors: [Reactor]
    let reposters: [String]
    let relays: [String]
    let profiles: [String: ProfileData]
    let onProfileTap: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !zappers.isEmpty {
                zapsSection
            }

            if !reposters.isEmpty {
                if !zappers.isEmpty { sectionDivider }
                repostsSection
            }

            if !reactors.isEmpty {
                if !zappers.isEmpty || !reposters.isEmpty { sectionDivider }
                reactionsSection
            }

            if !relays.isEmpty {
                if !zappers.isEmpty || !reposters.isEmpty || !reactors.isEmpty { sectionDivider }
                seenOnSection
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.vertical, 6)
    }

    private var zapsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(zappers.sorted(by: { $0.sats > $1.sats }), id: \.self) { zap in
                Button {
                    onProfileTap?(zap.pubkey)
                } label: {
                    HStack(spacing: 8) {
                        CachedAvatarView(url: profiles[zap.pubkey]?.picture, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            let label = !zap.message.isEmpty
                                ? zap.message
                                : (profiles[zap.pubkey]?.displayString ?? short(zap.pubkey))
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 3) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 11))
                            Text(CurrencyFormatter.short(sats: zap.sats))
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(Color.wispZapColor)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var repostsSection: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.2.squarepath")
                .font(.system(size: 14))
                .foregroundStyle(Color.wispRepostColor)
                .frame(width: 22)
            StackedAvatarRow(
                pubkeys: reposters,
                profiles: profiles,
                onProfileTap: onProfileTap
            )
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var reactionsSection: some View {
        let grouped = Dictionary(grouping: reactors, by: { $0.emoji })
        let sortedKeys = grouped.keys.sorted { (grouped[$0]?.count ?? 0) > (grouped[$1]?.count ?? 0) }
        let emojiMap = EmojiRepository.shared.resolvedCustomMap
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(sortedKeys, id: \.self) { emoji in
                let group = grouped[emoji] ?? []
                HStack(alignment: .center, spacing: 8) {
                    EmojiText(
                        displayEmoji(emoji),
                        emojiMap: emojiMap,
                        textStyle: .body,
                        lineLimit: 1
                    )
                    .frame(width: 22)
                    StackedAvatarRow(
                        pubkeys: group.map(\.pubkey),
                        profiles: profiles,
                        onProfileTap: onProfileTap
                    )
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var seenOnSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Seen on")
                .font(.caption2)
                .foregroundStyle(.secondary)
            FlowingChips(items: relays.map { hostname(of: $0) })
        }
    }

    private func displayEmoji(_ raw: String) -> String {
        switch raw {
        case "+", "": return "❤️"
        case "-": return "👎"
        default: return raw
        }
    }

    private func short(_ pubkey: String) -> String {
        String(pubkey.prefix(8)) + "\u{2026}"
    }

    private func hostname(of relay: String) -> String {
        URL(string: relay)?.host ?? relay
    }
}

// MARK: - Stacked Avatars

private struct StackedAvatarRow: View {
    let pubkeys: [String]
    let profiles: [String: ProfileData]
    let onProfileTap: ((String) -> Void)?
    var max: Int = 5
    var size: CGFloat = 24
    var overlap: CGFloat = 10

    var body: some View {
        let visible = Array(pubkeys.prefix(max))
        let extra = pubkeys.count - visible.count
        HStack(spacing: -overlap) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, pk in
                Button {
                    onProfileTap?(pk)
                } label: {
                    CachedAvatarView(url: profiles[pk]?.picture, size: size)
                        .overlay(
                            Circle().stroke(Color.wispBackground, lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, overlap + 4)
            }
        }
    }
}

// MARK: - Simple wrapping row of small text chips (for relay hostnames)

private struct FlowingChips: View {
    let items: [String]

    var body: some View {
        // Lightweight wrapping using LazyVGrid with adaptive columns.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 80), spacing: 6, alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.15))
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

func relativeTime(from timestamp: Int) -> String {
    let seconds = Int(Date().timeIntervalSince1970) - timestamp
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return "\(seconds / 3600)h" }
    if seconds < 604_800 { return "\(seconds / 86400)d" }
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))
}

