import Foundation

/// Dispatch unwrapped NIP-17 gift wraps by rumor kind to the right downstream
/// surface. Owned by `MessagesViewModel.handleGiftWrap`, which already performs
/// the kind-1059 gift-wrap dedup + `Nip17.unwrapGiftWrapWithSigner` call. The
/// kind-14/15 hot path stays inline in `MessagesViewModel`; this router only
/// handles rumor kinds that aren't conversation messages:
///
/// - kind 1  → private reply (PR #540 / iOS Phase 1)
/// - kind 7  → private reaction (PR #543 / iOS Phase 3 — stubbed here)
///
/// Other kinds drop silently. Unknown rumors aren't an error — DM senders may
/// send experimental rumor kinds and we don't want to crash the gift-wrap
/// pipeline because of one bad inner kind.
@MainActor
enum PrivateInteractionRouter {

    /// Entry point. Called after the gift wrap has been decrypted and the inner
    /// rumor parsed. The router never re-decrypts or re-validates the wrap.
    static func handleRumor(
        rumor: Rumor,
        giftWrap: NostrEvent,
        relayUrl: String,
        keypair: Keypair
    ) async {
        switch rumor.kind {
        case 1:
            await handlePrivateReply(rumor: rumor, relayUrl: relayUrl, keypair: keypair)
        case Nip17.Kind.reaction:
            await handlePrivateReaction(rumor: rumor, relayUrl: relayUrl, keypair: keypair)
        default:
            // Files (kind 15) and any future rumor kinds drop here. DMs go through
            // MessagesViewModel's existing kind-14 path.
            break
        }
    }

    // MARK: - Private reactions

    private static func handlePrivateReaction(rumor: Rumor, relayUrl: String, keypair: Keypair) async {
        // The `k` tag disambiguates reactions targeting kind-1 private replies
        // (k=1) from reactions on kind-14 DM messages (k=14). Anything else
        // drops silently — we only handle private replies in this phase.
        let kTag = rumor.tags.first { $0.count >= 2 && $0[0] == "k" }?[1]
        guard kTag == "1" else { return }

        // Resolve the reaction target — the last `e` tag per NIP-25.
        guard let eTag = rumor.tags.last(where: { $0.count >= 2 && $0[0] == "e" }),
              eTag.count >= 2 else { return }
        let targetId = eTag[1]

        // Parse the emoji/content + optional custom-emoji URL.
        let content = rumor.content
        var customEmojiUrl: String? = nil
        if content.hasPrefix(":"), content.hasSuffix(":") {
            let shortcode = String(content.dropFirst().dropLast())
            if let tag = rumor.tags.first(where: { $0.count >= 3 && $0[0] == "emoji" && $0[1] == shortcode }) {
                customEmojiUrl = tag[2]
            }
        }

        let synthetic = NostrEvent(
            id: rumor.id,
            pubkey: rumor.pubkey,
            kind: Nip17.Kind.reaction,
            createdAt: rumor.createdAt,
            tags: rumor.tags,
            content: rumor.content,
            sig: ""
        )

        // Match `handlePrivateReply`'s block-only check — WoT would otherwise
        // drop every inbound reaction on a fresh-login account (kind-7 isn't
        // WoT-exempt). Private reactions are addressed to specific recipients,
        // not spam.
        if SafetyFilter.shared.snapshot.blockedPubkeys.contains(rumor.pubkey) { return }

        PrivateInteractionStore.shared.markPrivate(rumor.id)
        await EventPersistQueue.shared.enqueue(synthetic)

        // Bump engagement counts via the existing optimistic apply. The
        // triple-key dedup (`target|reactor|emoji`) makes this safe even when
        // the same rumor arrives via the participant-fan-out self-wrap + the
        // recipient-wrap echo, or when the sender already pre-applied locally.
        EngagementRepository.shared.applyOptimisticReaction(
            eventId: targetId,
            pubkey: rumor.pubkey,
            emoji: rumor.content,
            customEmojiUrl: customEmojiUrl
        )

        // Surface in notifications only for inbound — self-fanout echoes
        // shouldn't ping the sender.
        if rumor.pubkey != keypair.pubkey {
            NotificationRepository.shared.ingest(
                synthetic,
                relayUrl: relayUrl,
                isFromDmRelay: true,
                isPrivate: true
            )
        }

        MissingProfileWatcher.shared.observe(synthetic)
    }

    // MARK: - Private replies

    private static func handlePrivateReply(rumor: Rumor, relayUrl: String, keypair: Keypair) async {
        // Materialize the rumor as if it were a public kind-1 — the rest of the
        // app (NotificationRepository, ThreadViewModel, PostCardView) renders
        // private replies through the same code paths as public ones. The lock
        // chip + repost/quote suppression key off `PrivateInteractionStore`
        // membership, not a field on the event.
        let synthetic = NostrEvent(
            id: rumor.id,
            pubkey: rumor.pubkey,
            kind: 1,
            createdAt: rumor.createdAt,
            tags: rumor.tags,
            content: rumor.content,
            sig: ""
        )

        // Only honor the block list — private rumors are addressed to us by a
        // specific sender (who had to know our DM relay set), so they bypass
        // WoT/word/thread-mute the same way kind-14 DMs do. Running the full
        // `SafetyFilter.shouldDrop(.feed)` here drops every private reply when
        // WoT is enabled because kind-1 isn't in `wotExemptKinds` — which
        // would silently swallow fresh-login users' entire DM inbox.
        if SafetyFilter.shared.snapshot.blockedPubkeys.contains(rumor.pubkey) { return }

        // Mark before persisting so the seedCache filter excludes it on the
        // next public-feed reseed. Without this ordering, a backgrounded feed
        // refresh between persist + mark would briefly leak the event.
        PrivateInteractionStore.shared.markPrivate(rumor.id)

        // Persist so the thread renders instantly on cold start without waiting
        // for the kind-1059 subscription to re-stream.
        await EventPersistQueue.shared.enqueue(synthetic)

        // Broadcast so any open ThreadViewModel ingests this rumor as a child
        // of the focal (when the e-tag matches a tracked id). The `isPrivate`
        // flag lets the thread skip its public-reply optimistic path.
        NotificationCenter.default.post(
            name: .nostrEventPublished,
            object: nil,
            userInfo: ["event": synthetic, "isPrivate": true]
        )

        // Surface in notifications — only for inbound (sender != me). The
        // self-wrap (we sent a private reply to ourselves so we see it on
        // every device) doesn't need to ping ourselves.
        if rumor.pubkey != keypair.pubkey {
            NotificationRepository.shared.ingest(
                synthetic,
                relayUrl: relayUrl,
                isFromDmRelay: true,
                isPrivate: true
            )
        }

        // Hydrate the sender's profile so the row resolves to a name instead
        // of a truncated npub.
        MissingProfileWatcher.shared.observe(synthetic)
    }
}
