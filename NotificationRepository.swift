import Foundation
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// In-memory store for inbound notification events. Mirrors Android's flat-row
/// model — every event is its own row, no grouping, no aggregation. LRU dedup,
/// timestamp-desc ordering, persistent only for last-read / latest-seen /
/// self-event-id state.
@MainActor
@Observable
final class NotificationRepository {
    static let shared = NotificationRepository()

    private(set) var flatItems: [FlatNotificationItem] = []
    private(set) var summary: NotificationSummary = NotificationSummary()
    /// targetEventId → optimistic kind-1 reply events the user has just sent.
    /// Rendered instantly under the expanded composer. Keyed by the event being
    /// replied to (the actor's reply/quote/mention event id).
    private(set) var inlineReplies: [String: [NostrEvent]] = [:]
    /// Cache of every inbound event we've ingested, keyed by id. Lets row views
    /// render the actor's note (kind 1/quote/mention) without a re-fetch.
    /// Capped by trimming alongside the seen-id LRU.
    private(set) var eventCache: [String: NostrEvent] = [:]

    func event(forId id: String) -> NostrEvent? { eventCache[id] }

    /// Caller-supplied set of the user's most-recent kind-1 ids. Drives reply/
    /// quote/repost/reaction reference-event ownership checks. NotificationsViewModel
    /// keeps this fresh.
    var selfEventIds: Set<String> = []

    private var seenEventIds: Set<String> = []
    private var seenOrder: [String] = []
    private static let seenCap = 2000
    private static let flatCap = 500

    private var activePubkey: String = ""

    /// Wall-clock at first construction. Mirrors Android's `soundEligibleAfter`
    /// so 24h backfill after a cold start never blasts sounds for already-old
    /// events.
    private let sessionStartTime: Int = Int(Date().timeIntervalSince1970)

    func bind(activePubkey: String) {
        if activePubkey != self.activePubkey {
            self.activePubkey = activePubkey
            flatItems = []
            summary = NotificationSummary()
            inlineReplies = [:]
            eventCache = [:]
            seenEventIds = []
            seenOrder = []
            // Warm-load self event ids from prior launch so cold-start filters work even before
            // the first network call returns.
            let cached = UserDefaults.standard.stringArray(forKey: "notif_self_eventids_\(activePubkey)") ?? []
            selfEventIds = Set(cached)
        }
    }

    // MARK: - Ingestion

    /// Returns true if the event produced a notification (was relevant + not duplicate).
    /// Pass `persist: false` when re-ingesting events that came *from* the local cache to
    /// avoid pointless write-back churn.
    @discardableResult
    func ingest(_ event: NostrEvent, relayUrl: String, isFromDmRelay: Bool = false, persist: Bool = true) -> Bool {
        guard !activePubkey.isEmpty else { return false }
        guard insertSeen(event.id) else { return false }

        // Drop the user's own actions for non-zap kinds — your own reply/quote/repost/
        // reaction shouldn't ping you. Zaps are evaluated by the resolved zap-request
        // pubkey inside `classifyZap`, since the receipt's `pubkey` is the LN service.
        if event.kind != 9735 && event.pubkey == activePubkey { return false }

        let item: FlatNotificationItem?
        switch event.kind {
        case 1:    item = classifyKind1(event)
        case 6:    item = classifyRepost(event)
        case 7:    item = classifyReaction(event)
        case 9735: item = classifyZap(event, isFromDmRelay: isFromDmRelay)
        case Nip88.kindPollResponse: item = classifyPollVote(event)
        default:   item = nil
        }

        guard let item else { return false }
        // Self-zap (zapping your own note from your own wallet) — drop after
        // classification, since `actorPubkey` is the resolved zap-request signer.
        if item.kind == .zap && item.actorPubkey == activePubkey { return false }
        eventCache[event.id] = event
        // Insert in timestamp-desc sorted position so the FIFO eviction at the
        // tail actually drops the oldest item. A backfill burst delivers items
        // out of order — without this, old events get placed at index 0 and
        // push the most recent (in-window) items off the end of the buffer,
        // which silently zeroes out `computeSummary24h`'s last-24h counters.
        // Apply the array mutation in a non-animating transaction so any
        // ambient SwiftUI animation in scope (e.g. the audio-player slide on
        // the parent shell) can't catch a sorted insert and "float" a late-
        // arriving row down from its insertion index over existing rows.
        let insertIdx = flatItems.firstIndex(where: { $0.timestamp < item.timestamp }) ?? flatItems.count
        withTransaction(Transaction(animation: nil)) {
            flatItems.insert(item, at: insertIdx)
            if flatItems.count > Self.flatCap { flatItems.removeLast(flatItems.count - Self.flatCap) }
        }

        summary = computeSummary24h()
        bumpLatestTimestamp(item.timestamp)

        // Mirror to ObjectBox so the next launch can paint instantly from disk.
        // Fire-and-forget — the actor handles its own queue and `persist` is a
        // no-op for kinds outside the persistedKinds set.
        if persist {
            Task { await EventPersistQueue.shared.enqueue(event) }
        }
        fireEffects(for: item, persist: persist)
        return true
    }

