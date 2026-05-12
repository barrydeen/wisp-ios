import SwiftUI

@MainActor
final class QuotedNoteCache {
    static let shared = QuotedNoteCache()
    private var cache: [String: NostrEvent] = [:]
    private var inflight: [String: Task<NostrEvent?, Never>] = [:]

    private static let defaultRelays = [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://relay.nostr.band"
    ]

    /// Second-pass fallbacks consulted when the embedded hint + defaults come
    /// back empty. Picked for breadth — community / archive relays that often
    /// hold notes the headline relays have dropped.
    private static let extraRelays = [
        "wss://nostr.wine",
        "wss://relay.snort.social",
        "wss://offchain.pub",
        "wss://relay.nostr.bg",
        "wss://nostr-pub.wellorder.net",
        "wss://eden.nostr.land"
    ]

    func cached(eventId: String) -> NostrEvent? { cache[eventId] }

    func cache(_ event: NostrEvent) {
        cache[event.id] = event
    }

    /// First-attempt fetch. Checks the in-memory cache, then the local
    /// ObjectBox event store (kinds 1/6/20 are persisted on the home feed, so
    /// a quoted note the user has already scrolled past is free to retrieve),
    /// and finally fans out to the embedded hint + default relays.
    func fetch(eventId: String, relayHints: [String]) async -> NostrEvent? {
        if let cached = cache[eventId] { return cached }
        if let stored = await EventStore.shared.eventsByIds([eventId]).first {
            cache[eventId] = stored
            return stored
        }
        if let existing = inflight[eventId] { return await existing.value }
        return await runFetch(eventId: eventId, relayHints: relayHints, attempt: 0)
    }

    /// Forced retry — bumps the attempt counter and widens the relay set with
    /// the user's outbox-scored relays plus an extra fallback list. Used by
    /// the tap-to-retry affordance on the "Quoted note not found" card and by
    /// the view's one automatic redundancy retry.
    func refetch(eventId: String, relayHints: [String], attempt: Int) async -> NostrEvent? {
        if let cached = cache[eventId] { return cached }
        if let existing = inflight[eventId] { return await existing.value }
        return await runFetch(eventId: eventId, relayHints: relayHints, attempt: attempt)
    }

    private func runFetch(eventId: String, relayHints: [String], attempt: Int) async -> NostrEvent? {
        let task = Task<NostrEvent?, Never> { [weak self] in
            guard let self else { return nil }
            let relays = self.relayList(hints: relayHints, attempt: attempt)
            // Retries get a longer window — broader relay sets contain slower
            // peers (.onion, regional, archive) that need extra time.
            let timeout: TimeInterval = attempt == 0 ? 6 : 10
            let events = await RelayPool.query(
                relays: relays,
                filter: filterByIds(eventId: eventId),
                timeout: timeout
            )
            return events.first(where: { $0.id == eventId })
        }
        inflight[eventId] = task
        let result = await task.value
        inflight[eventId] = nil
        if let result {
            cache[eventId] = result
        }
        return result
    }

    /// Build the relay set for a given attempt. The hint (when present) and
    /// the small default list cover the common case on attempt 0. Higher
    /// attempts blend in the user's top-scored outbox relays (NIP-65 write
    /// relays of people they follow — likely to mirror notes the author
    /// reposted or interacted with) and an extra fallback list, widening the
    /// cap to 12 relays.
    private func relayList(hints: [String], attempt: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []

        func append(_ url: String) {
            guard let canon = RelayUrlValidator.canonicalize(url) else { return }
            if seen.insert(canon).inserted { out.append(canon) }
        }

        for r in hints { append(r) }
        for r in Self.defaultRelays { append(r) }

        if attempt > 0 {
            if let pubkey = NostrKey.load()?.pubkey,
               let board = RelayScoreBoard.load(pubkey: pubkey) {
                for entry in board.scoredRelays.prefix(6) { append(entry.url) }
            }
            for r in Self.extraRelays { append(r) }
        }

        let cap = attempt == 0 ? 6 : 12
        return Array(out.prefix(cap))
    }

    private func filterByIds(eventId: String) -> NostrFilter {
        var f = NostrFilter()
        f.ids = [eventId]
        f.limit = 1
        return f
    }
}

struct QuotedNoteView: View {
    let eventId: String
    let relayHints: [String]
    let profiles: [String: ProfileData]
    var onProfileTap: ((String) -> Void)? = nil
    var onNoteTap: ((String) -> Void)? = nil
    var onHashtagTap: ((String) -> Void)? = nil

    @State private var event: NostrEvent?
    @State private var loaded = false
    @State private var profile: ProfileData?
    @State private var contentExpanded = false
    @State private var attempt: Int = 0

    /// Mirror PostCardView's long-post threshold so a quoted long note collapses
    /// to the same height with a "Show more" toggle instead of pushing the
    /// surrounding card off-screen.
    private static let longPostCharThreshold = 600
    private static let longPostCollapsedHeight: CGFloat = 280

    /// One silent redundancy retry on initial miss — broadens the relay set
    /// without making the user tap. Beyond that the missing card becomes a
    /// tap-to-retry button so we don't pound relays for events that genuinely
    /// don't exist anywhere.
    private static let autoRetryAttempts = 1

