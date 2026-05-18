import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class NotificationsViewModel {
    let keypair: Keypair

    var enabledTypes: Set<NotificationFilter> = Set(NotificationFilter.allCases)
    var isLoading: Bool = false

    /// Hidden authors whose NSpam-classified notifications should not appear.
    /// Tracked (not `@ObservationIgnored`) so `filteredItems` re-evaluates when
    /// `maybeScoreReplyForSpam` or `unhideSpamAuthor` mutates this set.
    var hiddenSpamPubkeys: Set<String> = []

    /// Bumped whenever `SafetyFilter`'s snapshot changes so `filteredItems`
    /// re-evaluates against the current blocklist. The repo's in-memory
    /// `flatItems` keeps notifications that were ingested *before* the user
    /// blocked their author — without this trigger they'd remain visible
    /// until app relaunch, since the ingestion-time `SafetyFilter` check
    /// only catches new events.
    private(set) var safetyGeneration: Int = 0

    @ObservationIgnored private var subNotif: RelaySubscription?
    @ObservationIgnored private var subRepliesEtag: RelaySubscription?
    @ObservationIgnored private var subQuotesQtag: RelaySubscription?
    @ObservationIgnored private var subDmZaps: RelaySubscription?
    @ObservationIgnored private var subPollVotes: RelaySubscription?
    @ObservationIgnored private var listenerTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var rearmTask: Task<Void, Never>?
    @ObservationIgnored private var refreshSelfIdsTask: Task<Void, Never>?
    @ObservationIgnored private var dmObserverTask: Task<Void, Never>?

    @ObservationIgnored private var notifRelays: [String] = []
    @ObservationIgnored private var dmRelays: [String] = []
    @ObservationIgnored private var ownWriteRelays: [String] = []
    @ObservationIgnored private let repo = NotificationRepository.shared
    @ObservationIgnored private let dmRepo = DmRepository.shared
    @ObservationIgnored private let profileRepo = ProfileRepository.shared
    @ObservationIgnored private var started = false
    @ObservationIgnored private var spamScoringInflight: Set<String> = []

    static let fallbackRelays = [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://relay.nostr.band",
        "wss://nostr.wine"
    ]

    init(keypair: Keypair) {
        self.keypair = keypair
    }

    // MARK: - Derived state

    /// Filtered, in-memory snapshot rendered by the View. Re-evaluates whenever
    /// `repo.flatItems`, `enabledTypes`, or `hiddenSpamPubkeys` change — under
    /// `@Observable` the dependency tracking happens automatically when the
    /// View reads `viewModel.filteredItems`.
    var filteredItems: [FlatNotificationItem] {
        // Bind to `safetyGeneration` so this view re-evaluates when a
        // block / mute edit lands. Without the read, `@Observable` has no
        // dependency to track and the blocklist check below would never
        // re-run for in-memory items already past the ingest filter.
        _ = safetyGeneration
        let hidden = hiddenSpamPubkeys
        let allowed = enabledTypes
        let blocked = SafetyFilter.shared.snapshot.blockedPubkeys
        return repo.flatItems.filter { item in
            !hidden.contains(item.actorPubkey)
                && !blocked.contains(item.actorPubkey)
                && allowed.contains(NotificationFilter.bucket(for: item.kind))
        }
    }

    var summary: NotificationSummary { repo.summary }
    var hasUnread: Bool { repo.hasUnread }

    // MARK: - Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        repo.bind(activePubkey: keypair.pubkey)
        loadFilterFromDefaults()

        // Prime relay sets synchronously from cached state (UserDefaults + RelayScoreBoard)
        // so live subscriptions can open IMMEDIATELY. Anything we don't have cached falls back
        // to the default relay list. We refresh in the background and reopen subs only if the
        // resolved set actually differs.
        primeRelaySetsFromCache()
        openSubscriptions()
        startRearmCycle()
        startDmObservation()
        startSelfIdsRefreshCycle()
        startBlocklistObservation()

        // Hydrate from ObjectBox in the background so the screen paints instantly from disk
        // on the next render tick. Runs in parallel with the live subs warming up.
        Task { [weak self] in
            guard let self else { return }
            await self.hydrateFromObjectBox()
        }

        // Background freshening: kind-10002 / kind-10050 fetch + self-event-id query + 24h
        // backfill. None of these block the user from seeing live notifications stream in.
        Task { [weak self] in
            guard let self else { return }
            let beforeRelays = Set(self.notifRelays)
            let beforeIds = self.repo.selfEventIds
            await self.resolveRelaySets()
            await self.refreshSelfEventIds()
            let relaysChanged = Set(self.notifRelays) != beforeRelays
            let idsChanged = self.repo.selfEventIds != beforeIds
            if relaysChanged || idsChanged {
                self.reopenSubscriptions()
            }
            await self.backfillRecent()
        }
    }

    private func hydrateFromObjectBox() async {
        let pubkey = keypair.pubkey
        let selfIds = repo.selfEventIds
        let cached = await EventStore.shared.loadNotifications(
            pubkey: pubkey,
            selfEventIds: selfIds,
            limit: 500
        )
        for e in cached {
            // Match the live ingestion's safety filtering — without this, cached
            // notifications from blocked / muted authors render on cold launch
            // until the live subscription catches up.
            if SafetyFilter.shared.shouldDrop(event: e, context: .notifications) { continue }
            _ = repo.ingest(e, relayUrl: "", isFromDmRelay: false, persist: false)
        }
    }

    /// Synchronous relay-set seeding from local caches. Lets `openSubscriptions()` run on the
    /// first tick of `start()` instead of waiting on relay round trips.
    private func primeRelaySetsFromCache() {
        let pubkey = keypair.pubkey
        let cachedRead = UserDefaults.standard.stringArray(forKey: "notif_read_relays_\(pubkey)") ?? []
        let cachedWrite = UserDefaults.standard.stringArray(forKey: "notif_write_relays_\(pubkey)") ?? []
        let scored = RelayScoreBoard.load(pubkey: pubkey)?.scoredRelays.prefix(5).map(\.url) ?? []

        var combined = Set<String>()
        for r in cachedRead { combined.insert(r) }
        for r in scored { combined.insert(r) }
        for r in Self.fallbackRelays { combined.insert(r) }

        // Cap to a reasonable fanout — too many concurrent sockets actually slows first-event
        // latency on iOS. ~10 relays gives strong coverage without thrashing.
        notifRelays = Array(combined.prefix(10)).sorted()
        ownWriteRelays = cachedWrite.isEmpty ? Self.fallbackRelays : cachedWrite
    }

    func stop() {
        started = false
        rearmTask?.cancel(); rearmTask = nil
        refreshSelfIdsTask?.cancel(); refreshSelfIdsTask = nil
        dmObserverTask?.cancel(); dmObserverTask = nil
        for t in listenerTasks { t.cancel() }
        listenerTasks.removeAll()
        subNotif?.cancel(); subNotif = nil
        subRepliesEtag?.cancel(); subRepliesEtag = nil
        subQuotesQtag?.cancel(); subQuotesQtag = nil
        subDmZaps?.cancel(); subDmZaps = nil
        subPollVotes?.cancel(); subPollVotes = nil
    }

    func refresh() async {
        await refreshSelfEventIds()
        await backfillRecent()
        reopenSubscriptions()
    }

    func markAllRead() {
        repo.markAllRead()
    }

    // MARK: - Filter API

    /// Animation used for filter-toggle list reflows. Applied at the
    /// mutation site (rather than as a view-level `.animation(value:)`)
    /// so it only fires for filter changes — `flatItems` inserts arriving
    /// in the same render pass can no longer ride this transaction.
    private static let filterAnimation: Animation = .easeInOut(duration: 0.15)

    func toggleType(_ t: NotificationFilter) {
        withTransaction(Transaction(animation: Self.filterAnimation)) {
            if enabledTypes.contains(t) {
                enabledTypes.remove(t)
            } else {
                enabledTypes.insert(t)
            }
        }
        persistEnabledTypes()
    }

    func isolateType(_ t: NotificationFilter) {
        withTransaction(Transaction(animation: Self.filterAnimation)) {
            enabledTypes = [t]
        }
        persistEnabledTypes()
    }

    func enableAll() {
        withTransaction(Transaction(animation: Self.filterAnimation)) {
            enabledTypes = Set(NotificationFilter.allCases)
        }
        persistEnabledTypes()
    }

    func disableAll() {
        withTransaction(Transaction(animation: Self.filterAnimation)) {
            enabledTypes = []
        }
        persistEnabledTypes()
    }

    private var enabledTypesKey: String { "notif_enabled_types_\(keypair.pubkey)" }

    private func persistEnabledTypes() {
        let raws = enabledTypes.map(\.rawValue)
        UserDefaults.standard.set(raws, forKey: enabledTypesKey)
    }

    private func loadFilterFromDefaults() {
        // Migrate the old single-chip key off so it doesn't linger.
        let oldKey = "notif_filter_\(keypair.pubkey)"
        if UserDefaults.standard.object(forKey: oldKey) != nil {
            UserDefaults.standard.removeObject(forKey: oldKey)
        }
        if let raws = UserDefaults.standard.stringArray(forKey: enabledTypesKey) {
            let decoded = raws.compactMap(NotificationFilter.init(rawValue:))
            enabledTypes = Set(decoded)
        } else {
            enabledTypes = Set(NotificationFilter.allCases)
        }
    }

    // MARK: - Relay set resolution

    private func resolveRelaySets() async {
        // Cached read relays (24h TTL) take priority to avoid blocking on a network round trip.
        let readKey = "notif_read_relays_\(keypair.pubkey)"
        let readTsKey = "notif_read_relays_ts_\(keypair.pubkey)"
        let cacheTs = UserDefaults.standard.integer(forKey: readTsKey)
        let now = Int(Date().timeIntervalSince1970)
        var readRelays: [String] = []
        var writeRelays: [String] = []

        if cacheTs > 0, now - cacheTs < 86400 {
            readRelays = UserDefaults.standard.stringArray(forKey: readKey) ?? []
            writeRelays = UserDefaults.standard.stringArray(forKey: "notif_write_relays_\(keypair.pubkey)") ?? []
        }

        if readRelays.isEmpty {
            let filter = NostrFilter(kinds: [10002], authors: [keypair.pubkey], limit: 1)
            let events = await RelayPool.query(relays: Self.fallbackRelays, filter: filter, timeout: 5)
            if let latest = events.max(by: { $0.createdAt < $1.createdAt }) {
                for tag in latest.tags where tag.first == "r" && tag.count >= 2 {
                    let url = tag[1]
                    let mode = tag.count >= 3 ? tag[2] : ""
                    if mode == "" || mode == "read" { readRelays.append(url) }
                    if mode == "" || mode == "write" { writeRelays.append(url) }
                }
                UserDefaults.standard.set(readRelays, forKey: readKey)
                UserDefaults.standard.set(writeRelays, forKey: "notif_write_relays_\(keypair.pubkey)")
                UserDefaults.standard.set(now, forKey: readTsKey)
            }
        }

        // Top-5 scored relays (already on disk after onboarding).
        let scored = RelayScoreBoard.load(pubkey: keypair.pubkey)?.scoredRelays.prefix(5).map(\.url) ?? []

        let dms = await resolveOwnDmRelays()

        var combined = Set<String>()
        for r in readRelays { combined.insert(r) }
        for r in scored { combined.insert(r) }
        for r in Self.fallbackRelays { combined.insert(r) }

        notifRelays = Array(combined.prefix(10)).sorted()
        ownWriteRelays = writeRelays.isEmpty ? Self.fallbackRelays : writeRelays
        dmRelays = dms
    }

    private func resolveOwnDmRelays() async -> [String] {
        let filter = NostrFilter(kinds: [10050], authors: [keypair.pubkey], limit: 1)
        let events = await RelayPool.query(relays: Self.fallbackRelays, filter: filter, timeout: 4)
        let latest = events.max(by: { $0.createdAt < $1.createdAt })
        return latest?.tags.compactMap { tag -> String? in
            guard tag.count >= 2, tag[0] == "relay" else { return nil }
            return tag[1]
        } ?? []
    }

    // MARK: - Self event ids

    private func refreshSelfEventIds() async {
        // Prefer the user's own write relays (where their own posts actually live), then merge
        // notifRelays + fallbacks for breadth. Never bail out on an empty notifRelays.
        var relays = Set<String>()
        for r in ownWriteRelays { relays.insert(r) }
        for r in notifRelays { relays.insert(r) }
        for r in Self.fallbackRelays { relays.insert(r) }
        let filter = NostrFilter(
            kinds: [1, Nip88.kindPoll, Nip69.kindZapPoll],
            authors: [keypair.pubkey],
            limit: 100
        )
        let events = await RelayPool.query(relays: Array(relays), filter: filter, timeout: 6)
        guard !events.isEmpty else { return }
        // Union with whatever the cache had so we don't shrink the horizon if a relay temporarily
        // returned a partial set.
        var ids = repo.selfEventIds
        for e in events { ids.insert(e.id) }
        // Cap at the most recent 100 by createdAt so the e-tag filter payload stays bounded.
        var ranked = events
        ranked.sort { $0.createdAt > $1.createdAt }
        let top = ranked.prefix(100).map(\.id)
        for id in top { ids.insert(id) }
        if ids.count > 200 {
            // Keep the most recent 100 from this fetch + drop older cached ids.
            ids = Set(top)
        }
        repo.selfEventIds = ids
        repo.persistSelfEventIds()
    }

    private func startSelfIdsRefreshCycle() {
        refreshSelfIdsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if Task.isCancelled { break }
                await self?.refreshSelfEventIds()
            }
        }
    }

    // MARK: - Backfill

    private func backfillRecent() async {
        guard !notifRelays.isEmpty else { return }
        let now = Int(Date().timeIntervalSince1970)
        // Anchor `since` on the newest cached notification (with a 60s overlap to absorb
        // clock skew across relays), falling back to 24h if the cache is empty. Avoids
        // re-pulling events we already have on disk.
        let cachedNewest = await EventStore.shared.newestNotificationTimestamp(
            pubkey: keypair.pubkey,
            selfEventIds: repo.selfEventIds
        ) ?? 0
        let since = cachedNewest > 0 ? max(0, cachedNewest - 60) : (now - 86400)
        let filter = NostrFilter(
            kinds: [1, 6, 7, 9735],
            authors: nil,
            pTags: [keypair.pubkey],
            limit: 300,
            since: since
        )
        async let pTagged: [NostrEvent] = RelayPool.query(relays: notifRelays, filter: filter, timeout: 8)

        // Poll-vote backfill: kind 1018 events e-tagged at any of our recent polls.
        let selfPollIds = Array(repo.selfEventIds.prefix(100))
        let pollVotes: [NostrEvent]
        if !selfPollIds.isEmpty {
            let pollVoteFilter = NostrFilter(
                kinds: [Nip88.kindPollResponse],
                eTags: selfPollIds,
                limit: 200,
                since: since
            )
            pollVotes = await RelayPool.query(relays: notifRelays, filter: pollVoteFilter, timeout: 8)
        } else {
            pollVotes = []
        }

        let events = await pTagged
        for e in events {
            _ = repo.ingest(e, relayUrl: "", isFromDmRelay: false)
            if e.kind == 9735 {
                ZapSender.recordIncomingAttribution(from: e)
            }
        }
        for e in pollVotes {
            _ = repo.ingest(e, relayUrl: "", isFromDmRelay: false)
        }
        await prefetchActorProfilesIfNeeded()
    }

    // MARK: - Live subscriptions

    private func openSubscriptions() {
        guard !notifRelays.isEmpty else { return }
        let pubkey = keypair.pubkey
        let selfIds = Array(repo.selfEventIds.prefix(100))

        let f1 = NostrFilter(kinds: [1, 6, 7, 9735], pTags: [pubkey], limit: 300)
        subNotif = RelayPool.subscribe(relays: notifRelays, filter: f1, id: "notif")
        listenerTasks.append(Task { [weak self] in
            guard let sub = self?.subNotif else { return }
            for await (event, relayUrl) in sub.events {
                guard let self else { break }
                if SafetyFilter.shared.shouldDrop(event: event, context: .notifications) { continue }
                _ = self.repo.ingest(event, relayUrl: relayUrl, isFromDmRelay: false)
                if event.kind == 9735 {
                    ZapSender.recordIncomingAttribution(from: event)
                }
                self.maybePrefetchProfile(for: event.pubkey)
                self.maybeScoreReplyForSpam(event)
            }
        })

        if !selfIds.isEmpty {
            let f2 = NostrFilter(kinds: [1], eTags: selfIds, limit: 200)
            subRepliesEtag = RelayPool.subscribe(relays: notifRelays, filter: f2, id: "notif-replies-etag")
            listenerTasks.append(Task { [weak self] in
                guard let sub = self?.subRepliesEtag else { return }
                for await (event, relayUrl) in sub.events {
                    guard let self else { break }
                    if SafetyFilter.shared.shouldDrop(event: event, context: .notifications) { continue }
                    _ = self.repo.ingest(event, relayUrl: relayUrl, isFromDmRelay: false)
                    self.maybePrefetchProfile(for: event.pubkey)
                    self.maybeScoreReplyForSpam(event)
                }
            })

            let f3 = NostrFilter(kinds: [1], qTags: selfIds, limit: 200)
            subQuotesQtag = RelayPool.subscribe(relays: notifRelays, filter: f3, id: "notif-quotes-qtag")
            listenerTasks.append(Task { [weak self] in
                guard let sub = self?.subQuotesQtag else { return }
                for await (event, relayUrl) in sub.events {
                    guard let self else { break }
                    if SafetyFilter.shared.shouldDrop(event: event, context: .notifications) { continue }
                    _ = self.repo.ingest(event, relayUrl: relayUrl, isFromDmRelay: false)
                    self.maybePrefetchProfile(for: event.pubkey)
                    self.maybeScoreReplyForSpam(event)
                }
            })

            // Kind-1018 poll votes targeting any of our recent polls.
            let f5 = NostrFilter(kinds: [Nip88.kindPollResponse], eTags: selfIds, limit: 200)
            subPollVotes = RelayPool.subscribe(relays: notifRelays, filter: f5, id: "notif-pollvotes-etag")
            listenerTasks.append(Task { [weak self] in
                guard let sub = self?.subPollVotes else { return }
                for await (event, relayUrl) in sub.events {
                    guard let self else { break }
                    if SafetyFilter.shared.shouldDrop(event: event, context: .notifications) { continue }
                    _ = self.repo.ingest(event, relayUrl: relayUrl, isFromDmRelay: false)
                    self.maybePrefetchProfile(for: event.pubkey)
                }
            })
        }

        if !dmRelays.isEmpty {
            let f4 = NostrFilter(kinds: [9735], pTags: [pubkey], limit: 100)
            subDmZaps = RelayPool.subscribe(relays: dmRelays, filter: f4, id: "notif-zaps-dm")
            listenerTasks.append(Task { [weak self] in
                guard let sub = self?.subDmZaps else { return }
                for await (event, relayUrl) in sub.events {
                    guard let self else { break }
                    if SafetyFilter.shared.shouldDrop(event: event, context: .notifications) { continue }
                    _ = self.repo.ingest(event, relayUrl: relayUrl, isFromDmRelay: true)
                    ZapSender.recordIncomingAttribution(from: event)
                }
            })
        }
    }

    private func reopenSubscriptions() {
        for t in listenerTasks { t.cancel() }
        listenerTasks.removeAll()
        subNotif?.cancel(); subNotif = nil
        subRepliesEtag?.cancel(); subRepliesEtag = nil
        subQuotesQtag?.cancel(); subQuotesQtag = nil
        subDmZaps?.cancel(); subDmZaps = nil
        subPollVotes?.cancel(); subPollVotes = nil
        openSubscriptions()
    }

    private func startRearmCycle() {
        rearmTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                if Task.isCancelled { break }
                guard let self else { return }
                let beforeRelays = Set(self.notifRelays)
                let beforeIds = self.repo.selfEventIds
                await self.resolveRelaySets()
                await self.refreshSelfEventIds()
                let relaysChanged = Set(self.notifRelays) != beforeRelays
                let idsChanged = self.repo.selfEventIds != beforeIds
                if relaysChanged || idsChanged {
                    self.reopenSubscriptions()
                }
            }
        }
    }

    // MARK: - DM observation

    /// Listen for blocklist edits so `filteredItems` drops in-memory
    /// notifications from a newly-blocked author without waiting for a
    /// cold relaunch. The ingestion-time `SafetyFilter` check (see
    /// `hydrateFromObjectBox` / `openSubscriptions`) only catches events
    /// arriving *after* the block — anything already in `repo.flatItems`
    /// would otherwise persist until app restart.
    private func startBlocklistObservation() {
        let task = Task { @MainActor [weak self] in
            let events = NotificationCenter.default.notifications(named: .userBlocked)
            for await _ in events {
                self?.safetyGeneration &+= 1
            }
        }
        listenerTasks.append(task)
    }

    private func startDmObservation() {
        dmObserverTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let snapshot = self.dmRepo.conversationList()
                self.projectDms(snapshot)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func projectDms(_ list: [DmConversation]) {
        let lastRead = dmRepo.lastReadTimestamp
        // Drop conversations whose latest message we sent — those aren't notifications.
        let incoming = list.filter { conv in
            (conv.messages.last?.senderPubkey ?? "") != keypair.pubkey
        }
        let items: [FlatNotificationItem] = incoming.map { conv in
            let unread = conv.messages.filter { $0.createdAt > lastRead && $0.senderPubkey != keypair.pubkey }.count
            return FlatNotificationItem(
                id: "dm:\(conv.conversationKey)",
                kind: .dm,
                actorPubkey: conv.peerPubkey,
                referencedEventId: "",
                timestamp: conv.lastMessageAt,
                dmPeerPubkey: conv.peerPubkey,
                dmConversationKey: conv.conversationKey,
                dmUnread: unread
            )
        }
        repo.upsertDms(items)
    }

    // MARK: - NSpam

    /// Score the author of an inbound reply (kind:1 with an `e` tag) and, if the calibrated
    /// probability crosses the threshold, hide every notification by that author. We never run
    /// scoring for safelisted authors, the user's own follows, or the user themselves.
    fileprivate func maybeScoreReplyForSpam(_ event: NostrEvent) {
        guard SafetyPreferences.shared.spamFilterEnabled else { return }
        guard event.kind == 1 else { return }
        // Replies have an `e` tag; root notes don't (NotificationsViewModel only sees pings, so
        // most kind-1s here will be replies/mentions, but check anyway).
        guard event.tags.contains(where: { $0.count >= 2 && $0[0] == "e" }) else { return }
        let author = event.pubkey
        guard author != keypair.pubkey else { return }
        if SafetyPreferences.shared.isSafelisted(author) { return }
        if hiddenSpamPubkeys.contains(author) { return }
        if spamScoringInflight.contains(author) { return }

        // Skip authors the user already follows — they get the benefit of the doubt.
        let follows = FollowsCache.shared.follows(for: keypair.pubkey)
        if follows.contains(author) { return }

        spamScoringInflight.insert(author)
        Task { [weak self, author] in
            guard let self else { return }
            let recent = await EventStore.shared.loadRecentByAuthor(pubkey: author, limit: 5)
            // Always include the just-arrived event so cold-cache authors still get a meaningful
            // signal on their first appearance.
            var pool = recent
            if !pool.contains(where: { $0.id == event.id }) { pool.insert(event, at: 0) }
            let score = await SpamScorer.shared.score(pubkey: author, recentEvents: pool)
            await MainActor.run {
                self.spamScoringInflight.remove(author)
                guard let s = score, s >= SpamScorer.spamThreshold else { return }
                self.hiddenSpamPubkeys.insert(author)
            }
        }
    }

    /// Re-include `pubkey`'s notifications after the user marks them not-spam in the UI.
    func unhideSpamAuthor(_ pubkey: String) {
        hiddenSpamPubkeys.remove(pubkey)
        SafetyPreferences.shared.addToSafelist(pubkey)
        Task { await SpamScorer.shared.invalidate(pubkey: pubkey) }
    }

    // MARK: - Profiles

    private func maybePrefetchProfile(for pubkey: String) {
        if profileRepo.get(pubkey) != nil { return }
        MissingProfileWatcher.shared.observePubkeys([pubkey])
    }

    private func prefetchActorProfilesIfNeeded() async {
        var missing: [String] = []
        for item in repo.flatItems {
            if profileRepo.get(item.actorPubkey) == nil { missing.append(item.actorPubkey) }
        }
        guard !missing.isEmpty else { return }
        MissingProfileWatcher.shared.observePubkeys(missing)
    }

    // MARK: - Quick reply

    /// Sign a kind-1 reply per NIP-10, publish to a best-effort union of own write relays + the
    /// target author's known relays, then optimistically render it under the expanded row.
    func sendQuickReply(targetEvent: NostrEvent, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Int(Date().timeIntervalSince1970)
        let hint = relayHintForTargetAuthor(targetEvent.pubkey)
        var tags: [[String]] = [
            ["e", targetEvent.id, hint, "reply"],
            ["p", targetEvent.pubkey]
        ]
        if let clientTag = NostrEvent.clientTagIfEnabled() { tags.append(clientTag) }
        let signed = try await Signer.sign(
            keypair: keypair,
            kind: 1,
            tags: tags,
            content: trimmed,
            createdAt: now
        )
        var publish = Set<String>()
        for r in ownWriteRelays { publish.insert(r) }
        for r in targetWriteRelays(for: targetEvent.pubkey) { publish.insert(r) }
        if publish.isEmpty { for r in Self.fallbackRelays { publish.insert(r) } }
        repo.addInlineReply(signed, targetEventId: targetEvent.id)
        _ = await RelayPool.publish(event: signed, to: Array(publish))
    }

    private func targetWriteRelays(for pubkey: String) -> [String] {
        if let board = RelayScoreBoard.load(pubkey: keypair.pubkey),
           let set = board.authorRelays[pubkey], !set.isEmpty {
            return Array(set.prefix(3))
        }
        return []
    }

    private func relayHintForTargetAuthor(_ pubkey: String) -> String {
        targetWriteRelays(for: pubkey).first ?? ""
    }
}