    private func fireEffects(for item: FlatNotificationItem, persist: Bool) {
        guard persist else { return }
        guard item.timestamp >= sessionStartTime else { return }
        #if canImport(UIKit)
        let state = UIApplication.shared.applicationState
        guard state == .active else { return }
        #endif
        let soundsOn = AppSettings.shared.notificationSoundsEnabled
        switch item.kind {
        case .reply:
            if soundsOn { NotificationSounds.shared.play(.reply) }
            Haptics.shared.pulse()
        case .reaction, .repost, .mention, .quote:
            if soundsOn { NotificationSounds.shared.play(.blip) }
            Haptics.shared.blip()
        case .zap:
            if soundsOn { NotificationSounds.shared.play(.zap) }
            Haptics.shared.zapBuzz()
        case .pollVote, .dm:
            break
        }
    }

    func addInlineReply(_ event: NostrEvent, targetEventId: String) {
        var current = inlineReplies[targetEventId] ?? []
        current.append(event)
        inlineReplies[targetEventId] = current
    }

    /// Replace the DM rows in `flatItems` with the latest snapshot from
    /// DmRepository. One FlatNotificationItem per conversation, kind == .dm.
    func upsertDms(_ items: [FlatNotificationItem]) {
        withTransaction(Transaction(animation: nil)) {
            flatItems.removeAll { $0.kind == .dm }
            for item in items {
                let i = flatItems.firstIndex(where: { $0.timestamp < item.timestamp }) ?? flatItems.count
                flatItems.insert(item, at: i)
            }
            if flatItems.count > Self.flatCap { flatItems.removeLast(flatItems.count - Self.flatCap) }
        }
        summary = computeSummary24h()
    }

    // MARK: - Classification

    private func classifyKind1(_ event: NostrEvent) -> FlatNotificationItem? {
        // Reply: any "e" tag pointing at one of my notes wins.
        if let replyTarget = event.tags.first(where: { $0.first == "e" && $0.count >= 2 && selfEventIds.contains($0[1]) }) {
            let refId = replyTarget[1]
            let hint = replyTarget.count >= 3 ? [replyTarget[2]] : []
            return FlatNotificationItem(
                id: event.id,
                kind: .reply,
                actorPubkey: event.pubkey,
                referencedEventId: refId,
                timestamp: event.createdAt,
                relayHints: hint
            )
        }
        // Quote: "q" tag pointing at one of my notes (NIP-18-style quote).
        if let quoteTag = event.tags.first(where: { $0.first == "q" && $0.count >= 2 && selfEventIds.contains($0[1]) }) {
            return FlatNotificationItem(
                id: event.id,
                kind: .quote,
                actorPubkey: event.pubkey,
                referencedEventId: event.id,
                timestamp: event.createdAt,
                quoteEventId: quoteTag[1],
                actorEventId: event.id,
                relayHints: quoteTag.count >= 3 ? [quoteTag[2]] : []
            )
        }
        // Mention: p-tag points at me but it's not a reply or quote of mine.
        if event.tags.contains(where: { $0.first == "p" && $0.count >= 2 && $0[1] == activePubkey }) {
            return FlatNotificationItem(
                id: event.id,
                kind: .mention,
                actorPubkey: event.pubkey,
                referencedEventId: event.id,
                timestamp: event.createdAt
            )
        }
        return nil
    }