    var body: some View {
        Group {
            if let event {
                noteCard(event)
            } else if loaded {
                missingCard
            } else {
                loadingCard
            }
        }
        .task(id: TaskKey(eventId: eventId, attempt: attempt)) { await load() }
    }

    /// Composite key so a retry (attempt bump) re-runs `.task` the same way an
    /// `eventId` change does. Mirrors the pattern in `RetryingAsyncImage`.
    private struct TaskKey: Hashable {
        let eventId: String
        let attempt: Int
    }

    private var loadingCard: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(Color.wispPrimary)
            Text("Loading quoted note…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurfaceVariant.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.wispSurfaceVariant, lineWidth: 1)
        )
    }

    private var missingCard: some View {
        Button {
            attempt += 1
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble")
                    .foregroundStyle(.secondary)
                Text("Quoted note not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.wispPrimary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.wispSurfaceVariant.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.wispSurfaceVariant, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quoted note not found. Tap to retry.")
    }

    private func noteCard(_ event: NostrEvent) -> some View {
        Button {
            onNoteTap?(event.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    CachedAvatarView(url: profile?.picture, size: 24)
                    EmojiText(
                        profile?.displayString ?? Nip19.shortNpub(hex: event.pubkey),
                        emojiMap: profile?.emojiMap ?? [:],
                        textStyle: .caption1,
                        weight: .semibold
                    )
                    Spacer()
                    Text(relativeTime(from: event.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if event.kind == 9735 {
                    zapReceiptBody(event)
                } else {
                    // "Long" for an embedded preview is text past the threshold OR
                    // ANY inline media (NIP-92 imeta image / video). Without the
                    // media check, a short-text + image embedded note expands to
                    // its full intrinsic height and dominates the parent card.
                    let hasMedia = event.tags.contains { $0.first == "imeta" }
                    let isLong = event.content.count > Self.longPostCharThreshold || hasMedia
                    let collapsed = isLong && !contentExpanded
                    VStack(alignment: .leading, spacing: 6) {
                        RichContentView(
                            content: event.content,
                            tags: event.tags,
                            profiles: profiles,
                            authorPubkey: event.pubkey,
                            onProfileTap: onProfileTap,
                            onNoteTap: onNoteTap,
                            onHashtagTap: onHashtagTap,
                            showLinkPreviews: false,
                            nested: true
                        )
                        // Render media at intrinsic height so an image
                        // inside an embedded note fills the card's width
                        // (parent_width × aspect). Without this, the
                        // outer `.frame(maxHeight:)` propagates a hard
                        // height down through `.aspectRatio(.fit)` and
                        // the image shrinks horizontally to keep aspect,
                        // leaving large empty margins around a postage-
                        // stamp-sized preview. The cap then clips the
                        // bottom rather than scaling the image.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(
                            maxHeight: collapsed ? Self.longPostCollapsedHeight : .infinity,
                            alignment: .top
                        )
                        .clipped()
                        .overlay(alignment: .bottom) {
                            if collapsed {
                                LinearGradient(
                                    colors: [Color.wispBackground.opacity(0), Color.wispBackground],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: 48)
                                .allowsHitTesting(false)
                            }
                        }
                        if isLong {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    contentExpanded.toggle()
                                }
                            } label: {
                                Text(contentExpanded ? "Show less" : "Show more")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.wispPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.wispSurfaceVariant.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.wispSurfaceVariant, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func zapReceiptBody(_ event: NostrEvent) -> some View {
        let sats = Nip57.zapAmountSats(receipt: event)
        let message = Nip57.zapMessage(receipt: event)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13))
                Text(sats > 0 ? "\(CurrencyFormatter.short(sats: sats)) sats" : "Zap")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Color.wispZapColor)

            if let message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func load() async {
        if let cached = QuotedNoteCache.shared.cached(eventId: eventId) {
            self.event = cached
            self.profile = profiles[cached.pubkey] ?? ProfileRepository.shared.get(cached.pubkey)
            loaded = true
            return
        }
        // Re-enter the loading state so a tap-to-retry hides the missing
        // card while the next attempt is in flight.
        loaded = false
        event = nil

        let result: NostrEvent?
        if attempt == 0 {
            result = await QuotedNoteCache.shared.fetch(eventId: eventId, relayHints: relayHints)
        } else {
            // Brief backoff before broader retries so a flaky relay isn't
            // pounded inside the same second. Capped so manual taps still
            // feel responsive.
            let delay = min(3.0, 0.75 * Double(attempt))
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            result = await QuotedNoteCache.shared.refetch(
                eventId: eventId,
                relayHints: relayHints,
                attempt: attempt
            )
        }
        if Task.isCancelled { return }

        if let result {
            self.event = result
            self.profile = profiles[result.pubkey] ?? ProfileRepository.shared.get(result.pubkey)
            loaded = true
            return
        }
        if attempt < Self.autoRetryAttempts {
            // Bumping attempt re-keys the `.task` and triggers another load
            // pass with the expanded relay set.
            attempt += 1
        } else {
            loaded = true
        }
    }
}
