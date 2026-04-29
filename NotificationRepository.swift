import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// In-memory store for inbound notification events. Mirrors Android's NotificationRepository:
/// LRU dedup, group + flat caps, persistent only for last-read / latest-seen / self-event-id state.
@MainActor
@Observable
final class NotificationRepository {
    static let shared = NotificationRepository()

    private(set) var groups: [NotificationGroup] = []
    private(set) var flatItems: [FlatNotificationItem] = []
    private(set) var summary: NotificationSummary = NotificationSummary()
    /// groupId → optimistic kind-1 reply events the user has just sent. Rendered instantly under
    /// the expanded composer.
    private(set) var inlineReplies: [String: [NostrEvent]] = [:]
    /// Cache of every inbound event we've ingested, keyed by id. Lets row views render the
    /// actor's note (kind 1/quote/mention) without a re-fetch. Capped by trimming alongside
    /// the seen-id LRU.
    private(set) var eventCache: [String: NostrEvent] = [:]

    func event(forId id: String) -> NostrEvent? { eventCache[id] }

    /// Caller-supplied set of the user's most-recent kind-1 ids. Drives reply/quote/repost/reaction
    /// reference-event ownership checks. NotificationsViewModel keeps this fresh.
    var selfEventIds: Set<String> = []

    private var seenEventIds: Set<String> = []
    private var seenOrder: [String] = []
    private static let seenCap = 2000
    private static let groupCap = 200
    private static let flatCap = 500

    /// Aggregating bucket keyed by referenced event id. Replies/quotes/mentions get unique keys
    /// so each remains its own row; reactions/zaps/reposts on the same target collapse together.
    private var byKey: [String: NotificationGroup] = [:]

    private var activePubkey: String = ""
    private var dmPlaceholders: [String: NotificationGroup] = [:]

    /// Wall-clock at first construction. Mirrors Android's `soundEligibleAfter` so 24h backfill
    /// after a cold start never blasts sounds for already-old events.
    private let sessionStartTime: Int = Int(Date().timeIntervalSince1970)

