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

    /// Cache a referenced poll event (kind 1068 / 6969) without creating a
    /// notification row. Lets a collapsed `.pollVote` / `.zap` row resolve its
    /// selected-option label(s) via `event(forId:)` — `classifyPollVote` only
    /// stores the chosen option *ids*, and the human-readable labels live in
    /// the poll's `option` / `poll_option` tags. Idempotent; never overwrites a
    /// fuller copy already present.
    func cacheReferencedEvent(_ event: NostrEvent) {
        guard event.kind == Nip88.kindPoll || event.kind == Nip69.kindZapPoll else { return }
        if eventCache[event.id] == nil { eventCache[event.id] = event }
    }

    /// Caller-supplied set of the user's most-recent kind-1 ids. Drives reply/
    /// quote/repost/reaction reference-event ownership checks. NotificationsViewModel
    /// keeps this fresh.
    var selfEventIds: Set<String> = []

    private var seenEventIds: Set<String> = []
    private var seenOrder: [String] = []
    private static let seenCap = 2000
    private static let flatCap = 500

    private var activePubkey: String = ""
    /// Active user's raw 32-byte privkey, set by `NotificationsViewModel` after
    /// `bind(activePubkey:)`. Required for DIP-03 zap receipt decoding — the
    /// classifier attempts to decrypt the inner kind-9733 with this privkey
    /// and falls back to the public kind-9734 pubkey on failure. nil for
    /// remote-signer / watch-only accounts.
    private var activePrivkey32: Data? = nil

    func setActivePrivkey32(_ data: Data?) {
        activePrivkey32 = data
    }

    /// Wall-clock floor for firing notification sounds/haptics. Initialized to
    /// app-launch and bumped to `now` every time the app re-enters the
    /// foreground, so an overnight backlog of relay events doesn't blast
    /// hundreds of sounds when the user reopens the app. Only events whose
    /// `createdAt` is at or after this threshold are considered "live arrivals
    /// the user is here to witness."
    private var soundEligibleAfter: Int = Int(Date().timeIntervalSince1970)

    init() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.soundEligibleAfter = Int(Date().timeIntervalSince1970)
            }
        }
        #endif
        // Track user-authored kind-1 / poll publishes in real time so a reply
        // landing seconds later classifies as `.reply` instead of falling
        // through to `.mention`. Without this hook, `selfEventIds` only learns
        // about new own-events when the 5-min `refreshSelfEventIds` cycle
        // queries relays — long enough that an early reply gets misclassified
        // and locked in by the `insertSeen` dedup.
        NotificationCenter.default.addObserver(
            forName: .nostrEventPublished,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.trackOwnPublish(note)
            }
        }
    }

    private func trackOwnPublish(_ note: Notification) {
        guard let event = note.userInfo?["event"] as? NostrEvent else { return }
        guard !activePubkey.isEmpty, event.pubkey == activePubkey else { return }
        switch event.kind {
        case 1, Nip88.kindPoll, Nip69.kindZapPoll:
            if selfEventIds.insert(event.id).inserted {
                persistSelfEventIds()
            }
            // Cache the poll itself so a vote landing later this session can
            // resolve its selected-option label(s) in the collapsed row.
            cacheReferencedEvent(event)
        default:
            return
        }
    }

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
    /// avoid pointless write-back churn. Pass `isPrivate: true` when the event was
    /// materialized from an unwrapped gift wrap (private reply / reaction); the resulting
    /// `FlatNotificationItem.isPrivate` drives the lock icon in the row.
    @discardableResult
    func ingest(_ event: NostrEvent, relayUrl: String, isFromDmRelay: Bool = false, isPrivate: Bool = false, persist: Bool = true) -> Bool {
        guard !activePubkey.isEmpty else { return false }
        // Safety chokepoint. Every caller — live subs, 24h backfill, disk
        // hydration, future paths — funnels through ingest, so the full
        // SafetyFilter gate lives HERE rather than at each call site (the
        // backfill path once forgot its pre-filter and leaked unfiltered
        // events). Runs before `insertSeen` so a drop under today's rules
        // doesn't permanently mark the id seen — if the user later relaxes
        // the filter, a re-delivered event can still notify. Two carve-outs:
        // gift-wrap rumors (`isPrivate`) are e2e-private and WoT/word-exempt
        // by design, and kind-9735 receipts are signed by the LN service —
        // their real sender is judged post-classification below.
        if !isPrivate, event.kind != 9735,
           SafetyFilter.shared.shouldDrop(event: event, context: .notifications) {
            return false
        }
        // Zaps defer the seen-mark until their actor gate below passes — the
        // gate needs `classifyZap`'s resolved sender first, and marking a
        // dropped receipt seen here would permanently silence it even after
        // the user relaxes the filter.
        guard event.kind == 9735 || insertSeen(event.id) else { return false }

        // Drop the user's own actions for non-zap kinds — your own reply/quote/repost/
        // reaction shouldn't ping you. Zaps are evaluated by the resolved zap-request
        // pubkey inside `classifyZap`, since the receipt's `pubkey` is the LN service.
        if event.kind != 9735 && event.pubkey == activePubkey { return false }

        var item: FlatNotificationItem?
        switch event.kind {
        case 1:    item = classifyKind1(event)
        case 6:    item = classifyRepost(event)
        case 7:    item = classifyReaction(event)
        case 9735: item = classifyZap(event, isFromDmRelay: isFromDmRelay)
        case Nip88.kindPollResponse: item = classifyPollVote(event)
        default:   item = nil
        }

        if isPrivate { item?.isPrivate = true }

        guard let item else { return false }
        // Self-zap (zapping your own note from your own wallet) — drop after
        // classification, since `actorPubkey` is the resolved zap-request signer.
        if item.kind == .zap && item.actorPubkey == activePubkey { return false }
        // Zap safety gate — the receipt's `pubkey` is the LN service, so the
        // generic chokepoint above deliberately skipped kind-9735. Judge the
        // resolved zap-request signer instead: blocked senders always drop;
        // non-WoT senders drop unless the zap is private/anonymous
        // (`isPrivateZap`, set by `classifyZap` — NOT the gift-wrap `isPrivate`
        // param, which is never true for zaps): an e2e-private zap reached the
        // user through the same trusted channel as a DM, and an anonymous one
        // has no judgeable sender. Only after the gate passes does the receipt
        // take its seen slot (deferred from the top of ingest).
        if item.kind == .zap {
            if SafetyFilter.shared.snapshot.blockedPubkeys.contains(item.actorPubkey) { return false }
            if !item.isPrivateZap, !SafetyFilter.shared.isWotQualified(item.actorPubkey) { return false }
            guard insertSeen(event.id) else { return false }
        }
        // Sub-thread suppression: don't notify about a reply whose NIP-10 chain
        // includes a blocked author. When non-blocked A replies to blocked B's
        // reply to your note, A's event p-tags B (the ancestor author) — and
        // B's own reply is never persisted, so that p-tag is the only surviving
        // signal. Scope is `.reply` only: a `.mention`/`.quote` targets your
        // content directly and merely incidentally p-tags a blocked user, so
        // dropping those would hide legitimate notifications. This is the single
        // ingest chokepoint, so it also covers the disk-seed hydration path.
        if item.kind == .reply {
            let blocked = SafetyFilter.shared.snapshot.blockedPubkeys
            if !blocked.isEmpty,
               event.tags.contains(where: { $0.count >= 2 && $0[0] == "p" && blocked.contains($0[1]) }) {
                return false
            }
        }
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
        guard item.timestamp >= soundEligibleAfter else { return }
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
        case .pollVote, .pollEnded, .dm:
            break
        }
    }

    /// Insert a synthetic `.pollEnded` row. Called by `NotificationsViewModel`'s
    /// poll-end scan once a poll's `endsAt` / `closed_at` is in the past and we
    /// haven't already surfaced it. Caller is responsible for dedup via
    /// `selfPollEndedNotified` so the row doesn't re-appear after relaunch.
    func insertPollEnded(pollEvent: NostrEvent, endedAt: Int) -> Bool {
        let syntheticId = "poll-ended:\(pollEvent.id)"
        guard insertSeen(syntheticId) else { return false }
        let item = FlatNotificationItem(
            id: syntheticId,
            kind: .pollEnded,
            actorPubkey: pollEvent.pubkey,
            referencedEventId: pollEvent.id,
            timestamp: endedAt
        )
        eventCache[pollEvent.id] = pollEvent
        let insertIdx = flatItems.firstIndex(where: { $0.timestamp < item.timestamp }) ?? flatItems.count
        flatItems.insert(item, at: insertIdx)
        if flatItems.count > Self.flatCap { flatItems.removeLast(flatItems.count - Self.flatCap) }
        summary = computeSummary24h()
        bumpLatestTimestamp(item.timestamp)
        return true
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

    /// Re-run `classifyKind1` over every in-memory `.mention` row and promote
    /// any whose source event actually targets one of the user's notes to
    /// `.reply` (or `.quote`). Called by `NotificationsViewModel` after
    /// `refreshSelfEventIds` discovers ids that weren't in the warm-load /
    /// publish-time set — without this, the row's icon stays frozen at "@"
    /// and the 24h summary counters undercount replies until cold relaunch.
    /// Promotion is one-way (mention → reply / quote); the set only grows
    /// within a refresh, so a row already classified as `.reply` can never
    /// legitimately reverse.
    func reclassifyKind1Mentions() {
        guard !flatItems.isEmpty else { return }
        var changed = false
        withTransaction(Transaction(animation: nil)) {
            for idx in flatItems.indices {
                let item = flatItems[idx]
                guard item.kind == .mention else { continue }
                guard let event = eventCache[item.id] else { continue }
                guard let replacement = classifyKind1(event), replacement.kind != .mention else { continue }
                var updated = replacement
                updated.isPrivate = item.isPrivate
                flatItems[idx] = updated
                changed = true
            }
        }
        if changed {
            summary = computeSummary24h()
        }
    }

    private func classifyKind1(_ event: NostrEvent) -> FlatNotificationItem? {
        // Reply: any "e" tag pointing at one of my notes wins.
        if let selfETag = event.tags.first(where: { $0.first == "e" && $0.count >= 2 && selfEventIds.contains($0[1]) }) {
            // Show what the actor actually replied to — the immediate parent — which for a
            // reply-to-a-reply is someone else's note nested under mine, not my root post.
            let parentId = Nip10.replyTarget(of: event) ?? selfETag[1]
            let parentTag = event.tags.first { $0.first == "e" && $0.count >= 2 && $0[1] == parentId }
            let hint = (parentTag?.count ?? 0) >= 3 ? [parentTag![2]] : []
            return FlatNotificationItem(
                id: event.id,
                kind: .reply,
                actorPubkey: event.pubkey,
                referencedEventId: parentId,
                timestamp: event.createdAt,
                relayHints: hint,
                replyTargetIsMine: selfEventIds.contains(parentId)
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

        // DIP-03 resolution: when the embedded kind-9734 carries a bech32-packed
        // anon tag (`pzap1..._iv1...`) and we have a privkey, decrypt the inner
        // kind-9733 to reveal the real sender + message. Public zaps fall back
        // to the embedded description's pubkey/content. `isFromDmRelay` is kept
        // as a defensive fallback signal for legacy receipts published via the
        // homegrown private-zap path; new DIP-03 receipts arrive on DM relays
        // *and* set the explicit isPrivate flag here.
        let resolved = Nip57.resolveZapSender(receipt: event, recipientPrivkey32: activePrivkey32)
        let actor = resolved?.pubkey ?? event.pubkey
        let message = resolved?.message ?? ""
        let isPrivate = resolved?.isPrivate ?? false

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
            isPrivateZap: isPrivate || isFromDmRelay,
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
        // Identify sub-thread rows BEFORE pruning eventCache: a reply by a
        // non-blocked actor that p-tags the now-blocked `pubkey` is part of a
        // sub-thread we no longer want (mirrors the ingest-time `.reply` drop).
        // Its source event is the only place that link survives, so resolve it
        // from the cache while it's still present.
        let subThreadIds = Set(flatItems.compactMap { item -> String? in
            guard item.kind == .reply, let ev = eventCache[item.id] else { return nil }
            let involvesBlocked = ev.tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == pubkey }
            return involvesBlocked ? item.id : nil
        })
        eventCache = eventCache.filter { $0.value.pubkey != pubkey && !subThreadIds.contains($0.key) }
        flatItems.removeAll { $0.actorPubkey == pubkey || subThreadIds.contains($0.id) }
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

    /// Drop every in-memory notification whose actor fails the current WoT
    /// snapshot. Called on `.safetyFilterChanged` so enabling WoT (or a graph
    /// recompute shrinking the qualified set) scrubs rows that were ingested
    /// under looser rules — without this they'd render until cold relaunch and
    /// keep inflating the 24h summary. Private (gift-wrap) items keep their
    /// blanket WoT exemption; `inlineReplies` are the user's own optimistic
    /// replies and need no pruning. O(flatItems ≤ cap), runs only on snapshot
    /// installs.
    func purgeNonWotQualified() {
        guard SafetyFilter.shared.snapshot.wotEnabled else { return }
        let dropIds = Set(flatItems.compactMap { item -> String? in
            guard !item.isPrivate, !item.isPrivateZap else { return nil }
            return SafetyFilter.shared.isWotQualified(item.actorPubkey) ? nil : item.id
        })
        guard !dropIds.isEmpty else { return }
        eventCache = eventCache.filter { !dropIds.contains($0.key) }
        flatItems.removeAll { dropIds.contains($0.id) }
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
            case .pollVote:  s.pollVoteCount += 1
            case .pollEnded: s.pollEndedCount += 1
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
