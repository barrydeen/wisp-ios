import SwiftUI

/// Single-event notification row. Mirrors Android's `ZenNotificationRow`: one
/// row per event, no grouping. Type icon on the left, avatar, name + action
/// verb, timestamp on the right. Tap to expand for non-DM types.
struct NotificationRowView: View {
    let item: FlatNotificationItem
    let viewModel: NotificationsViewModel
    let onPeerTap: (String) -> Void
    let onDmTap: (String) -> Void
    var onNoteTap: ((String, String?) -> Void)? = nil

    @State private var expanded = false
    @State private var profiles: [String: ProfileData] = [:]
    @State private var sendingReply = false

    private let repo = NotificationRepository.shared
    private let profileRepo = ProfileRepository.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedRow
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
                .onTapGesture { handleTap() }

            if expanded { expandedContent }
        }
        .padding(.vertical, 10)
        .background(rowBackground)
        .task(id: item.id) { await hydrateProfiles() }
    }

    // MARK: - Collapsed row

    private var collapsedRow: some View {
        HStack(alignment: .center, spacing: 8) {
            NotificationTypeIcon(item: item)

            CachedAvatarView(url: profiles[item.actorPubkey]?.picture, size: 32)
                .onTapGesture { onPeerTap(item.actorPubkey) }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(displayName(item.actorPubkey))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(NotificationStyle.actionText(item.kind))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                voteOptionLabel
                if let snippet = referencedSnippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Text(relativeTime(from: item.timestamp))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var voteOptionLabel: some View {
        // NIP-88 poll votes: show selected option labels.
        if item.kind == .pollVote, !item.voteOptionIds.isEmpty,
           let pollEvent = repo.event(forId: item.referencedEventId) {
            let options = Nip88.parsePollOptions(pollEvent)
            let labels = item.voteOptionIds.compactMap { id in
                options.first(where: { $0.id == id })?.label
            }
            if !labels.isEmpty {
                Text(labels.joinToString())
                    .font(.caption)
                    .foregroundStyle(Color.wispPrimary)
                    .lineLimit(1)
            }
        }
        // Kind-6969 zap polls: show selected option label.
        if item.kind == .zap, let idx = item.zapPollOptionIndex,
           let pollEvent = repo.event(forId: item.referencedEventId) {
            let opts = Nip69.parseZapPollOptions(pollEvent)
            if let label = opts.first(where: { $0.index == idx })?.label {
                Text("voted: \(label)")
                    .font(.caption)
                    .foregroundStyle(Color.wispPrimary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Expanded content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch item.kind {
            case .dm:
                EmptyView()
            case .reply:
                replyExpansion
            case .quote:
                quoteExpansion
            case .mention:
                mentionExpansion
            case .reaction, .repost, .pollVote:
                referencedNoteExpansion
            case .zap:
                zapExpansion
            }
        }
        .padding(.top, 10)
    }

    /// Standard avatar-aligned indent for caption text + inline-reply
    /// blocks inside the expansion. PostCardViews intentionally skip
    /// this — they render at the row's full content width so MediaGridView
    /// (which keys its layout off the screen edge) doesn't overflow.
    private static let captionLeadingIndent: CGFloat = 12 + 42

    /// Composer pill aligns with PostCardView's content edge (which sits
    /// at +16 from the screen via the card's internal padding). 2 here
    /// + the composer's own 14pt internal padding = 16pt visual offset,
    /// so the pill ends matching the post text width above it instead of
    /// being indented under the avatar like caption snippets.
    private static let composerSidePadding: CGFloat = 2

    @ViewBuilder
    private var replyExpansion: some View {
        if !item.referencedEventId.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("replying to your note")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                QuotedNoteView(
                    eventId: item.referencedEventId,
                    relayHints: [],
                    profiles: profiles,
                    onProfileTap: onPeerTap,
                    onNoteTap: { id in onNoteTap?(id, nil) }
                )
            }
            .padding(.leading, Self.captionLeadingIndent)
            .padding(.trailing, 12)
        }
        if let actorEvent = repo.event(forId: item.id) {
            Button {
                onNoteTap?(actorEvent.id, actorEvent.pubkey)
            } label: {
                PostCardView(
                    event: actorEvent,
                    profile: profiles[actorEvent.pubkey],
                    profiles: profiles
                )
            }
            .buttonStyle(.plain)
        }
        inlineReplyList(targetId: item.id)
        if let actorEvent = repo.event(forId: item.id) {
            NotificationComposer(
                targetEvent: actorEvent,
                sending: $sendingReply,
                viewModel: viewModel
            )
            .padding(.horizontal, Self.composerSidePadding)
        }
    }

    @ViewBuilder
    private var quoteExpansion: some View {
        let actorId = item.actorEventId ?? item.id
        if let actor = repo.event(forId: actorId) {
            Button {
                onNoteTap?(actor.id, actor.pubkey)
            } label: {
                PostCardView(
                    event: actor,
                    profile: profiles[actor.pubkey],
                    profiles: profiles
                )
            }
            .buttonStyle(.plain)
        }
        if let qid = item.quoteEventId, !qid.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("quoted your note")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                QuotedNoteView(
                    eventId: qid,
                    relayHints: item.relayHints,
                    profiles: profiles,
                    onProfileTap: onPeerTap,
                    onNoteTap: { id in onNoteTap?(id, nil) }
                )
            }
            .padding(.leading, Self.captionLeadingIndent)
            .padding(.trailing, 12)
        }
        inlineReplyList(targetId: actorId)
        if let actor = repo.event(forId: actorId) {
            NotificationComposer(
                targetEvent: actor,
                sending: $sendingReply,
                viewModel: viewModel
            )
            .padding(.horizontal, Self.composerSidePadding)
        }
    }

    @ViewBuilder
    private var mentionExpansion: some View {
        if let actor = repo.event(forId: item.id) {
            Button {
                onNoteTap?(actor.id, actor.pubkey)
            } label: {
                PostCardView(
                    event: actor,
                    profile: profiles[actor.pubkey],
                    profiles: profiles
                )
            }
            .buttonStyle(.plain)
            inlineReplyList(targetId: item.id)
            NotificationComposer(
                targetEvent: actor,
                sending: $sendingReply,
                viewModel: viewModel
            )
            .padding(.horizontal, Self.composerSidePadding)
        }
    }

    @ViewBuilder
    private var referencedNoteExpansion: some View {
        if !item.referencedEventId.isEmpty {
            QuotedNoteView(
                eventId: item.referencedEventId,
                relayHints: [],
                profiles: profiles,
                onProfileTap: onPeerTap,
                onNoteTap: { id in onNoteTap?(id, nil) }
            )
            .padding(.leading, Self.captionLeadingIndent)
            .padding(.trailing, 12)
        }
    }

    @ViewBuilder
    private var zapExpansion: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !item.referencedEventId.isEmpty {
                QuotedNoteView(
                    eventId: item.referencedEventId,
                    relayHints: [],
                    profiles: profiles,
                    onProfileTap: onPeerTap,
                    onNoteTap: { id in onNoteTap?(id, nil) }
                )
            }
            let msg = item.zapMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty {
                Text("\u{201C}\(msg)\u{201D}")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.leading, Self.captionLeadingIndent)
        .padding(.trailing, 12)
    }

    @ViewBuilder
    private func inlineReplyList(targetId: String) -> some View {
        let optimistic = repo.inlineReplies[targetId] ?? []
        if !optimistic.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(optimistic, id: \.id) { e in
                    Button {
                        onNoteTap?(e.id, e.pubkey)
                    } label: {
                        PostCardView(
                            event: e,
                            profile: profiles[e.pubkey] ?? ProfileRepository.shared.get(e.pubkey),
                            profiles: profiles
                        )
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

    private var referencedSnippet: String? {
        let raw: String?
        switch item.kind {
        case .reply:
            raw = repo.event(forId: item.id)?.content
        case .mention:
            raw = repo.event(forId: item.id)?.content
        case .quote:
            raw = repo.event(forId: item.actorEventId ?? item.id)?.content
        case .pollVote:
            raw = repo.event(forId: item.referencedEventId)?.content
        case .dm, .reaction, .repost, .zap:
            return nil
        }
        return raw.map {
            resolveNostrMentions($0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
        }
    }

    /// Replaces `nostr:` bech32 references in `content` with short human-readable
    /// forms so notification snippets never expose raw IDs:
    /// - `npub1…` / `nprofile1…` → `@displayname`
    /// - `nevent1…` / `note1…` → `@author's note` if the author resolves, else `[note]`
    /// - `naddr1…` → `@author's post` if the author resolves, else `[post]`
    /// The bare-bech32 alternative excludes URL-context characters from the lookbehind
    /// (`/`, `:`, `.`, `@`) and rejects matches followed by `.letter` (TLDs) so a
    /// bech32 embedded in a URL like `https://npub1xxx.blossom.band/…` is left alone.
    private func resolveNostrMentions(_ content: String) -> String {
        let pattern = #"nostr:(?:npub1|nprofile1|nevent1|note1|naddr1)[a-z0-9]+|(?<![\w/:.@])(?:npub1|nprofile1|nevent1|note1|naddr1)[a-z0-9]{50,}(?!\w|\.[a-zA-Z])"#
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
            switch Nip19.decodeNostrUri(uri) {
            case .profileRef(let pk, _):
                out += "@\(displayName(pk))"
            case .noteRef(let eid, _, let author):
                let pk = author ?? repo.event(forId: eid)?.pubkey
                out += pk.map { "@\(displayName($0))'s note" } ?? "[note]"
            case .addressRef(_, _, let author, _):
                out += author.map { "@\(displayName($0))'s post" } ?? "[post]"
            case .none:
                out += token
            }
            lastEnd = match.range.upperBound
        }
        out += ns.substring(from: lastEnd)
        return out
    }

    private func handleTap() {
        if item.kind == .dm, let key = item.dmConversationKey {
            onDmTap(key)
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
    }

    private func displayName(_ pubkey: String) -> String {
        profiles[pubkey]?.displayString
            ?? profileRepo.get(pubkey)?.displayString
            ?? Nip19.shortNpub(hex: pubkey)
    }

    private func hydrateProfiles() async {
        var needed = Set<String>([item.actorPubkey])
        if let peer = item.dmPeerPubkey { needed.insert(peer) }

        // Walk the actor event's tags + content for any referenced pubkeys.
        // The actor's reply/mention event contains `p` tags for everyone in the
        // thread, and the body may inline `nostr:nprofile1...` URIs that aren't
        // tagged. Both should resolve to a real handle, not a truncated pubkey.
        let actorEventId: String?
        switch item.kind {
        case .reply, .mention:
            actorEventId = item.id
        case .quote:
            actorEventId = item.actorEventId ?? item.id
        default:
            actorEventId = nil
        }
        if let id = actorEventId, let e = repo.event(forId: id) {
            for tag in e.tags where tag.first == "p" && tag.count >= 2 {
                needed.insert(tag[1])
            }
            for pk in extractPubkeysFromContent(e.content) {
                needed.insert(pk)
            }
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

        let pubkeys = Array(needed)
        profiles = profileRepo.getAll(pubkeys)

        let resolved = await profileRepo.ensure(pubkeys)
        profiles = resolved
    }

    /// Pull every pubkey referenced from an event's body — direct profile
    /// references (`npub1`/`nprofile1`) plus the author fields of any
    /// `nevent`/`naddr`/`note1` embedded in the content. URL-context
    /// exclusions in the lookbehind/lookahead keep bech32 inside URLs
    /// from being mistaken for a mention.
    private func extractPubkeysFromContent(_ content: String) -> [String] {
        let pattern = #"nostr:(?:npub1|nprofile1|nevent1|note1|naddr1)[a-z0-9]+|(?<![\w/:.@])(?:npub1|nprofile1|nevent1|note1|naddr1)[a-z0-9]{50,}(?!\w|\.[a-zA-Z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = content as NSString
        let range = NSRange(location: 0, length: ns.length)
        var seen = Set<String>()
        var out: [String] = []
        regex.enumerateMatches(in: content, range: range) { m, _, _ in
            guard let m else { return }
            let token = ns.substring(with: m.range)
            let uri = token.lowercased().hasPrefix("nostr:") ? token : "nostr:\(token)"
            let pk: String?
            switch Nip19.decodeNostrUri(uri) {
            case .profileRef(let p, _): pk = p
            case .noteRef(let eid, _, let author): pk = author ?? repo.event(forId: eid)?.pubkey
            case .addressRef(_, _, let author, _): pk = author
            case .none: pk = nil
            }
            if let pk, seen.insert(pk).inserted {
                out.append(pk)
            }
        }
        return out
    }
}

private extension Array where Element == String {
    func joinToString() -> String { joined(separator: ", ") }
}

/// Inline rendering for a single reaction emoji. Renders the cached bitmap when
/// the URL is known and loaded; falls back to the literal text (which may be a
/// unicode glyph or the original `:shortcode:` while loading).
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