    func bind(activePubkey: String) {
        if activePubkey != self.activePubkey {
            self.activePubkey = activePubkey
            groups = []
            flatItems = []
            summary = NotificationSummary()
            inlineReplies = [:]
            eventCache = [:]
            seenEventIds = []
            seenOrder = []
            byKey = [:]
            dmPlaceholders = [:]
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

        let item: FlatNotificationItem?
        switch event.kind {
        case 1:  item = classifyKind1(event)
        case 6:  item = classifyRepost(event)
        case 7:  item = classifyReaction(event)
        case 9735: item = classifyZap(event, isFromDmRelay: isFromDmRelay)
        case Nip88.kindPollResponse: item = classifyPollVote(event)
        default: item = nil
        }

        guard let item else { return false }
        eventCache[event.id] = event
        flatItems.insert(item, at: 0)
        if flatItems.count > Self.flatCap { flatItems.removeLast(flatItems.count - Self.flatCap) }

        mergeIntoGroup(item)
        rebuild()
        bumpLatestTimestamp(item.timestamp)

        // Mirror to ObjectBox so the next launch can paint instantly from disk. Fire-and-
        // forget — the actor handles its own queue and `persist` is a no-op for kinds outside
        // the persistedKinds set.
        if persist {
            Task.detached { await EventStore.shared.persist([event]) }
        }
        fireEffects(for: item, persist: persist)
        return true
    }

    private func fireEffects(for item: FlatNotificationItem, persist: Bool) {
        let now = Int(Date().timeIntervalSince1970)
        NSLog("[NotifFX] kind=%@ persist=%d ts=%d sessionStart=%d delta=%d", String(describing: item.kind), persist ? 1 : 0, item.timestamp, sessionStartTime, now - item.timestamp)
        guard persist else { NSLog("[NotifFX] dropped: persist=false"); return }
        guard item.timestamp >= sessionStartTime else {
            NSLog("[NotifFX] dropped: ts %d < sessionStart %d", item.timestamp, sessionStartTime)
            return
        }
        #if canImport(UIKit)
        let state = UIApplication.shared.applicationState
        guard state == .active else {
            NSLog("[NotifFX] dropped: applicationState=%d (not .active)", state.rawValue)
            return
        }
        #endif
        let soundsOn = AppSettings.shared.notificationSoundsEnabled
        NSLog("[NotifFX] firing kind=%@ soundsOn=%d", String(describing: item.kind), soundsOn ? 1 : 0)
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

    func addInlineReply(_ event: NostrEvent, groupId: String) {
        var current = inlineReplies[groupId] ?? []
        current.append(event)
        inlineReplies[groupId] = current
    }

    /// Replace the DM-derived rows from observation. Caller passes a snapshot of all conversations
    /// projected as `.dm` groups; we fold them into `byKey` keyed by `dm:<conversationKey>`.
    func setDmGroups(_ dmGroups: [NotificationGroup]) {
        // Drop any existing DM placeholders, then re-add from the snapshot.
        for key in dmPlaceholders.keys { byKey.removeValue(forKey: key) }
        dmPlaceholders.removeAll(keepingCapacity: true)
        for g in dmGroups {
            let key = g.id
            byKey[key] = g
            dmPlaceholders[key] = g
        }
        rebuild()
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
        // Custom emoji (`:shortcode:`) → look for matching emoji tag for the URL. Kick off
        // an image fetch immediately so the row renders the bitmap instead of literal text.
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

    // MARK: - Grouping

    private func mergeIntoGroup(_ item: FlatNotificationItem) {
        switch item.kind {
        case .reaction, .repost, .zap:
            let key = "engagement:\(item.referencedEventId)"
            let existing = byKey[key]
            byKey[key] = mergeEngagement(existing: existing, item: item, key: key)
        case .reply:
            let key = "reply:\(item.id)"
            byKey[key] = .reply(
                id: key,
                sender: item.actorPubkey,
                replyEventId: item.id,
                refEventId: item.referencedEventId,
                latestTs: item.timestamp,
                relayHints: item.relayHints
            )
        case .quote:
            let key = "quote:\(item.id)"
            byKey[key] = .quote(
                id: key,
                sender: item.actorPubkey,
                actorEventId: item.actorEventId ?? item.id,
                quoteEventId: item.quoteEventId ?? "",
                latestTs: item.timestamp,
                relayHints: item.relayHints
            )
        case .mention:
            let key = "mention:\(item.id)"
            byKey[key] = .mention(
                id: key,
                sender: item.actorPubkey,
                eventId: item.id,
                latestTs: item.timestamp,
                relayHints: item.relayHints
            )
        case .pollVote:
            let key = "pollvotes:\(item.referencedEventId)"
            byKey[key] = mergePollVotes(existing: byKey[key], item: item, key: key)
        case .dm:
            // DM groups are managed via setDmGroups(_:). Ignore here.
            break
        }
    }

    private func mergePollVotes(
        existing: NotificationGroup?,
        item: FlatNotificationItem,
        key: String
    ) -> NotificationGroup {
        var votersByOptionId: [String: [String]] = [:]
        var latestTs = item.timestamp
        if case let .pollVotes(_, _, prev, ts) = existing {
            votersByOptionId = prev
            latestTs = max(ts, item.timestamp)
        }
        for optionId in item.voteOptionIds {
            var voters = votersByOptionId[optionId] ?? []
            if !voters.contains(item.actorPubkey) {
                voters.append(item.actorPubkey)
            }
            votersByOptionId[optionId] = voters
        }
        return .pollVotes(
            id: key,
            refEventId: item.referencedEventId,
            votersByOptionId: votersByOptionId,
            latestTs: latestTs
        )
    }

    private func mergeEngagement(
        existing: NotificationGroup?,
        item: FlatNotificationItem,
        key: String
    ) -> NotificationGroup {
        var emojiByActor: [String: String] = [:]
        var emojiUrlByActor: [String: String] = [:]
        var zaps: [ZapEntry] = []
        var reposters: [String] = []
        var latestTs = item.timestamp
        if case let .reactions(_, _, e, eu, z, r, ts) = existing {
            emojiByActor = e
            emojiUrlByActor = eu
            zaps = z
            reposters = r
            latestTs = max(ts, item.timestamp)
        }
        switch item.kind {
        case .reaction:
            emojiByActor[item.actorPubkey] = item.emoji ?? "❤"
            if let url = item.emojiUrl { emojiUrlByActor[item.actorPubkey] = url }
        case .zap:
            // De-dup zaps by receipt id.
            if !zaps.contains(where: { $0.receiptEventId == item.id }) {
                zaps.append(ZapEntry(
                    pubkey: item.actorPubkey,
                    sats: item.zapSats,
                    message: item.zapMessage,
                    createdAt: item.timestamp,
                    receiptEventId: item.id,
                    isPrivate: item.isPrivateZap
                ))
            }
        case .repost:
            if !reposters.contains(item.actorPubkey) { reposters.append(item.actorPubkey) }
        default: break
        }
        return .reactions(
            id: key,
            refEventId: item.referencedEventId,
            emojiByActor: emojiByActor,
            emojiUrlByActor: emojiUrlByActor,
            zaps: zaps,
            reposters: reposters,
            latestTs: latestTs
        )
    }

    private func rebuild() {
        var sorted = Array(byKey.values)
        sorted.sort { $0.latestTs > $1.latestTs }
        if sorted.count > Self.groupCap { sorted = Array(sorted.prefix(Self.groupCap)) }
        groups = sorted
        summary = computeSummary24h()
    }

    /// Drop every trace of `pubkey` from the in-memory notification state.
    /// Called when the user blocks someone — without this, single-actor
    /// notifications they triggered (`user quoted`, `user replied`) plus their
    /// contributions to multi-actor reaction / zap / repost groups linger in
    /// `groups` and `eventCache` until the next cold-launch.
    func purgeAuthor(_ pubkey: String) {
        eventCache = eventCache.filter { $0.value.pubkey != pubkey }
        flatItems.removeAll { $0.actorPubkey == pubkey }
        for (groupId, replies) in inlineReplies {
            let filtered = replies.filter { $0.pubkey != pubkey }
            if filtered.isEmpty {
                inlineReplies.removeValue(forKey: groupId)
            } else {
                inlineReplies[groupId] = filtered
            }
        }

        // Walk byKey: drop single-actor groups whose sender is the blocked
        // pubkey; rewrite multi-actor reaction groups to remove their entries.
        var rewritten: [String: NotificationGroup] = [:]
        for (key, group) in byKey {
            switch group {
            case .reply(_, let sender, _, _, _, _),
                 .quote(_, let sender, _, _, _, _),
                 .mention(_, let sender, _, _, _):
                if sender == pubkey { continue }
                rewritten[key] = group
            case .reactions(let id, let refEventId, var emojiByActor, var emojiUrlByActor, var zaps, var reposters, let latestTs):
                emojiByActor.removeValue(forKey: pubkey)
                emojiUrlByActor.removeValue(forKey: pubkey)
                zaps.removeAll { $0.pubkey == pubkey }
                reposters.removeAll { $0 == pubkey }
                if emojiByActor.isEmpty && zaps.isEmpty && reposters.isEmpty { continue }
                rewritten[key] = .reactions(
                    id: id,
                    refEventId: refEventId,
                    emojiByActor: emojiByActor,
                    emojiUrlByActor: emojiUrlByActor,
                    zaps: zaps,
                    reposters: reposters,
                    latestTs: latestTs
                )
            case .pollVotes(let id, let refEventId, var votersByOptionId, let latestTs):
                for (optionId, voters) in votersByOptionId {
                    let filtered = voters.filter { $0 != pubkey }
                    if filtered.isEmpty {
                        votersByOptionId.removeValue(forKey: optionId)
                    } else {
                        votersByOptionId[optionId] = filtered
                    }
                }
                if votersByOptionId.isEmpty { continue }
                rewritten[key] = .pollVotes(
                    id: id,
                    refEventId: refEventId,
                    votersByOptionId: votersByOptionId,
                    latestTs: latestTs
                )
            case .dm:
                // DMs preserve their own block UX (the user can leave the conversation);
                // don't auto-drop placeholder rows here.
                rewritten[key] = group
            }
        }
        byKey = rewritten
        rebuild()
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
        // DM count comes from active DM placeholders (each represents a recent conversation tail).
        for case .dm(_, _, _, let ts, _) in dmPlaceholders.values where ts >= cutoff {
            s.dmCount += 1
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
