import Foundation

/// Build + send a private reply: kind-1 rumor wrapped in two kind-1059 gift wraps
/// (one to the parent author, one to self) and routed through both sides'
/// kind-10050 DM relays. No public kind-1 is ever published. The returned
/// synthetic `NostrEvent` carries the rumor id + tags so the caller can use it
/// as the optimistic UI seed.
///
/// Mirrors Android `PrivateReplyPublisher.kt` (PR #540) — same recipient set
/// (parent author + self), same shared rumor id across wraps so the parent's
/// reply can route back to a known event on the sender's device.
@MainActor
enum PrivateReplyPublisher {
    enum SendError: Swift.Error {
        /// Recipient has no kind-10050 inbox and no NIP-65 read relays. We
        /// refuse to fall back to public infrastructure — the user opted in
        /// to private, and silently leaking the wrap to a default relay would
        /// violate that expectation.
        case noRecipientRelays
        /// Caller has no kind-10050 DM relays of their own to publish the
        /// self-copy to. The self-copy is what lets the sender's other devices
        /// (or a reinstall) see what they sent privately.
        case noOwnRelays
        case wrapFailed(Swift.Error)
        /// All relays rejected or timed out on both the recipient wrap and
        /// the self-copy. Carries the relay counts for diagnostic messaging.
        case publishFailed(recipientTried: Int, ownTried: Int)
    }

    /// Send a private reply to `parent`. `extraTags` should include any inline
    /// mentions (`["p", pubkey]`), hashtags, and the client tag — *not* the
    /// canonical NIP-10 e/p reply tags, which this function builds itself.
    /// Returns the synthesized rumor event the caller persists locally.
    @discardableResult
    static func send(
        keypair: Keypair,
        parent: NostrEvent,
        root: NostrEvent? = nil,
        content: String,
        extraTags: [[String]] = []
    ) async throws -> NostrEvent {
        // 1. Resolve recipient's relays first — fail fast if there's no path
        //    before we burn CPU on encrypt + PoW. The hierarchy is kind-10050 →
        //    kind-10002 inbox → fail; no fallback to write relays.
        let recipientRelays = await PeerRelayResolver.resolveDmTargets(pubkey: parent.pubkey)
        guard !recipientRelays.isEmpty else { throw SendError.noRecipientRelays }

        // 2. Own relays for the self-copy. Prefer kind-10050 (NIP-17 DM relays);
        //    fall back to the user's NIP-65 write relays + top scored relays if
        //    no DM relays are configured. The fallback is a soft privacy
        //    trade-off (anyone subscribed to the user's outbox sees they sent
        //    a kind-1059 event) but matches Android's behavior so first-run
        //    users without an explicit kind-10050 list can still send private
        //    replies. The wrap content is still encrypted; only the existence
        //    of the kind-1059 is visible.
        RelaySettingsRepository.shared.ensureLoaded(pubkey: keypair.pubkey)
        var ownRelays = RelaySettingsRepository.shared.dmRelays
        if ownRelays.isEmpty {
            ownRelays = await RelayListRepository.shared.getWriteRelays(keypair.pubkey)
            if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
                for entry in board.scoredRelays.prefix(5) {
                    if !ownRelays.contains(entry.url) { ownRelays.append(entry.url) }
                }
            }
        }
        guard !ownRelays.isEmpty else { throw SendError.noOwnRelays }

        // 3. Pin `created_at` for the rumor so both wraps decrypt to the same
        //    rumor id — the parent author's reply can then e-tag what *we*
        //    have locally, keeping the private chain coherent across devices.
        let rumorCreatedAt = Int(Date().timeIntervalSince1970)

        // 4. Build canonical reply tags via NIP-10. These already include
        //    `["p", parent.pubkey]` plus every p-tag carried up from the parent.
        var tags = Nip10.buildReplyTags(replyTo: parent, relayHint: "")
        for tag in extraTags {
            if !tags.contains(where: { $0 == tag }) {
                tags.append(tag)
            }
        }

