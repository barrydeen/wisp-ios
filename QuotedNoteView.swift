import SwiftUI
import QuartzCore
import os

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
    func fetch(eventId: String, relayHints: [String], author: String? = nil) async -> NostrEvent? {
        if let cached = cache[eventId] { return cached }
        if let stored = await EventStore.shared.eventsByIds([eventId]).first {
            cache[eventId] = stored
            return stored
        }
        if let existing = inflight[eventId] { return await existing.value }
        return await runFetch(eventId: eventId, relayHints: relayHints, author: author, attempt: 0)
    }

    /// Forced retry — bumps the attempt counter and widens the relay set with
    /// the user's outbox-scored relays plus an extra fallback list. Used by
    /// the tap-to-retry affordance on the "Quoted note not found" card and by
    /// the view's one automatic redundancy retry.
    func refetch(eventId: String, relayHints: [String], author: String? = nil, attempt: Int) async -> NostrEvent? {
        if let cached = cache[eventId] { return cached }
        if let existing = inflight[eventId] { return await existing.value }
        return await runFetch(eventId: eventId, relayHints: relayHints, author: author, attempt: attempt)
    }

    private func runFetch(eventId: String, relayHints: [String], author: String?, attempt: Int) async -> NostrEvent? {
        let task = Task<NostrEvent?, Never> { [weak self] in
            guard let self else { return nil }
            let relays = await self.relayList(hints: relayHints, author: author, eventId: eventId, attempt: attempt)
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
        #if DEBUG
        // Correlation: this fan-out has a 6s/10s timeout that matches the
        // reported freeze duration. It's async so it shouldn't block main —
        // if a MAIN STALL lines up with this log, a hidden sync hop is implicated.
        let t0 = CACurrentMediaTime()
        mediaPerfLog.log("quotedNote.fetch start id=\(String(eventId.prefix(12)), privacy: .public) attempt=\(attempt, privacy: .public)")
        #endif
        let result = await task.value
        #if DEBUG
        mediaPerfLog.log("quotedNote.fetch done \(Int((CACurrentMediaTime() - t0) * 1000), privacy: .public)ms hit=\(result != nil, privacy: .public) id=\(String(eventId.prefix(12)), privacy: .public)")
        #endif
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
    private func relayList(hints: [String], author: String?, eventId: String, attempt: Int) async -> [String] {
        var seen = Set<String>()
        var out: [String] = []

        func append(_ url: String) {
            guard let canon = RelayUrlValidator.canonicalize(url) else { return }
            if seen.insert(canon).inserted { out.append(canon) }
        }

        for r in hints { append(r) }
        // A note this client saw earlier may have recorded who wrote the note
        // it quoted, even when the current reference didn't name them — a bare
        // `note1…`, or a `q` tag published without the optional pubkey. That
        // remembered author is what makes an outbox lookup possible here.
        let effectiveAuthor = author ?? QuoteGraph.shared.author(of: eventId)
        // The author's own NIP-65 write relays — the outbox model, and the
        // one place a note is actually guaranteed to have been published.
        // Ahead of the generic defaults: a hint that misses used to fall
        // straight to a fixed list that has no particular reason to hold this
        // author's notes, which is why quotes from outside the usual relays
        // showed as "not found" while the note was sitting where its author
        // put it.
        if let effectiveAuthor {
            for r in await RelayListRepository.shared.getWriteRelays(effectiveAuthor) { append(r) }
        }
        for r in Self.defaultRelays { append(r) }

        if attempt > 0 {
            if let pubkey = NostrKey.load()?.pubkey,
               let board = RelayScoreBoard.load(pubkey: pubkey) {
                for entry in board.scoredRelays.prefix(6) { append(entry.url) }
            }
            for r in Self.extraRelays { append(r) }
        }

        // A little wider on attempt 0 than before, so the author's relays
        // don't push the defaults out of the first try.
        let cap = attempt == 0 ? 8 : 14
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
    /// Author of the quoted note — from the quoting note's NIP-18 `q` tag when
    /// it named one, else the `nevent1…`'s own hint. Two consumers: it enables
    /// an outbox lookup when relay hints don't resolve the event, and it
    /// attributes a NIP-09 deletion request, which only counts from the quoted
    /// note's own author — when the note can't be fetched this hint is the only
    /// way to know who that is.
    var authorHint: String? = nil
    let profiles: [String: ProfileData]
    var onProfileTap: ((String) -> Void)? = nil
    var onNoteTap: ((String) -> Void)? = nil
    /// Forwarded to `RichContentView.nestedHorizontalInset` / `MediaGridView`
    /// for this note's own attached gallery. Default (56) matches this view's
    /// most common placement: embedded inline inside another post's own body
    /// (`RichContentView`'s `.nostrNote` case) under a `PostCardView`'s 16pt
    /// card edge. `NotificationRowView` places this view directly under its
    /// own, wider caption indent and must pass its own total.
    var nestedHorizontalInset: CGFloat = 56
    var onHashtagTap: ((String) -> Void)? = nil
    /// Whether a retracted note may render the quote recovered from its own
    /// content (see `deletedCard`). False on that recovered child, so the
    /// repair reaches exactly one level down and a chain of retracted notes
    /// can't recurse.
    var allowsDeletedQuoteRecovery: Bool = true

    @State private var event: NostrEvent?
    @State private var loaded = false
    @State private var blocked = false
    @State private var safetyHidden = false
    /// The quoted note's author retracted it (NIP-09 kind-5).
    @State private var deleted = false
    /// The note the retracted note itself quoted, when a relay still served the
    /// retracted event so we could read it back out. Keeps a quote stack from
    /// losing everything below a deleted middle node.
    @State private var recoveredQuote: RecoveredQuote?
    @State private var profile: ProfileData?
    @State private var contentExpanded = false
    @State private var attempt: Int = 0
    /// Natural (pre-cap) height of the text portion, measured so the collapse
    /// fade is drawn only when the cap actually cut text off.
    @State private var textPortionIntrinsicHeight: CGFloat = 0

    /// Mirror PostCardView's long-post threshold so a quoted long note collapses
    /// to the same height with a "Show more" toggle instead of pushing the
    /// surrounding card off-screen.
    private static let longPostCharThreshold = 600
    private static let longPostTextCollapsedHeight: CGFloat = 280
    /// Fraction of the quoted card's own content width that collapsed media
    /// may occupy.
    ///
    /// PostCardView's flat 80pt peek is sized for a different job: there the
    /// reader already has the post's text in front of them and the strip only
    /// has to signal "media continues below the toggle". An embedded card has
    /// no such body to lean on — for a short-text quote the image *is* the
    /// context — and 80pt of a ~337pt-wide photo is a ~48pt sliver once the
    /// 32pt bottom fade is drawn over it, which reads as no image at all.
    ///
    /// Keyed to width rather than a flat point value so the peek tracks the
    /// card it sits in (`NotificationRowView`'s wider indent leaves a
    /// narrower card, so a proportionally shorter slice of the same photo).
    /// At 0.8 landscape photos clear the cap outright and a square or
    /// portrait one keeps its top ~80% — most of the shot, with the fade
    /// below still signalling that the rest is one tap away.
    private static let mediaPeekWidthFraction: CGFloat = 0.8

    /// Visible height of trailing media when collapsed. Rendered as its own
    /// portion (see `renderMode: .mediaPortion` below) with its own height
    /// budget so a long caption above it can't eat into the gallery's peek —
    /// previously text and media shared one combined cap, and a caption
    /// alone could consume nearly all of it, leaving almost nothing of the
    /// gallery visible.
    private var mediaPeekHeight: CGFloat {
        Self.mediaPeekHeight(
            forContentWidth: UIScreen.main.bounds.width - nestedHorizontalInset
        )
    }

    /// Pure form of `mediaPeekHeight`, seeded the way
    /// `MediaGridView.tileHeightForNested` seeds its own guess: the quoted
    /// card's content width is the screen less `nestedHorizontalInset`, this
    /// view's total horizontal chrome.
    static func mediaPeekHeight(forContentWidth width: CGFloat) -> CGFloat {
        max(1, width) * mediaPeekWidthFraction
    }

    /// One silent redundancy retry on initial miss — broadens the relay set
    /// without making the user tap. Beyond that the missing card becomes a
    /// tap-to-retry button so we don't pound relays for events that genuinely
    /// don't exist anywhere.
    private static let autoRetryAttempts = 1

    var body: some View {
        Group {
            if blocked {
                blockedCard
            } else if deleted {
                deletedCard
            } else if safetyHidden {
                safetyHiddenCard
            } else if let event {
                noteCard(event)
            } else if loaded {
                missingCard
            } else {
                loadingCard
            }
        }
        .task(id: TaskKey(eventId: eventId, attempt: attempt)) { await load() }
        // Re-gate in place on snapshot installs (WoT toggle / recompute): the
        // load()-time check only sees the snapshot of that moment, so an
        // already-resolved quoted note would otherwise keep rendering after
        // the filter tightens (and a hidden one would stay hidden after it
        // relaxes).
        .onReceive(NotificationCenter.default.publisher(for: .safetyFilterChanged)) { _ in
            // A retracted note is gone regardless of how the filter moves —
            // re-gating it would replace the accurate card with a misleading one.
            if deleted { return }
            if let event,
               !PrivateInteractionStore.shared.contains(event.id),
               SafetyFilter.shared.shouldDrop(event: event, context: .feed) {
                self.event = nil
                safetyHidden = true
                loaded = true
            } else if safetyHidden {
                // Re-attempt from cache under the relaxed rules: the attempt
                // bump re-keys `.task`, and `load()` re-evaluates the cached
                // event before any network fetch.
                safetyHidden = false
                loaded = false
                attempt += 1
            }
        }
    }

    /// Composite key so a retry (attempt bump) re-runs `.task` the same way an
    /// `eventId` change does. Mirrors the pattern in `RetryingAsyncImage`.
    private struct TaskKey: Hashable {
        let eventId: String
        let attempt: Int
    }

    /// Reports the text portion's natural height out from under the collapsed
    /// `.frame(maxHeight:)` cap. The background GeometryReader sits before the
    /// frame in the modifier chain, so it measures what the text *wants* to
    /// be, not what the cap left visible.
    private struct TextPortionHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// A quote reference lifted back out of a retracted note's own content.
    private struct RecoveredQuote: Equatable {
        let eventId: String
        let relayHints: [String]
        let author: String?
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

    /// Shown when the quoted note's author is blocked. Their content is never
    /// rendered; a neutral stub keeps the surrounding card from looking broken
    /// (or showing a misleading "Quoted note not found").
    private var blockedCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "nosign")
                .foregroundStyle(.secondary)
            Text("Note from a blocked user")
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
        .accessibilityLabel("Note from a blocked user")
    }

    /// Shown when the safety filter (Web of Trust, muted word) hides the
    /// quoted note. Mirrors `blockedCard` — none of the event renders, and
    /// there's no reveal affordance (the filter gates potentially graphic
    /// content). Copy stays generic because `.feed`-context `shouldDrop`
    /// covers more than WoT.
    private var safetyHiddenCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)
            Text("Note hidden by your safety filters")
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
        .accessibilityLabel("Note hidden by your safety filters")
    }

    /// Shown when the quoted note's author retracted it with a NIP-09 kind-5.
    /// Deliberately its own category: `missingCard` implies retrying might turn
    /// the note up, and `safetyHiddenCard` points the reader at their own
    /// settings — neither is true of a note the author took down. No retry
    /// affordance, for the same reason.
    ///
    /// When a relay still served the retracted event we could read the quote it
    /// carried, and that note renders below: it belongs to someone else and
    /// wasn't retracted, so dropping it would silently cut the bottom off a
    /// quote stack. The retracted note's own words never render either way.
    private var deletedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                Text("Note deleted by its author")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Note deleted by its author")

            if let recoveredQuote {
                Text("It quoted:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                QuotedNoteView(
                    eventId: recoveredQuote.eventId,
                    relayHints: recoveredQuote.relayHints,
                    authorHint: recoveredQuote.author,
                    profiles: profiles,
                    onProfileTap: onProfileTap,
                    onNoteTap: onNoteTap,
                    nestedHorizontalInset: nestedHorizontalInset,
                    onHashtagTap: onHashtagTap,
                    allowsDeletedQuoteRecovery: false
                )
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
                    // Avatar alone routes to the author's profile; the rest
                    // of the row + body still opens the quoted note's
                    // thread via the surrounding Button.
                    Button {
                        onProfileTap?(event.pubkey)
                    } label: {
                        CachedAvatarView(url: profile?.picture, size: 24)
                    }
                    .buttonStyle(.plain)
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
                } else if event.kind == 30023 {
                    // A long-form article quoted by event id lands here, and
                    // its content is markdown — rendering it as note text
                    // spills raw `[label](url)` syntax and a wall of body
                    // copy into the card. The same article linked as a
                    // `nostr:naddr1…` already gets a proper card via
                    // `ArticleCardView`; this gives the id-based path the
                    // equivalent, using the event already in hand.
                    ArticleFeedPreview(event: event, relayHints: relayHints)
                } else {
                    // "Long" for an embedded preview is text past the threshold OR
                    // ANY inline media (NIP-92 imeta image / video). Without the
                    // media check, a short-text + image embedded note expands to
                    // its full intrinsic height and dominates the parent card.
                    let hasMedia = event.tags.contains { $0.first == "imeta" }
                    let isLong = event.content.count > Self.longPostCharThreshold || hasMedia
                    let collapsed = isLong && !contentExpanded
                    VStack(alignment: .leading, spacing: 6) {
                        // Text portion: leading inline groups only, capped
                        // independently of media (see `mediaPortion` below).
                        // Previously one `RichContentView(renderMode: .all)`
                        // shared a single height cap between the caption and
                        // any trailing gallery — a caption alone could
                        // consume nearly the whole cap, leaving almost
                        // nothing of the gallery visible beneath it.
                        RichContentView(
                            content: event.content,
                            tags: event.tags,
                            profiles: profiles,
                            authorPubkey: event.pubkey,
                            onProfileTap: onProfileTap,
                            onNoteTap: onNoteTap,
                            onHashtagTap: onHashtagTap,
                            showLinkPreviews: false,
                            nested: true,
                            nestedHorizontalInset: nestedHorizontalInset,
                            renderMode: .textPortion
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
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: TextPortionHeightKey.self,
                                    value: geo.size.height
                                )
                            }
                        )
                        .frame(
                            maxHeight: collapsed ? Self.longPostTextCollapsedHeight : .infinity,
                            alignment: .top
                        )
                        .clipped()
                        .overlay(alignment: .bottom) {
                            // The fade means "text continues below the cap",
                            // so only draw it when the cap actually cut
                            // something. A quote whose text fits whole was
                            // getting its only line dimmed under the fade,
                            // which read as a truncated preview of text
                            // that wasn't there.
                            if collapsed,
                               textPortionIntrinsicHeight > Self.longPostTextCollapsedHeight + 0.5 {
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
                        // Media portion: everything from the first
                        // block/media group onward. Always rendered, even
                        // when collapsed — peeked to `mediaPeekHeight` so
                        // the user can see media (e.g. a gallery) exists
                        // below, instead of the caption's cap swallowing it
                        // entirely. Expands to natural size on toggle.
                        RichContentView(
                            content: event.content,
                            tags: event.tags,
                            profiles: profiles,
                            authorPubkey: event.pubkey,
                            onProfileTap: onProfileTap,
                            onNoteTap: onNoteTap,
                            onHashtagTap: onHashtagTap,
                            showLinkPreviews: false,
                            nested: true,
                            nestedHorizontalInset: nestedHorizontalInset,
                            renderMode: .mediaPortion
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(
                            maxHeight: collapsed ? mediaPeekHeight : .infinity,
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
                                .frame(height: 32)
                                .allowsHitTesting(false)
                            }
                        }
                    }
                    .onPreferenceChange(TextPortionHeightKey.self) { textPortionIntrinsicHeight = $0 }
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
            await present(cached)
            return
        }
        // Re-enter the loading state so a tap-to-retry hides the missing
        // card while the next attempt is in flight.
        loaded = false
        event = nil

        let result: NostrEvent?
        if attempt == 0 {
            result = await QuotedNoteCache.shared.fetch(eventId: eventId, relayHints: relayHints, author: authorHint)
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
                author: authorHint,
                attempt: attempt
            )
        }
        if Task.isCancelled { return }

        if let result {
            await present(result)
            return
        }
        if attempt < Self.autoRetryAttempts {
            // Bumping attempt re-keys the `.task` and triggers another load
            // pass with the expanded relay set.
            attempt += 1
            return
        }
        // Nothing served the note. "Not found" is only half an answer — the
        // author may have retracted it, in which case no amount of retrying
        // will help and the card should say so. The `nevent`'s author hint is
        // the only attribution available here; without one the check no-ops
        // and the missing card stands.
        loaded = true
        if await DeletionTracker.shared.check(
            eventId: eventId,
            author: authorHint,
            relayHints: relayHints
        ), !Task.isCancelled {
            markDeleted(source: nil)
        }
    }

    /// Apply the render gates to a resolved quoted note, in priority order:
    /// blocked author, then author-retracted, then the safety filter.
    ///
    /// Deletion outranks the safety gate deliberately. Relays are free to keep
    /// serving a retracted note, so one can arrive here and then be caught by
    /// the WoT check — and "Note hidden by your safety filters" blames the
    /// reader's own settings for something the author did. Neither card shows
    /// any of the note's content, so ordering them this way costs nothing and
    /// gives the accurate reason.
    private func present(_ resolved: NostrEvent) async {
        if SafetyFilter.shared.snapshot.blockedPubkeys.contains(resolved.pubkey) {
            blocked = true
            loaded = true
            return
        }

        if DeletionTracker.shared.isDeleted(eventId: resolved.id, author: resolved.pubkey) {
            markDeleted(source: resolved)
            return
        }

        // WoT gate — a qualified author quoting a stranger's note would
        // otherwise inline-render the stranger's content/media right past
        // the filter. Private rumors keep their gift-wrap exemption.
        if !PrivateInteractionStore.shared.contains(resolved.id),
           SafetyFilter.shared.shouldDrop(event: resolved, context: .feed) {
            // Paint the safety card first and ask relays about a deletion
            // after: the check is one small query per hidden quote, cached for
            // the session, and must never delay the placeholder. A positive
            // answer upgrades the card in place.
            safetyHidden = true
            loaded = true
            if await DeletionTracker.shared.check(
                eventId: resolved.id,
                author: resolved.pubkey,
                relayHints: relayHints
            ), !Task.isCancelled {
                markDeleted(source: resolved)
            }
            return
        }

        event = resolved
        profile = profiles[resolved.pubkey] ?? ProfileRepository.shared.get(resolved.pubkey)
        loaded = true
    }

    /// Switch to the retracted-note card. `source` is the retracted event when a
    /// relay still served it, which is the only way to recover the note it
    /// quoted — that link lives in its content and nowhere else.
    private func markDeleted(source: NostrEvent?) {
        event = nil
        blocked = false
        safetyHidden = false
        recoveredQuote = allowsDeletedQuoteRecovery
            ? source.flatMap { Self.firstQuotedNote(in: $0, excluding: eventId) }
            : nil
        deleted = true
        loaded = true
    }

    /// First `nostr:note1…` / `nostr:nevent1…` reference in `event`'s content.
    /// Self-references are skipped so a note quoting itself can't recurse.
    private static func firstQuotedNote(in event: NostrEvent, excluding excluded: String) -> RecoveredQuote? {
        for segment in ContentParser.parse(content: event.content, tags: event.tags) {
            guard case .nostrNote(let id, let hints, let author) = segment else { continue }
            guard id != excluded, id != event.id else { continue }
            return RecoveredQuote(eventId: id, relayHints: hints, author: author)
        }
        return nil
    }
}
