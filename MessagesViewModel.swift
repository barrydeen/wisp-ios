import Foundation
import Observation

@Observable
@MainActor
final class MessagesViewModel {
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
        isLoading = true

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
        let priv = privkeyData()

        listenerTask = Task { [weak self] in
            for await (event, relayUrl) in sub.events {
                guard let self else { break }
                await self.handleGiftWrap(event: event, relayUrl: relayUrl, privkey: priv)
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

    private func handleGiftWrap(event: NostrEvent, relayUrl: String, privkey: Data) async {
        guard event.kind == Nip17.Kind.giftWrap else { return }
        // Dedupe across relays first (cheap) before attempting decryption (expensive).
        guard repo.markGiftWrapSeen(event.id) else {
            // Already processed: still merge relayUrl into the existing message if present.
            mergeRelayUrl(giftWrapId: event.id, relayUrl: relayUrl)
            return
        }

        // Route both NIP-44 decrypts through `Signer` so remote (NIP-46) accounts can
        // peel the gift wrap + seal layers via their signer. `privkey` is unused for
        // remote accounts (Signer dispatches to `Nip46Manager.activeClient`); for local
        // accounts Signer falls back to in-process `Nip44.decrypt` with the keypair's
        // privkey, which is functionally identical to the previous direct call.
        let rumor: Rumor
        do {
            rumor = try await Nip17.unwrapGiftWrapWithSigner(keypair: keypair, giftWrap: event)
        } catch {
            return
        }

        // v1 scope: chat messages only. Reactions/files arrive as different rumor kinds and are
        // dropped silently for now.
        guard rumor.kind == Nip17.Kind.chatMessage else { return }

        // Safety check on the inner rumor — kind:1059 wrappers are pure transport so we filter
        // on what's actually inside.
        let safetyEvent = NostrEvent(
            id: rumor.id, pubkey: rumor.pubkey, kind: rumor.kind, createdAt: rumor.createdAt,
            tags: rumor.tags, content: rumor.content, sig: ""
        )
        if SafetyFilter.shared.shouldDrop(event: safetyEvent, context: .messages) { return }

        let participants = Nip17.getConversationParticipants(rumor: rumor, myPubkey: keypair.pubkey)
        let convKey = DmRepository.conversationKey(participants: participants + [keypair.pubkey])
        let replyTo = rumor.tags.first { $0.count >= 2 && $0[0] == "e" }?[1]

        let msg = DmMessage(
            id: "\(event.id):\(rumor.createdAt)",
            senderPubkey: rumor.pubkey,
            content: rumor.content,
            createdAt: rumor.createdAt,
            giftWrapId: event.id,
            rumorId: rumor.id,
            replyToId: replyTo,
            participants: participants,
            relayUrls: relayUrl.isEmpty ? [] : [relayUrl]
        )
        repo.addMessage(msg, conversationKey: convKey)
        refreshSnapshot()
        await prefetchProfilesIfNeeded(participants: participants + [rumor.pubkey])
    }

    private func mergeRelayUrl(giftWrapId: String, relayUrl: String) {
        // Best-effort merge for already-seen messages. Cheap path; only need conversation lookup.
        for (key, msgs) in repo.conversations {
            if let i = msgs.firstIndex(where: { $0.giftWrapId == giftWrapId }) {
                var msg = msgs[i]
                msg.relayUrls.insert(relayUrl)
                repo.addMessage(msg, conversationKey: key)
                return
            }
        }
    }

    func refreshSnapshot() {
        conversations = repo.conversationList()
        hasUnread = repo.hasUnread
    }

    // MARK: - Relay resolution

    /// Build the kind-1059 subscription target set. Use the user's kind-10050 DM inbox
    /// relays if they have any, otherwise fall back to their NIP-65 inbox (read) relays.
    /// We never apply hardcoded defaults and we never include NIP-65 write relays —
    /// senders publish gift wraps to the recipient's *inbox*, not to the recipient's
    /// outbox. Sourcing from the user's own published lists only.
    private func resolveDmSubscriptionRelays() async -> [String] {
        // Hydrate from disk (instant) for the case where MessagesViewModel.start runs before
        // RelaySettingsRepository.bootstrap completes its async merge.
        RelaySettingsRepository.shared.ensureLoaded(pubkey: keypair.pubkey)

        let dm = RelaySettingsRepository.shared.dmRelays
        let source: [String] = dm.isEmpty
            ? await RelayListRepository.shared.getReadRelays(keypair.pubkey)
            : dm

        var seen = Set<String>()
        var canonical: [String] = []
        for url in source {
            guard let n = RelayUrlValidator.canonicalize(url) else { continue }
            if seen.insert(n).inserted { canonical.append(n) }
        }
        return canonical
    }

    func privkeyData() -> Data {
        Hex.decode(keypair.privkey) ?? Data()
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
