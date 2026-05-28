import Foundation

/// A pending mutation to apply to one `EngagementBox.counts` on the main thread.
/// Emitted in batches by `EngagementProcessor` every ~50 ms when non-empty so
/// 100 inbound engagement events produce ~2 observable mutations on main
/// instead of 100. Mirrors Android's conflated-channel version-bump pattern.
struct EngagementDiff: Sendable {
    /// Event id whose `EngagementBox` should be mutated.
    let targetEventId: String
    /// Relay this event arrived from — appended to `counts.seenRelays`.
    let relayUrl: String
    let mutation: Mutation
    /// Pubkeys to enqueue into `MissingProfileWatcher` so display names
    /// resolve. Collected by `apply` into one `observePubkeys` call per
    /// batch.
    let profilesToObserve: [String]

    enum Mutation: Sendable {
        case reply
        case repost(reposter: String, repostEventId: String)
        case reaction(reactor: Reactor)
        case zap(sats: Int64, zapper: Zapper)
        case quote(quoter: Quoter)
    }
}

/// Background processor for engagement events (kinds 1 / 6 / 7 / 9735).
///
/// Mirrors the Android client's `EventRouter` + `EventRepository` pipeline:
/// a single off-main consumer parses every inbound event, holds the dedup
/// state (`ConcurrentHashMap` over there, this `actor` here), and emits
/// debounced UI-mutation batches. The main thread only mutates
/// `EngagementBox.counts` on the 50 ms flush boundary — never per event.
///
/// Subscription consumer Tasks call `ingest` from a *detached* context so
/// the for-await loop never runs on `@MainActor`. Optimistic apply paths
/// (UI button taps) `await` the reservation methods and then mutate the
/// `EngagementBox` synchronously on main — the small actor hop is invisible
/// next to the heart's button press animation.
actor EngagementProcessor {
    /// Process-wide instance. `EngagementRepository.shared` owns the only
    /// MainActor consumer of `diffs` so all live-engagement traffic funnels
    /// through one singleton.
    static let shared = EngagementProcessor()

    // MARK: - Diff stream

    /// Batched diffs ready for MainActor application. Yielded on a 50 ms
    /// debounce. Unbounded buffer because main is allowed to fall slightly
    /// behind during a burst — dropping diffs would lose engagement counts.
    nonisolated let diffs: AsyncStream<[EngagementDiff]>
    private let diffsContinuation: AsyncStream<[EngagementDiff]>.Continuation

    private var pending: [EngagementDiff] = []
    private var flushTask: Task<Void, Never>?
    private static let flushDelayMs: UInt64 = 50

    // MARK: - Dedup state

    /// Event ids whose engagement we're actively tracking. Inbound events
    /// whose primary `#e` target isn't in this set are dropped — relay-side
    /// echoes and broad `#e` filters can stream events for ids we never
    /// asked about.
    private var queriedIds: Set<String> = []
    /// Inbound engagement event ids already processed (across all targets).
    /// Also seeded by `reserveEngagementId` from the optimistic publish path
    /// so a server-echoed copy doesn't double-count.
    private var seenEngagementIds: Set<String> = []
    /// `"target|reactor|emoji"` triples already counted. Shared by inbound
    /// kind-7 ingest and optimistic UI reactions.
    private var seenReactionKeys: Set<String> = []
    /// Bolt11 payment hashes already counted. Shared by inbound kind-9735
    /// ingest and optimistic zap UI.
    private var seenZapPaymentHashes: Set<String> = []
    /// Event ids whose NIP-18 quote-fetch has been kicked off (drawer
    /// expansion). One per note for the app's lifetime.
    private var quotersFetched: Set<String> = []

    /// Cached recipient privkey for DIP-03 private-zap sender resolution.
    /// Loaded lazily on the first inbound kind-9735 event so keychain access
    /// happens off-main (we're in the actor) and only once per session.
    /// Reset by `clear()` on logout/pubkey switch.
    private var recipientPrivkey32: Data?
    private var recipientPrivkeyLoaded = false

    init() {
        var cont: AsyncStream<[EngagementDiff]>.Continuation!
        diffs = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        diffsContinuation = cont
    }

    // MARK: - Tracking

    /// Mark event ids as actively tracked by the feed. Called from
    /// `EngagementRepository.flushBatch` after the per-relay subscription
    /// has been opened, so the consumer can drop irrelevant events the
    /// moment they arrive.
    func markQueried(_ ids: [String]) {
        for id in ids { queriedIds.insert(id) }
    }

    // MARK: - Optimistic apply reservations

    /// Reserve a `(target, reactor, emoji)` triple so an inbound copy of an
    /// optimistic kind-7 doesn't double-count. Also seeds `queriedIds` so
    /// the reaction's counts appear even when the target wasn't visible.
    /// Returns `true` if newly reserved.
    func reserveReactionKey(eventId: String, pubkey: String, emoji: String) -> Bool {
        let key = "\(eventId)|\(pubkey)|\(emoji)"
        let claimed = seenReactionKeys.insert(key).inserted
        if claimed { queriedIds.insert(eventId) }
        return claimed
    }

    /// Release a prior reservation when an optimistic publish failed.
    func releaseReactionKey(eventId: String, pubkey: String, emoji: String) {
        let key = "\(eventId)|\(pubkey)|\(emoji)"
        seenReactionKeys.remove(key)
    }

    /// Reserve a signed kind-7 event id against the inbound dedup set so the
    /// server-echoed copy is dropped.
    func reserveEngagementId(_ id: String) {
        seenEngagementIds.insert(id)
    }

    /// Undo a prior `reserveEngagementId`.
    func releaseEngagementId(_ id: String) {
        seenEngagementIds.remove(id)
    }

    /// Reserve a repost wrapper id + bump for the target. Returns true if the
    /// reposter wasn't already in the queried tracking. Also marks the event
    /// id as queried so the count appears even if the target is off-screen.
    func reserveRepost(targetEventId: String, repostEventId: String) {
        seenEngagementIds.insert(repostEventId)
        queriedIds.insert(targetEventId)
    }

    /// Reserve a zap payment hash. Returns `true` if newly claimed.
    func reserveZapHash(_ hash: String, eventId: String) -> Bool {
        let claimed = seenZapPaymentHashes.insert(hash).inserted
        if claimed { queriedIds.insert(eventId) }
        return claimed
    }

    /// Release a previously reserved zap payment hash.
    func releaseZapHash(_ hash: String) {
        seenZapPaymentHashes.remove(hash)
    }

    /// One-shot guard for the lazy `fetchQuoters` path on the details drawer.
    /// Returns `true` if this was the first request for this event.
    func reserveQuoterFetch(_ eventId: String) -> Bool {
        return quotersFetched.insert(eventId).inserted
    }

    // MARK: - Apply lazily-fetched quoters

    /// Apply a one-shot quote-fetch result. Returns the deduplicated `Quoter`
    /// list ready for the MainActor to merge into `EngagementBox.counts.quoters`.
    /// Also returns the unique reactor pubkeys for profile observation.
    func ingestQuoters(_ events: [NostrEvent], targetId: String) -> (quoters: [Quoter], pubkeys: [String]) {
        var quoters: [Quoter] = []
        var pubkeys: [String] = []
        for event in events {
            guard event.kind == 1, seenEngagementIds.insert(event.id).inserted else { continue }
            let hasMatchingQTag = event.tags.contains { tag in
                tag.count >= 2 && tag[0] == "q" && tag[1] == targetId
            }
            guard hasMatchingQTag else { continue }
            quoters.append(Quoter(
                eventId: event.id,
                pubkey: event.pubkey,
                createdAt: event.createdAt
            ))
            pubkeys.append(event.pubkey)
        }
        return (quoters, pubkeys)
    }

    // MARK: - Ingest (from RelaySubscription consumer)

    /// Parse and dedupe an inbound engagement event. Appends a diff to the
    /// pending batch if the event applies to a queried note.
    func ingest(event: NostrEvent, relayUrl: String) {
        guard seenEngagementIds.insert(event.id).inserted else { return }

        // Quote reposts (NIP-18): kind-1 with `q` tags matching queried notes
        // become Quoter entries on the targets and bypass the e-tag path.
        if event.kind == 1 {
            var matchedQuoteTargets: Set<String> = []
            for tag in event.tags where tag.count >= 2 && tag[0] == "q" {
                if queriedIds.contains(tag[1]) { matchedQuoteTargets.insert(tag[1]) }
            }
            if !matchedQuoteTargets.isEmpty {
                let quoter = Quoter(
                    eventId: event.id,
                    pubkey: event.pubkey,
                    createdAt: event.createdAt
                )
                for quotedId in matchedQuoteTargets {
                    pending.append(EngagementDiff(
                        targetEventId: quotedId,
                        relayUrl: relayUrl,
                        mutation: .quote(quoter: quoter),
                        profilesToObserve: [event.pubkey]
                    ))
                }
                scheduleFlush()
                return
            }
        }

        // Aggregate against the most-specific (last) e-tag, ignoring `mention`
        // markers — same rule as `ThreadViewModel.ingestEngagement`.
        var lastETarget: String?
        for tag in event.tags where tag.count >= 2 && tag[0] == "e" {
            if tag.count >= 4, tag[3] == "mention" { continue }
            lastETarget = tag[1]
        }
        guard let primary = lastETarget, queriedIds.contains(primary) else { return }

        switch event.kind {
        case 1:
            pending.append(EngagementDiff(
                targetEventId: primary,
                relayUrl: relayUrl,
                mutation: .reply,
                profilesToObserve: []
            ))
        case 6:
            pending.append(EngagementDiff(
                targetEventId: primary,
                relayUrl: relayUrl,
                mutation: .repost(reposter: event.pubkey, repostEventId: event.id),
                profilesToObserve: [event.pubkey]
            ))
        case 7:
            let reactionKey = "\(primary)|\(event.pubkey)|\(event.content)"
            guard seenReactionKeys.insert(reactionKey).inserted else { return }
            let reactor = Reactor(
                pubkey: event.pubkey,
                emoji: event.content,
                customEmojiUrl: Self.customEmojiUrl(for: event.content, in: event.tags),
                reactionEventId: event.id
            )
            pending.append(EngagementDiff(
                targetEventId: primary,
                relayUrl: relayUrl,
                mutation: .reaction(reactor: reactor),
                profilesToObserve: [event.pubkey]
            ))
        case 9735:
            var sats: Int64 = 0
            var paymentHash: String?
            if let bolt = event.tags.first(where: { $0.first == "bolt11" && $0.count >= 2 })?[1],
               let decoded = Bolt11.decode(bolt) {
                sats = decoded.amountSats ?? 0
                paymentHash = decoded.paymentHash
            }
            if let hash = paymentHash, !seenZapPaymentHashes.insert(hash).inserted {
                return
            }
            // Resolve the real zapper via `Nip57.resolveZapSender`, which
            // handles both public zaps (description.pubkey path) and DIP-03
            // private zaps (decrypt inner kind-9733 with the recipient's
            // privkey, fall back to ephemeral pubkey when decryption fails).
            // For DIP-03 receipts arriving for a note that isn't ours, we
            // can't decrypt — those still surface with the ephemeral pubkey,
            // which is the correct privacy-preserving behavior.
            if !recipientPrivkeyLoaded {
                recipientPrivkeyLoaded = true
                recipientPrivkey32 = NostrKey.load().flatMap { Hex.decode($0.privkey) }
            }
            let resolved = Nip57.resolveZapSender(receipt: event, recipientPrivkey32: recipientPrivkey32)
            let zapperPubkey = resolved?.pubkey ?? event.pubkey
            let message = resolved?.message ?? ""
            let zapper = Zapper(pubkey: zapperPubkey, sats: sats, message: message)
            pending.append(EngagementDiff(
                targetEventId: primary,
                relayUrl: relayUrl,
                mutation: .zap(sats: sats, zapper: zapper),
                profilesToObserve: [zapperPubkey]
            ))
        default:
            return
        }
        scheduleFlush()
    }

    // MARK: - Flush

    private func scheduleFlush() {
        if flushTask != nil { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.flushDelayMs)))
            await self?.flush()
        }
    }

    private func flush() {
        flushTask = nil
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        diffsContinuation.yield(batch)
    }

    // MARK: - Clear

    func clear() {
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
        seenEngagementIds.removeAll()
        seenReactionKeys.removeAll()
        seenZapPaymentHashes.removeAll()
        queriedIds.removeAll()
        quotersFetched.removeAll()
        recipientPrivkey32 = nil
        recipientPrivkeyLoaded = false
    }

    // MARK: - Helpers

    /// If `content` is a NIP-30 `:shortcode:` reaction, find the matching
    /// `["emoji", shortcode, url]` tag and return the image URL.
    nonisolated private static func customEmojiUrl(for content: String, in tags: [[String]]) -> String? {
        guard content.hasPrefix(":"), content.hasSuffix(":"), content.count > 2 else { return nil }
        let shortcode = String(content.dropFirst().dropLast())
        for tag in tags where tag.count >= 3 && tag[0] == "emoji" && tag[1] == shortcode {
            return tag[2]
        }
        return nil
    }
}