    private func classifyRepost(_ event: NostrEvent) -> FlatNotificationItem? {
        guard let eTag = event.tags.first(where: { $0.first == "e" && $0.count >= 2 }) else { return nil }
        let refId = eTag[1]
        guard selfEventIds.contains(refId) else { return nil }
        return FlatNotificationItem(
            id: event.id,
            kind: .repost,
            actorPubkey: event.pubkey,
            referencedEventId: refId,
            timestamp: event.createdAt
        )
    }

    private func classifyReaction(_ event: NostrEvent) -> FlatNotificationItem? {
        // NIP-25: last "e" tag is the reaction target.
        guard let eTag = event.tags.last(where: { $0.first == "e" && $0.count >= 2 }) else { return nil }
        let refId = eTag[1]
        guard selfEventIds.contains(refId) else { return nil }
        let raw = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let emoji: String
        switch raw {
        case "", "+": emoji = "❤"
        case "-":     emoji = "💔"
        default:      emoji = raw
        }
        // Custom emoji (`:shortcode:`) → look for matching emoji tag for the URL.
        // Kick off an image fetch immediately so the row renders the bitmap
        // instead of literal text.
        var emojiUrl: String? = nil
        if emoji.hasPrefix(":"), emoji.hasSuffix(":") {
            let shortcode = String(emoji.dropFirst().dropLast())
            if let tag = event.tags.first(where: { $0.first == "emoji" && $0.count >= 3 && $0[1] == shortcode }) {
                emojiUrl = tag[2]
                EmojiImageCache.shared.ensureLoaded(tag[2])
            }
        }
        return FlatNotificationItem(
            id: event.id,
            kind: .reaction,
            actorPubkey: event.pubkey,
            referencedEventId: refId,
            timestamp: event.createdAt,
            emoji: emoji,
            emojiUrl: emojiUrl
        )
    }

    private func classifyZap(_ event: NostrEvent, isFromDmRelay: Bool) -> FlatNotificationItem? {
        // Receipt must p-tag the recipient.
        guard event.tags.contains(where: { $0.first == "p" && $0.count >= 2 && $0[1] == activePubkey }) else { return nil }
        // Either targets a specific note (verify ownership) or is a profile zap (skip in v1).
        guard let eTag = event.tags.first(where: { $0.first == "e" && $0.count >= 2 }) else { return nil }
        let refId = eTag[1]
        guard selfEventIds.contains(refId) else { return nil }

        var sats: Int64 = 0
        if let bolt = event.tags.first(where: { $0.first == "bolt11" && $0.count >= 2 })?[1],
           let decoded = Bolt11.decode(bolt), let amt = decoded.amountSats {
            sats = amt
        }

        var actor = event.pubkey
        var message = ""
        if let descTag = event.tags.first(where: { $0.first == "description" && $0.count >= 2 }),
           let descData = descTag[1].data(using: .utf8),
           let descJson = try? JSONSerialization.jsonObject(with: descData) as? [String: Any] {
            if let p = descJson["pubkey"] as? String { actor = p }
            if let c = descJson["content"] as? String { message = c }
        }

        // If the receipt targets one of our zap polls, surface the chosen option index.
        var zapPollOptionIndex: Int? = nil
        if let pollEvent = eventCache[refId], pollEvent.kind == Nip69.kindZapPoll {
            zapPollOptionIndex = Nip69.getZapPollOptionFromZapReceipt(event)
        }

        return FlatNotificationItem(
            id: event.id,
            kind: .zap,
            actorPubkey: actor,
            referencedEventId: refId,
            timestamp: event.createdAt,
            zapSats: sats,
            zapMessage: message,
            isPrivateZap: isFromDmRelay,
            zapPollOptionIndex: zapPollOptionIndex
        )
    }

