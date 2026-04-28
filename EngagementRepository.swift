import Foundation
import Observation

/// Viewport-driven engagement count cache for the follow feed.
///
/// As `PostCardView` rows become visible, the feed registers their `(eventId, author)` here.
/// Pending registrations are coalesced for 300 ms, then routed per NIP-65: each event's
/// engagement query (kinds 1/6/7/9735 with `#e`) goes to its author's read (inbox) relays,
/// with fallbacks for authors without a published relay list and a safety-net broadcast to
/// the top scored relays. Mirrors Android's `OutboxRouter.subscribeEngagementByAuthors`.
@Observable
@MainActor
final class EngagementRepository {
    static let shared = EngagementRepository()

    private(set) var counts: [String: EngagementCounts] = [:]

    @ObservationIgnored private var queriedIds: Set<String> = []
    @ObservationIgnored private var pending: [(eventId: String, author: String)] = []
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var liveTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var liveSubs: [RelaySubscription] = []
    @ObservationIgnored private var seenEngagementIds: Set<String> = []
    /// `eventId|pubkey|content` keys for kind-7 reactions already counted (via either an optimistic
    /// `apply...` call or an inbound EVENT). Prevents the round-trip duplicate when an optimistic
    /// reaction streams back from the relays under a fresh event id.
    @ObservationIgnored private var seenReactionKeys: Set<String> = []

    private init() {}

    // MARK: - Public API

    /// Called from feed row `.onAppear`. Idempotent per event id within a session.
    func markVisible(eventId: String, author: String) {
        guard !queriedIds.contains(eventId) else { return }
        // Avoid double-queueing while debounce is pending.
        if pending.contains(where: { $0.eventId == eventId }) { return }
        pending.append((eventId, author))
        if debounceTask == nil { scheduleFlush() }
    }

    /// Called on logout / pubkey switch.
    func clear() {
        debounceTask?.cancel()
        debounceTask = nil
        for sub in liveSubs { sub.cancel() }
        for task in liveTasks { task.cancel() }
        liveSubs.removeAll()
        liveTasks.removeAll()
        counts = [:]
        queriedIds.removeAll()
        pending.removeAll()
        seenEngagementIds.removeAll()
        seenReactionKeys.removeAll()
        ReactionSender.shared.clear()
        RepostSender.shared.clear()
    }

    // MARK: - Optimistic reactions

    /// Increment the reaction count for `eventId` immediately, before the kind-7 has actually
    /// been published. The reactor `pubkey` and `emoji` are stamped into `reactors` so the
    /// detail panel reflects the pending state. The synthetic event id is reserved against
    /// `seenEngagementIds` so the inbound copy doesn't double-count.
    func applyOptimisticReaction(eventId: String, reactionEventId: String, pubkey: String, emoji: String, customEmojiUrl: String? = nil) {
        let key = "\(eventId)|\(pubkey)|\(emoji)"
        guard seenReactionKeys.insert(key).inserted else {
            NSLog("[Reaction] applyOptimistic skipped (dedup) key=%@", key)
            return
        }
        NSLog("[Reaction] applyOptimistic eventId=%@ emoji=%@", eventId.prefix(8) as CVarArg, emoji)
        // Reserve the eventual inbound id too, in case the same event streams back.
        seenEngagementIds.insert(reactionEventId)

        // Make sure observers see the count even when the post wasn't visible yet.
        queriedIds.insert(eventId)

        var current = counts[eventId] ?? EngagementCounts()
        current.reactions += 1
        let reactor = Reactor(pubkey: pubkey, emoji: emoji, customEmojiUrl: customEmojiUrl)
        if !current.reactors.contains(where: { $0.pubkey == pubkey && $0.emoji == emoji }) {
            current.reactors.append(reactor)
        }
        counts[eventId] = current
    }

    /// Revert a prior optimistic apply. Called when publishing fails.
    func revertOptimisticReaction(eventId: String, pubkey: String, emoji: String) {
        let key = "\(eventId)|\(pubkey)|\(emoji)"
        guard seenReactionKeys.remove(key) != nil else { return }
        guard var current = counts[eventId] else { return }
        if current.reactions > 0 { current.reactions -= 1 }
        current.reactors.removeAll { $0.pubkey == pubkey && $0.emoji == emoji }
        counts[eventId] = current
    }

    // MARK: - Optimistic reposts

    /// Bump the repost counter for `eventId` immediately. Idempotent per `(eventId, reposter)`.
    /// `repostEventId` is reserved against the inbound dedup set so the published kind-6 streaming
    /// back from a relay doesn't double-count.
    func applyOptimisticRepost(eventId: String, repostEventId: String, reposterPubkey: String) {
        seenEngagementIds.insert(repostEventId)
        queriedIds.insert(eventId)
        var current = counts[eventId] ?? EngagementCounts()
        if current.reposters.contains(reposterPubkey) { return }
        current.reposts += 1
        current.reposters.append(reposterPubkey)
        counts[eventId] = current
    }

    /// Revert a prior optimistic repost. Called when publishing fails.
    func revertOptimisticRepost(eventId: String, reposterPubkey: String) {
        guard var current = counts[eventId] else { return }
        guard current.reposters.contains(reposterPubkey) else { return }
        if current.reposts > 0 { current.reposts -= 1 }
        current.reposters.removeAll { $0 == reposterPubkey }
        counts[eventId] = current
    }

    // MARK: - Debounce + flush