        // 5. Build the shared rumor once. `buildRumorRaw` skips the auto-prepended
        //    `["p", recipientPubkey]` so the tag order is exactly the canonical
        //    reply set — no duplicate p-tags, no per-recipient drift.
        let rumor = Nip17.buildRumorRaw(
            senderPubkey: keypair.pubkey,
            kind: 1,
            tags: tags,
            content: content,
            createdAt: rumorCreatedAt
        )

        // 6. Wrap once per recipient. Same rumor → same rumor id on every
        //    decryption. Each wrap is encrypted with its own ephemeral key
        //    and targets one specific recipient's pubkey on the outer envelope.
        let recipientWrap: NostrEvent
        let selfWrap: NostrEvent
        do {
            recipientWrap = try await Nip17.wrapRumorWithSigner(
                keypair: keypair,
                recipientPubkey: parent.pubkey,
                rumor: rumor
            )
            selfWrap = try await Nip17.wrapRumorWithSigner(
                keypair: keypair,
                recipientPubkey: keypair.pubkey,
                rumor: rumor
            )
        } catch {
            throw SendError.wrapFailed(error)
        }

        // 7. Publish in parallel — recipient wrap to recipient relays, self-copy
        //    to own relays. We require *some* successful publish, not all four
        //    of (recipient_relay_count * 2) — a single accepted wrap is enough
        //    for the rumor to propagate via relay-to-relay replication.
        async let acceptedRecipient = RelayPool.publish(event: recipientWrap, to: recipientRelays, timeout: 8)
        async let acceptedSelf = RelayPool.publish(event: selfWrap, to: ownRelays, timeout: 8)
        let (recipientAccepted, selfAccepted) = await (acceptedRecipient, acceptedSelf)
        guard !recipientAccepted.isEmpty || !selfAccepted.isEmpty else {
            throw SendError.publishFailed(recipientTried: recipientRelays.count, ownTried: ownRelays.count)
        }

        // 8. Synthesize a NostrEvent for the local UI. Sig is empty — this is
        //    a rumor, not a signed event. The id matches what every recipient
        //    sees on decrypt.
        let synthetic = NostrEvent(
            id: rumor.id,
            pubkey: rumor.pubkey,
            kind: 1,
            createdAt: rumor.createdAt,
            tags: rumor.tags,
            content: rumor.content,
            sig: ""
        )

        // 9. Mark private + persist + broadcast for any open thread observers.
        //    Order: mark first so EventStore.seedCache excludes the synthetic on
        //    a concurrent feed refresh.
        PrivateInteractionStore.shared.markPrivate(rumor.id)
        await EventPersistQueue.shared.enqueue(synthetic)
        // Pre-seed the gift-wrap dedup so the relay echo of our self-wrap (which
        // we'll receive back through MessagesViewModel's kind-1059 subscription)
        // doesn't double-ingest the same rumor. Both wraps go into the dedup —
        // the recipient wrap can echo back too if relays cross-replicate.
        _ = DmRepository.shared.markGiftWrapSeen(recipientWrap.id)
        _ = DmRepository.shared.markGiftWrapSeen(selfWrap.id)
        // Register this rumor id as one of the active user's own events so
        // inbound notification classification (`classifyZap`,
        // `classifyReaction`, `classifyKind1` for reply detection) accepts
        // events whose e-tag points back at it. Private rumors never appear
        // in the relay-query path that normally populates `selfEventIds`
        // (their author/kind/sig signature isn't a real signed kind-1 on
        // any relay), so this is the only way the user ever sees zaps,
        // reactions, or sub-replies on a private reply they sent.
        NotificationRepository.shared.selfEventIds.insert(rumor.id)
        NotificationRepository.shared.persistSelfEventIds()
        NotificationCenter.default.post(
            name: .nostrEventPublished,
            object: nil,
            userInfo: ["event": synthetic, "isPrivate": true]
        )

        return synthetic
    }
}