    private func classifyPollVote(_ event: NostrEvent) -> FlatNotificationItem? {
        guard let pollId = Nip88.getPollEventId(event), selfEventIds.contains(pollId) else { return nil }
        let optionIds = Nip88.getResponseOptionIds(event)
        guard !optionIds.isEmpty else { return nil }
        return FlatNotificationItem(
            id: event.id,
            kind: .pollVote,
            actorPubkey: event.pubkey,
            referencedEventId: pollId,
            timestamp: event.createdAt,
            voteOptionIds: optionIds
        )
    }

    /// Drop every trace of `pubkey` from the in-memory notification state.
    /// Called when the user blocks someone — without this, notifications they
    /// triggered linger in `flatItems` and `eventCache` until cold-launch.
    func purgeAuthor(_ pubkey: String) {
        eventCache = eventCache.filter { $0.value.pubkey != pubkey }
        flatItems.removeAll { $0.actorPubkey == pubkey }
        for (key, replies) in inlineReplies {
            let filtered = replies.filter { $0.pubkey != pubkey }
            if filtered.isEmpty {
                inlineReplies.removeValue(forKey: key)
            } else {
                inlineReplies[key] = filtered
            }
        }
        summary = computeSummary24h()
    }

    // MARK: - Summary (last 24h)

    private func computeSummary24h() -> NotificationSummary {
        var s = NotificationSummary()
        let cutoff = Int(Date().timeIntervalSince1970) - 86400
        for item in flatItems where item.timestamp >= cutoff {
            switch item.kind {
            case .reply:    s.replyCount += 1
            case .reaction: s.reactionCount += 1
            case .repost:   s.repostCount += 1
            case .zap:
                s.zapCount += 1
                s.zapSats += item.zapSats
            case .mention:  s.mentionCount += 1
            case .quote:    s.quoteCount += 1
            case .dm:       s.dmCount += 1
            case .pollVote: s.pollVoteCount += 1
            }
        }
        return s
    }

    // MARK: - Persistence (UserDefaults, scoped by active pubkey)

    private var lastReadKey: String { "notif_last_read_\(activePubkey)" }
    private var latestTsKey: String { "notif_latest_ts_\(activePubkey)" }
    private var selfIdsKey: String { "notif_self_eventids_\(activePubkey)" }

    var lastReadTimestamp: Int {
        get { UserDefaults.standard.integer(forKey: lastReadKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastReadKey) }
    }

    var latestNotifTimestamp: Int {
        get { UserDefaults.standard.integer(forKey: latestTsKey) }
    }

    /// True if any non-DM notification has arrived since the user last opened the screen.
    var hasUnread: Bool {
        let last = lastReadTimestamp
        for item in flatItems where item.kind != .dm {
            if item.timestamp > last { return true }
        }
        return false
    }

    func markAllRead() {
        let now = Int(Date().timeIntervalSince1970)
        let candidate = max(latestNotifTimestamp, now)
        lastReadTimestamp = candidate
    }

    func persistSelfEventIds() {
        UserDefaults.standard.set(Array(selfEventIds), forKey: selfIdsKey)
    }

    private func bumpLatestTimestamp(_ ts: Int) {
        if ts > latestNotifTimestamp {
            UserDefaults.standard.set(ts, forKey: latestTsKey)
        }
    }

    // MARK: - Internal

    private func insertSeen(_ id: String) -> Bool {
        if seenEventIds.contains(id) { return false }
        seenEventIds.insert(id)
        seenOrder.append(id)
        if seenOrder.count > Self.seenCap {
            let drop = seenOrder.count - Self.seenCap
            for old in seenOrder.prefix(drop) { seenEventIds.remove(old) }
            seenOrder.removeFirst(drop)
        }
        return true
    }
}
