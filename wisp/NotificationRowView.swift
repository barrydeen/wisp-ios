import SwiftUI

struct NotificationRowView: View {
    let group: NotificationGroup
    let viewModel: NotificationsViewModel
    let onPeerTap: (String) -> Void
    let onDmTap: (String) -> Void
    var onNoteTap: ((String) -> Void)? = nil

    @State private var expanded = false
    @State private var profiles: [String: ProfileData] = [:]
    @State private var sendingReply = false
    @ObservedObject private var emojiCache = EmojiImageCache.shared

    private let repo = NotificationRepository.shared
    private let profileRepo = ProfileRepository.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedRow
                .contentShape(Rectangle())
                .onTapGesture { handleTap() }

            if expanded { expandedContent }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(rowBackground)
        .task(id: group.id) { await hydrateProfiles() }
    }

    // MARK: - Collapsed row

    private var collapsedRow: some View {
        HStack(alignment: .top, spacing: 10) {
            NotificationTypeIcon(kind: group.kind)
                .padding(.top, 2)

            avatarsCluster

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    headline
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Text(relativeTime(from: group.latestTs))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let snippet = referencedSnippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var avatarsCluster: some View {
        // Show up to 2 actor avatars; group counts > 1 shown as "+N" overlay.
        let pubkeys = primaryActors().prefix(2)
        return HStack(spacing: -6) {
            ForEach(Array(pubkeys.enumerated()), id: \.offset) { _, pk in
                CachedAvatarView(url: profiles[pk]?.picture, size: 32)
                    .overlay(Circle().stroke(Color.wispBackground, lineWidth: 2))
            }
        }
    }

    // MARK: - Expanded content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch group {
            case .reactions(_, let refId, let emojiByActor, let emojiUrlByActor, let zaps, let reposters, _):
                reactionsExpansion(
                    refId: refId,
                    emojiByActor: emojiByActor,
                    emojiUrlByActor: emojiUrlByActor,
                    zaps: zaps,
                    reposters: reposters
                )
            case .reply(let id, _, let replyEventId, let refEventId, _, let hints):
                replyExpansion(groupId: id, replyEventId: replyEventId, refEventId: refEventId, hints: hints)
            case .quote(let id, _, let actorEventId, let quoteEventId, _, let hints):
                quoteExpansion(groupId: id, actorEventId: actorEventId, quoteEventId: quoteEventId, hints: hints)
            case .mention(let id, _, let eventId, _, _):
                mentionExpansion(groupId: id, eventId: eventId)
            case .pollVotes(_, let refId, let votersByOptionId, _):
                pollVotesExpansion(refId: refId, votersByOptionId: votersByOptionId)
            case .dm:
                EmptyView()
            }
        }
        .padding(.top, 10)
        .padding(.leading, 42)
    }

    private func pollVotesExpansion(refId: String, votersByOptionId: [String: [String]]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            QuotedNoteView(eventId: refId, relayHints: [], profiles: profiles, onProfileTap: onPeerTap, onNoteTap: onNoteTap)
            // Resolve option labels from the cached poll event when available.
            let pollEvent = repo.event(forId: refId)
            let labelsById: [String: String] = {
                guard let pollEvent else { return [:] }
                var out: [String: String] = [:]
                for opt in Nip88.parsePollOptions(pollEvent) { out[opt.id] = opt.label }
                return out
            }()
            ForEach(votersByOptionId.keys.sorted(), id: \.self) { optionId in
                let voters = votersByOptionId[optionId] ?? []
                HStack(spacing: 6) {
                    Text(labelsById[optionId] ?? optionId)
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 4)
                    Text("\(voters.count) vote\(voters.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reactionsExpansion(
        refId: String,
        emojiByActor: [String: String],
        emojiUrlByActor: [String: String],
        zaps: [ZapEntry],
        reposters: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            QuotedNoteView(eventId: refId, relayHints: [], profiles: profiles, onProfileTap: onPeerTap, onNoteTap: onNoteTap)
            if !zaps.isEmpty {
                let total = zaps.reduce(Int64(0)) { $0 + $1.sats }
                Text("\(NotificationStyle.formatSats(total)) sats from \(zaps.count) zap\(zaps.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Color.wispZapColor)
            }
            if !reposters.isEmpty {
                Text("\(reposters.count) repost\(reposters.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Color.wispRepostColor)
            }
            if !emojiByActor.isEmpty {
                let counts = Dictionary(grouping: emojiByActor.values, by: { $0 }).mapValues { $0.count }
                HStack(spacing: 6) {
                    ForEach(counts.sorted(by: { $0.value > $1.value }).prefix(6), id: \.key) { entry in
                        HStack(spacing: 3) {
                            EmojiInlineView(
                                emoji: entry.key,
                                url: urlForEmoji(entry.key, emojiByActor: emojiByActor, emojiUrlByActor: emojiUrlByActor),
                                height: 14
                            )
                            Text("\(entry.value)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.wispSurfaceVariant.opacity(0.5))
                        .clipShape(Capsule())
                    }
                }
            }
        }
    }

    private func urlForEmoji(
        _ emoji: String,
        emojiByActor: [String: String],
        emojiUrlByActor: [String: String]
    ) -> String? {
        for (actor, e) in emojiByActor where e == emoji {
            if let url = emojiUrlByActor[actor] { return url }
        }
        return nil
    }

    private func replyExpansion(
        groupId: String,
        replyEventId: String,
        refEventId: String?,
        hints: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let refEventId {
                Text("replying to your note")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                QuotedNoteView(eventId: refEventId, relayHints: [], profiles: profiles, onProfileTap: onPeerTap, onNoteTap: onNoteTap)
            }
            if let actorEvent = repo.event(forId: replyEventId) {
                Button {
                    onNoteTap?(actorEvent.id)
                } label: {
                    PostCardView(
                        event: actorEvent,
                        profile: profiles[actorEvent.pubkey],
                        profiles: profiles
                    )
                    .padding(.horizontal, -12)
                }
                .buttonStyle(.plain)
            }
            inlineReplyList(groupId: groupId)
            if let actorEvent = repo.event(forId: replyEventId) {
                NotificationComposer(
                    targetEvent: actorEvent,
                    groupId: groupId,
                    sending: $sendingReply,
                    viewModel: viewModel
                )
            }
        }
    }

    private func quoteExpansion(
        groupId: String,
        actorEventId: String,
        quoteEventId: String,
        hints: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let actor = repo.event(forId: actorEventId) {
                Button {
                    onNoteTap?(actor.id)
                } label: {
                    PostCardView(
                        event: actor,
                        profile: profiles[actor.pubkey],
                        profiles: profiles
                    )
                    .padding(.horizontal, -12)
                }
                .buttonStyle(.plain)
            }
            if !quoteEventId.isEmpty {
                Text("quoted your note")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                QuotedNoteView(eventId: quoteEventId, relayHints: hints, profiles: profiles, onProfileTap: onPeerTap, onNoteTap: onNoteTap)
            }
            inlineReplyList(groupId: groupId)
            if let actor = repo.event(forId: actorEventId) {
                NotificationComposer(
                    targetEvent: actor,
                    groupId: groupId,
                    sending: $sendingReply,
                    viewModel: viewModel
                )
            }
        }
    }

    private func mentionExpansion(groupId: String, eventId: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let actor = repo.event(forId: eventId) {
                Button {
                    onNoteTap?(actor.id)
                } label: {
                    PostCardView(
                        event: actor,
                        profile: profiles[actor.pubkey],
                        profiles: profiles
                    )
                    .padding(.horizontal, -12)
                }
                .buttonStyle(.plain)
                inlineReplyList(groupId: groupId)
                NotificationComposer(
                    targetEvent: actor,
                    groupId: groupId,
                    sending: $sendingReply,
                    viewModel: viewModel
                )
            }
        }
    }

    @ViewBuilder
    private func inlineReplyList(groupId: String) -> some View {
        let optimistic = repo.inlineReplies[groupId] ?? []
        if !optimistic.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(optimistic, id: \.id) { e in
                    Button {
                        onNoteTap?(e.id)
                    } label: {
                        PostCardView(
                            event: e,
                            profile: profiles[e.pubkey] ?? ProfileRepository.shared.get(e.pubkey),
                            profiles: profiles
                        )
                        .padding(.horizontal, -12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Helpers

    private var rowBackground: some View {
        Group {
            if expanded {
                Color.wispSurfaceVariant.opacity(0.25)
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private var headline: some View {
        let actors = primaryActors()
        let firstName = actors.first.map(displayName) ?? "Someone"
        switch group {
        case .reactions(_, _, let emojiByActor, let emojiUrlByActor, let zaps, let reposters, _):
            if !zaps.isEmpty {
                let totalSats = zaps.reduce(Int64(0)) { $0 + $1.sats }
                let suffix = zaps.count == 1
                    ? "zapped \(NotificationStyle.formatSats(totalSats)) sats"
                    : "and \(zaps.count - 1) other\(zaps.count == 2 ? "" : "s") zapped \(NotificationStyle.formatSats(totalSats)) sats"
                Text("\(displayName(zaps[0].pubkey)) \(suffix)")
            } else if !reposters.isEmpty {
                let suffix = reposters.count == 1
                    ? "reposted"
                    : "and \(reposters.count - 1) other\(reposters.count == 2 ? "" : "s") reposted"
                Text("\(displayName(reposters[0])) \(suffix)")
            } else if !emojiByActor.isEmpty {
                let firstActor = emojiByActor.keys.first ?? ""
                let emoji = emojiByActor[firstActor] ?? "❤"
                let url = emojiUrlByActor[firstActor]
                if emojiByActor.count == 1 {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(displayName(firstActor)) reacted")
                        EmojiInlineView(emoji: emoji, url: url, height: 16)
                    }
                } else {
                    Text("\(displayName(firstActor)) and \(emojiByActor.count - 1) other\(emojiByActor.count == 2 ? "" : "s") reacted")
                }
            } else {
                Text(firstName)
            }
        case .reply: Text("\(firstName) replied")
        case .quote: Text("\(firstName) quoted")
        case .mention: Text("\(firstName) mentioned you")
        case .pollVotes(_, _, let map, _):
            let totalVoters = Set(map.values.flatMap { $0 }).count
            if totalVoters <= 1 {
                Text("\(firstName) voted on your poll")
            } else {
                Text("\(firstName) and \(totalVoters - 1) other\(totalVoters == 2 ? "" : "s") voted on your poll")
            }
        case .dm(_, _, _, _, let unread):
            if unread > 0 {
                Text("\(firstName) sent \(unread) message\(unread == 1 ? "" : "s")")
            } else {
                Text("\(firstName) messaged you")
            }
        }
    }

    private var referencedSnippet: String? {
        let raw: String?
        switch group {
        case .reply(_, _, let replyEventId, _, _, _):
            raw = repo.event(forId: replyEventId)?.content
        case .mention(_, _, let eventId, _, _):
            raw = repo.event(forId: eventId)?.content
        case .quote(_, _, let actorEventId, _, _, _):
            raw = repo.event(forId: actorEventId)?.content
        case .pollVotes(_, let refId, _, _):
            raw = repo.event(forId: refId)?.content
        case .dm, .reactions:
            return nil
        }
        return raw.map {
            resolveNostrMentions($0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
        }
    }

    /// Replaces `nostr:npub1…`, `nostr:nprofile1…`, and bare `npub1…` / `nprofile1…`
    /// tokens in `content` with `@displayname` using the already-resolved `profiles` dict.
    private func resolveNostrMentions(_ content: String) -> String {
        let pattern = #"nostr:(?:npub1|nprofile1)[a-z0-9]+|(?<!\w)(?:npub1|nprofile1)[a-z0-9]{50,}(?!\w)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return content }
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return content }
        var out = ""
        var lastEnd = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let token = ns.substring(with: match.range)
            let uri = token.lowercased().hasPrefix("nostr:") ? token : "nostr:\(token)"
            if case .profileRef(let pk, _)? = Nip19.decodeNostrUri(uri) {
                out += "@\(displayName(pk))"
            } else {
                out += token
            }
            lastEnd = match.range.upperBound
        }
        out += ns.substring(from: lastEnd)
        return out
    }

    private func primaryActors() -> [String] {
        switch group {
        case .reactions(_, _, let emojiByActor, _, let zaps, let reposters, _):
            var ordered: [String] = []
            for z in zaps where !ordered.contains(z.pubkey) { ordered.append(z.pubkey) }
            for k in reposters where !ordered.contains(k) { ordered.append(k) }
            for k in emojiByActor.keys where !ordered.contains(k) { ordered.append(k) }
            return ordered
        case .reply(_, let s, _, _, _, _),
             .quote(_, let s, _, _, _, _),
             .mention(_, let s, _, _, _):
            return [s]
        case .dm(_, let p, _, _, _):
            return [p]
        case .pollVotes(_, _, let map, _):
            var ordered: [String] = []
            for voters in map.values {
                for pk in voters where !ordered.contains(pk) { ordered.append(pk) }
            }
            return ordered
        }
    }

    private func handleTap() {
        if case .dm(_, _, let convKey, _, _) = group {
            onDmTap(convKey)
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
    }

    private func displayName(_ pubkey: String) -> String {
        profiles[pubkey]?.displayString
            ?? profileRepo.get(pubkey)?.displayString
            ?? (String(pubkey.prefix(8)) + "…")
    }

    private func hydrateProfiles() async {
        var needed = Set<String>(primaryActors())

        // Walk the actor event's tags + content for any referenced pubkeys.
        // The actor's reply / mention event contains `p` tags for everyone in
        // the thread, and the body may inline `nostr:nprofile1...` URIs that
        // aren't tagged. Both should resolve to a real handle in the rendered
        // row, not a truncated pubkey fallback.
        let actorEventId: String?
        switch group {
        case .reply(_, _, let id, _, _, _): actorEventId = id
        case .mention(_, _, let id, _, _): actorEventId = id
        default: actorEventId = nil
        }
        if let id = actorEventId, let e = repo.event(forId: id) {
            for tag in e.tags where tag.first == "p" && tag.count >= 2 {
                needed.insert(tag[1])
            }
            for pk in extractPubkeysFromContent(e.content) {
                needed.insert(pk)
            }
            // Also pull pubkeys referenced in the parent note this reply quotes —
            // that's the surface the user reported renders as `@<8-hex>...`.
            for tag in e.tags where tag.first == "e" && tag.count >= 2 {
                if let parent = repo.event(forId: tag[1]) {
                    for ptag in parent.tags where ptag.first == "p" && ptag.count >= 2 {
                        needed.insert(ptag[1])
                    }
                    for pk in extractPubkeysFromContent(parent.content) {
                        needed.insert(pk)
                    }
                }
            }
        }

        // Hand the seed dict whatever's already cached so the first paint
        // doesn't flash truncated keys for the ones we have.
        let pubkeys = Array(needed)
        profiles = profileRepo.getAll(pubkeys)

        // Lazy-fetch any missing ones; reassigning `profiles` triggers a re-render.
        let resolved = await profileRepo.ensure(pubkeys)
        profiles = resolved
    }

    /// Pull `nostr:npub1.../nprofile1...` and bare bech32 pubkey references out
    /// of an event's body. Mirrors what `ContentParser` recognizes.
    private func extractPubkeysFromContent(_ content: String) -> [String] {
        let pattern = #"nostr:(?:npub1|nprofile1)[a-z0-9]+|(?<!\w)(?:npub1|nprofile1)[a-z0-9]{50,}(?!\w)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        var seen = Set<String>()
        var out: [String] = []
        regex.enumerateMatches(in: content, range: range) { m, _, _ in
            guard let m else { return }
            let token = ns.substring(with: m.range)
            let uri = token.lowercased().hasPrefix("nostr:") ? token : "nostr:\(token)"
            if case .profileRef(let pk, _)? = Nip19.decodeNostrUri(uri), seen.insert(pk).inserted {
                out.append(pk)
            }
        }
        return out
    }
}

/// Inline rendering for a single reaction emoji. Renders the cached bitmap when the URL is
/// known and loaded; falls back to the literal text (which may be a unicode glyph or the
/// original `:shortcode:` while loading).
struct EmojiInlineView: View {
    let emoji: String
    let url: String?
    let height: CGFloat
    @ObservedObject private var cache = EmojiImageCache.shared

    var body: some View {
        if let url, !url.isEmpty {
            if let img = cache.image(for: url) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(height: height)
            } else {
                Color.clear
                    .frame(width: height, height: height)
                    .onAppear { cache.ensureLoaded(url) }
            }
        } else {
            Text(emoji).font(.system(size: height))
        }
    }
}