    private func scheduleFlush() {
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.flushBatch()
        }
    }

    private func flushBatch() {
        debounceTask = nil
        let batch = pending
        pending.removeAll()
        guard !batch.isEmpty else { return }
        for (id, _) in batch { queriedIds.insert(id) }

        let board = NostrKey.load().flatMap { RelayScoreBoard.load(pubkey: $0.pubkey) }
        let userReads = NostrKey.load().flatMap { RelayListRepository.shared.cachedReadRelays($0.pubkey) } ?? []
        let topScored = board?.scoredRelays.prefix(5).map(\.url) ?? []

        var relayToIds: [String: Set<String>] = [:]
        var homeless: [String] = []

        for (eventId, author) in batch {
            if let reads = RelayListRepository.shared.cachedReadRelays(author), !reads.isEmpty {
                for relay in reads.prefix(3) {
                    relayToIds[relay, default: []].insert(eventId)
                }
            } else {
                homeless.append(eventId)
            }
        }

        if !homeless.isEmpty {
            let fallback = !userReads.isEmpty
                ? Array(userReads.prefix(3))
                : (board?.scoredRelays.prefix(3).map(\.url) ?? [])
            for relay in fallback {
                for id in homeless {
                    relayToIds[relay, default: []].insert(id)
                }
            }
        }

        // Safety net: top scored relays receive every id from this batch.
        let allIds = batch.map(\.eventId)
        for relay in topScored {
            for id in allIds {
                relayToIds[relay, default: []].insert(id)
            }
        }

        for (relay, ids) in relayToIds {
            for chunk in Array(ids).chunked(into: 150) {
                openSubscription(relay: relay, eventIds: chunk)
            }
        }
    }

    private func openSubscription(relay: String, eventIds: [String]) {
        let subId = "feed-engagement-\(UUID().uuidString.prefix(6))"
        let filter = NostrFilter(kinds: [1, 6, 7, 9735], eTags: eventIds, limit: 500)
        let sub = RelayPool.subscribe(relays: [relay], filter: filter, id: subId)
        liveSubs.append(sub)

        let consumer = Task { [weak self] in
            for await (event, relayUrl) in sub.events {
                self?.ingest(event, relayUrl: relayUrl)
            }
        }
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            sub.cancel()
            consumer.cancel()
            self?.prune(sub: sub)
        }
        liveTasks.append(consumer)
        liveTasks.append(watchdog)
    }

    private func prune(sub: RelaySubscription) {
        liveSubs.removeAll { $0 === sub }
    }

    // MARK: - Ingest

    private func ingest(_ event: NostrEvent, relayUrl: String) {
        guard seenEngagementIds.insert(event.id).inserted else { return }

        // Aggregate against the most-specific (last) e-tag, ignoring `mention` markers — same
        // rule as ThreadViewModel.ingestEngagement.
        let targets = event.tags.compactMap { tag -> String? in
            guard tag.count >= 2, tag[0] == "e" else { return nil }
            if tag.count >= 4, tag[3] == "mention" { return nil }
            return tag[1]
        }
        guard let primary = targets.last, queriedIds.contains(primary) else { return }

        var current = counts[primary] ?? EngagementCounts()
        current.seenRelays.insert(relayUrl)
        switch event.kind {
        case 1:
            current.replies += 1
        case 6:
            current.reposts += 1
            if !current.reposters.contains(event.pubkey) {
                current.reposters.append(event.pubkey)
            }
        case 7:
            // Dedupe by (target, pubkey, content) so an optimistic apply followed by the
            // server-streamed copy doesn't double-count.
            let reactionKey = "\(primary)|\(event.pubkey)|\(event.content)"
            guard seenReactionKeys.insert(reactionKey).inserted else { return }
            current.reactions += 1
            let reactor = Reactor(
                pubkey: event.pubkey,
                emoji: event.content,
                customEmojiUrl: Self.customEmojiUrl(for: event.content, in: event.tags)
            )
            if !current.reactors.contains(where: { $0.pubkey == reactor.pubkey && $0.emoji == reactor.emoji }) {
                current.reactors.append(reactor)
            }
        case 9735:
            var sats: Int64 = 0
            if let bolt = event.tags.first(where: { $0.first == "bolt11" && $0.count >= 2 })?[1],
               let decoded = Bolt11.decode(bolt),
               let amt = decoded.amountSats {
                sats = amt
            }
            current.zapSats += sats
            current.zapCount += 1

            // Extract the true zapper pubkey + message from the description tag (NIP-57):
            // event.pubkey is the LNURL server publishing the receipt, not the actual zapper.
            var zapperPubkey = event.pubkey
            var message = ""
            if let descTag = event.tags.first(where: { $0.first == "description" && $0.count >= 2 }),
               let descData = descTag[1].data(using: .utf8),
               let descJson = try? JSONSerialization.jsonObject(with: descData) as? [String: Any] {
                if let p = descJson["pubkey"] as? String { zapperPubkey = p }
                if let c = descJson["content"] as? String { message = c }
            }
            current.zappers.append(Zapper(pubkey: zapperPubkey, sats: sats, message: message))
        default:
            return
        }
        counts[primary] = current
    }

    /// If `content` is a NIP-30 `:shortcode:` reaction, find the matching `["emoji", shortcode, url]`
    /// tag the reactor included on their kind-7 event and return the image URL. Returns nil for
    /// Unicode reactions or when the tag is missing (some senders forget it).
    static func customEmojiUrl(for content: String, in tags: [[String]]) -> String? {
        guard content.hasPrefix(":"), content.hasSuffix(":"), content.count > 2 else { return nil }
        let shortcode = String(content.dropFirst().dropLast())
        for tag in tags where tag.count >= 3 && tag[0] == "emoji" && tag[1] == shortcode {
            return tag[2]
        }
        return nil
    }
}
