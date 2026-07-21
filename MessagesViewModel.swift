import Foundation
import Observation
import os

@Observable
@MainActor
final class MessagesViewModel {
    static let log = Logger(subsystem: "wisp", category: "dm")

    let keypair: Keypair

    var conversations: [DmConversation] = []
    var hasUnread: Bool = false
    var isLoading: Bool = false

    @ObservationIgnored private var subscription: RelaySubscription?
    @ObservationIgnored private var listenerTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let repo = DmRepository.shared
    @ObservationIgnored private let profileRepo = ProfileRepository.shared

    /// How often to re-issue the gift-wrap REQ on every live socket. Mirrors Android
    /// (StartupCoordinator.subscribeDmsAndNotifications). Relays can silently drop
    /// server-side subscriptions while the WebSocket stays alive — periodic re-issue
    /// re-arms them and pulls anything that landed since.
    private static let refreshIntervalSeconds: UInt64 = 180

    init(keypair: Keypair) {
        self.keypair = keypair
    }

    func start() async {
        guard subscription == nil else { return }
        repo.bind(activePubkey: keypair.pubkey)
        PrivateInteractionStore.shared.bind(activePubkey: keypair.pubkey)
        isLoading = true

        // Hydrate persisted conversations from disk before the first snapshot so DMs
        // show on cold start even before (or without) any live relay traffic.
        await repo.hydrateIfNeeded()
        refreshSnapshot()

        // 1. Resolve the DM subscription relay set: kind-10050 DM relays unioned with the
        //    user's NIP-65 read+write relays. No hardcoded defaults — every URL here came
        //    from the user's own published relay lists.
        let relays = await resolveDmSubscriptionRelays()

        // 2. Open persistent subscription. NO `since`, no `limit`, no `until` — wraps have
        //    randomized timestamps (NIP-17 spec allows up to 2 days in the past), so any
        //    time-window cursor mis-counts history. The unbounded REQ tells each relay
        //    "give me everything you have for kind:1059 #p:me", which is the only correct
        //    way to fetch DM history. Mirrors Android's `subscribeDmsAndNotifications`.
        let filter = NostrFilter(kinds: [Nip17.Kind.giftWrap], pTags: [keypair.pubkey])
        let sub = RelayPool.subscribe(relays: relays, filter: filter, id: "dms")
        subscription = sub

        listenerTask = Task { [weak self] in
            for await (event, relayUrl) in sub.events {
                guard let self else { break }
                await self.handleGiftWrap(event: event, relayUrl: relayUrl)
            }
        }

        // 3. Re-issue the REQ on every live socket every 3 minutes. Some relays silently
        //    drop subscriptions server-side while the WebSocket stays open; without a
        //    periodic poke they go dark. DmRepository.markGiftWrapSeen dedupes any
        //    duplicate frames produced by the refresh.
        refreshTask = Task { [weak sub] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.refreshIntervalSeconds * 1_000_000_000)
                if Task.isCancelled { break }
                await sub?.resendREQ()
            }
        }

        refreshSnapshot()
        isLoading = false
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        listenerTask?.cancel()
        listenerTask = nil
        subscription?.cancel()
        subscription = nil
    }

    func markAllRead() {
        repo.markAllRead()
        hasUnread = false
    }

    /// Thin wrapper over the shared `DmGiftWrapIngestor` (which also feeds the
    /// per-conversation scoped subscription). Decrypt/dedup/safety/routing live in
    /// the ingestor; the view model only owns the snapshot refresh + profile prefetch.
    private func handleGiftWrap(event: NostrEvent, relayUrl: String) async {
        guard let result = await DmGiftWrapIngestor.ingest(event: event, relayUrl: relayUrl, keypair: keypair)
        else { return }
        refreshSnapshot()
        await prefetchProfilesIfNeeded(participants: result.participants + [result.senderPubkey])
    }

    func refreshSnapshot() {
        conversations = repo.conversationList()
        hasUnread = repo.hasUnread
    }

    // MARK: - Relay resolution

    /// Build the kind-1059 subscription target set: the UNION of the user's own
    /// kind-10050 DM inbox relays AND their NIP-65 read relays. Both are the user's
    /// OWN published lists (bounded, small) — unioning them means we catch copies a
    /// sender deposited in our NIP-65 inbox (because they couldn't find our kind-10050)
    /// even when we DO publish a kind-10050. We still do NOT union in every general
    /// relay — that pins a `kind:1059` stream (no since/limit) open on every relay,
    /// flooding the main actor with duplicate gift wraps and starving the shared
    /// connection pool (one persistent socket per relay, capped). Broader per-conversation
    /// coverage comes from the temporary scoped subscription in `DmConversationViewModel`.
    private func resolveDmSubscriptionRelays() async -> [String] {
        // Hydrate from disk (instant) for the case where MessagesViewModel.start runs before
        // RelaySettingsRepository.bootstrap completes its async merge.
        RelaySettingsRepository.shared.ensureLoaded(pubkey: keypair.pubkey)

        let dm = RelaySettingsRepository.shared.dmRelays
        let read = await RelayListRepository.shared.getReadRelays(keypair.pubkey)

        var seen = Set<String>()
        var canonical: [String] = []
        for url in dm + read {
            guard let n = RelayUrlValidator.canonicalize(url) else { continue }
            if seen.insert(n).inserted { canonical.append(n) }
        }
        return canonical
    }

    private func prefetchProfilesIfNeeded(participants: [String]) async {
        let missing = participants.filter { profileRepo.get($0) == nil }
        guard !missing.isEmpty else { return }
        let filter = NostrFilter(kinds: [0], authors: missing, limit: missing.count)
        let events = await RelayPool.query(
            relays: RelaySettingsRepository.indexerRelays, filter: filter, timeout: 5
        )
        for e in events { profileRepo.updateFromEvent(e) }
    }
}
