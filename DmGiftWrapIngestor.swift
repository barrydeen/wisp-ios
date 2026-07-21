import Foundation
import os

/// Outcome of a successful chat/file ingest — enough for the caller to refresh
/// its snapshot and prefetch the relevant profiles.
struct DmIngestResult {
    let conversationKey: String
    /// Conversation participants excluding the local user (from the rumor's p-tags).
    let participants: [String]
    /// The rumor author (real sender).
    let senderPubkey: String
}

/// Shared decrypt + materialize path for incoming NIP-17 gift wraps (kind 1059).
///
/// Used by BOTH the global DM subscription (`MessagesViewModel`) and the
/// per-conversation scoped subscription (`DmConversationViewModel`), so the
/// dedup / decrypt-retry / safety-filter / routing / materialization ordering
/// lives in exactly one place. `DmRepository`'s `seenGiftWraps` set + composite-id
/// merge make overlapping delivery across the two subscriptions idempotent, so it
/// is safe for both to feed this with the same wraps.
@MainActor
enum DmGiftWrapIngestor {
    static let log = Logger(subsystem: "wisp", category: "dm")

    /// Decrypt and ingest one gift wrap. Returns a `DmIngestResult` only when a
    /// chat/file message was materialized into the repository (so the caller can
    /// refresh that snapshot); returns `nil` when the wrap was a duplicate, a
    /// non-chat rumor (routed through `PrivateInteractionRouter`), dropped by the
    /// safety filter, or failed to decrypt.
    @discardableResult
    static func ingest(event: NostrEvent, relayUrl: String, keypair: Keypair) async -> DmIngestResult? {
        let repo = DmRepository.shared
        guard event.kind == Nip17.Kind.giftWrap else { return nil }
        // Read-only dedup across relays (cheap) before attempting decryption (expensive).
        // We do NOT mark the wrap seen here — that happens only after a successful decrypt
        // (`DmRepository.addMessage`), so a transient signer/decrypt failure is retried on
        // the next periodic REQ instead of being silently dropped for the session.
        guard !repo.isGiftWrapSeen(event.id) else { return nil }

        let rumor: Rumor
        do {
            rumor = try await Nip17.unwrapGiftWrapWithSigner(keypair: keypair, giftWrap: event)
        } catch {
            // Bounded retry: keep the wrap unseen so the next REQ re-delivers it, but give
            // up after a few attempts (and mark it seen) so a permanently-bad wrap doesn't
            // busy-loop. Not persisted — a fresh launch retries.
            let gaveUp = repo.recordDecryptFailure(event.id)
            log.error("DM gift-wrap decrypt failed (gaveUp=\(gaveUp, privacy: .public)) id=\(event.id, privacy: .public) relay=\(relayUrl, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
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
            return nil
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
            return nil
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
            // The composite id keeps the UNCLAMPED rumor timestamp — it must match the
            // sender-side reconcile id (DmConversationViewModel.deliver) or the self-echo
            // dedup breaks. Only the sort/display field below is clamped.
            id: "\(event.id):\(rumor.createdAt)",
            senderPubkey: rumor.pubkey,
            content: rumor.content,
            // Clamp so a sender with a fast clock can't pin their message below
            // every subsequent (correctly-stamped) reply.
            createdAt: NostrClock.clampIncoming(rumor.createdAt),
            giftWrapId: event.id,
            rumorId: rumor.id,
            replyToId: replyTo,
            participants: participants,
            relayUrls: relayUrl.isEmpty ? [] : [relayUrl],
            emojiMap: emojiMap,
            fileMetadata: fileMeta
        )
        repo.addMessage(msg, conversationKey: convKey)
        return DmIngestResult(conversationKey: convKey, participants: participants, senderPubkey: rumor.pubkey)
    }
}
