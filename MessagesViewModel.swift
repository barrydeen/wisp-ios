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
        // Read-only dedup across relays (cheap) before attempting decryption (expensive).
        // We do NOT mark the wrap seen here — that happens only after a successful decrypt
        // (`DmRepository.addMessage`), so a transient signer/decrypt failure is retried on
        // the next periodic REQ instead of being silently dropped for the session.
        guard !repo.isGiftWrapSeen(event.id) else { return }

        let rumor: Rumor
        do {
            rumor = try await Nip17.unwrapGiftWrapWithSigner(keypair: keypair, giftWrap: event)
        } catch {
            // Bounded retry: keep the wrap unseen so the next REQ re-delivers it, but give
            // up after a few attempts (and mark it seen) so a permanently-bad wrap doesn't
            // busy-loop. Not persisted — a fresh launch retries.
            let gaveUp = repo.recordDecryptFailure(event.id)
            Self.log.error("DM gift-wrap decrypt failed (gaveUp=\(gaveUp, privacy: .public)) id=\(event.id, privacy: .public) relay=\(relayUrl, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }

        // Chat (kind-14) and file (kind-15) messages are materialized inline since they
        // mutate the per-conversation snapshot. Other rumor kinds — private replies
        // (kind-1) and private reactions (kind-7, incl. DM reactions with k=14) — route
        // through the shared router.
        guard rumor.kind == Nip17.Kind.chatMessage || rumor.kind == Nip17.Kind.fileMessage else {
            await PrivateInteractionRouter.handleRumor(
                rumor: rumor,
                giftWrap: event,
                relayUrl: relayUrl,
                keypair: keypair
            )
            return
        }

        // Safety check on the inner rumor — kind:1059 wrappers are pure transport so we filter
        // on what's actually inside.
        let safetyEvent = NostrEvent(
            id: rumor.id, pubkey: rumor.pubkey, kind: rumor.kind, createdAt: rumor.createdAt,
            tags: rumor.tags, content: rumor.content, sig: ""
        )
        if SafetyFilter.shared.shouldDrop(event: safetyEvent, context: .messages) {
            // Treat as handled so we don't re-decrypt a muted/blocked sender's wrap every REQ.
            _ = repo.markGiftWrapSeen(event.id)
            return
        }

        let participants = Nip17.getConversationParticipants(rumor: rumor, myPubkey: keypair.pubkey)
        let convKey = DmRepository.conversationKey(participants: participants + [keypair.pubkey])
        // Prefer the NIP-10 "reply"-marked e-tag, falling back to the first e-tag.
        let replyTo = rumor.tags.first { $0.count >= 4 && $0[0] == "e" && $0[3] == "reply" }?[1]
            ?? rumor.tags.first { $0.count >= 2 && $0[0] == "e" }?[1]
        // NIP-30 custom-emoji shortcode → URL map carried on the rumor.
        var emojiMap: [String: String] = [:]
        for t in rumor.tags where t.count >= 3 && t[0] == "emoji" { emojiMap[t[1]] = t[2] }
        // Kind-15: parse the encrypted-file metadata; content holds the Blossom URL.
        let fileMeta = rumor.kind == Nip17.Kind.fileMessage
            ? EncryptedMedia.parseKind15Tags(rumor.tags, fileUrl: rumor.content)
            : nil

        let msg = DmMessage(
            id: "\(event.id):\(rumor.createdAt)",
            senderPubkey: rumor.pubkey,
            content: rumor.content,
            createdAt: rumor.createdAt,
            giftWrapId: event.id,
            rumorId: rumor.id,
            replyToId: replyTo,
            participants: participants,
            relayUrls: relayUrl.isEmpty ? [] : [relayUrl],
            emojiMap: emojiMap,
            fileMetadata: fileMeta
        )
        repo.addMessage(msg, conversationKey: convKey)
        refreshSnapshot()
        await prefetchProfilesIfNeeded(participants: participants + [rumor.pubkey])
    }

    func refreshSnapshot() {
        conversations = repo.conversationList()
        hasUnread = repo.hasUnread
    }

    // MARK: - Relay resolution

    /// Build the kind-1059 subscription target set: the user's kind-10050 DM inbox relays,
    /// falling back to their NIP-65 read relays if no DM list is published. We do NOT union
    /// in every general relay — that pins a `kind:1059` stream (no since/limit) open on every
    /// relay, flooding the main actor with duplicate gift wraps and starving the shared
    /// connection pool (one persistent socket per relay, capped). Cold-start completeness
    /// comes from `DmStore` persistence now, not from a wider live fan-out.
    private func resolveDmSubscriptionRelays() async -> [String] {
        // Hydrate from disk (instant) for the case where MessagesViewModel.start runs before
        // RelaySettingsRepository.bootstrap completes its async merge.
        RelaySettingsRepository.shared.ensureLoaded(pubkey: keypair.pubkey)

        let dm = RelaySettingsRepository.shared.dmRelays
        let source = dm.isEmpty
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
