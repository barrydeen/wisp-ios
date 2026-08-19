import Foundation

/// Builds, signs, and publishes kind-6 reposts (NIP-18).
///
/// A "naked" repost is a kind-6 event whose `content` is the JSON of the original event
/// (so clients without inline lookup can still render it) plus `["e", id, relayHint]` and
/// `["p", authorPubkey]` tags. Quote-reposts go through `ComposeView` with `.quote(event)`
/// instead — that path produces a kind-1 with a `q` tag.
///
/// Outbox routing mirrors `ReactionSender`: publish to the target author's read relays
/// (so the author sees the boost) and the reposter's top write relays (so others pulling
/// the reposter's outbox discover it).
@MainActor
final class RepostSender {
    static let shared = RepostSender()
    private init() {}

    private var sent: Set<String> = []

    enum SendError: Error {
        case missingKey
        case noRelays
        case publishFailed
        case alreadyReposted
    }

    /// Publish a kind-6 repost of `targetEvent`. Idempotent per `(reposter, targetId)`.
    // TODO: reposts of non-kind-1 events should be kind 16, not kind 6.
    // NIP-18 scopes kind 6 to kind-1 text notes and defines kind 16 (generic
    // repost) for everything else, carrying the original's kind in a `k` tag.
    // We already emit that `k` tag but always sign as kind 6, so a repost of a
    // kind-1111 comment (or a 30023 article, a kind-20 picture…) is
    // technically malformed. Clients that filter kind 6 expecting kind-1
    // content may drop it or render it wrong; ones that ignore kind 16
    // entirely won't see it at all. Worth surveying what other clients do
    // with each before changing, since switching kinds changes who sees the
    // repost — a behavioral change, not just a correctness fix.
    func repost(_ targetEvent: NostrEvent, keypair: Keypair) async throws {
        let dedupKey = "\(keypair.pubkey)|\(targetEvent.id)"
        if sent.contains(dedupKey) { throw SendError.alreadyReposted }

        let relayHint = NoteSourceTracker.shared.relays(for: targetEvent.id).first ?? ""
        var tags: [[String]] = [
            ["e", targetEvent.id, relayHint],
            ["p", targetEvent.pubkey],
            ["k", String(targetEvent.kind)]
        ]
        if let clientTag = NostrEvent.clientTagIfEnabled() {
            tags.append(clientTag)
        }

        let event: NostrEvent
        do {
            event = try await Signer.sign(
                keypair: keypair,
                kind: 6,
                tags: tags,
                content: targetEvent.toJSON()
            )
        } catch {
            throw SendError.missingKey
        }

        let relays = await relaySetForRepost(of: targetEvent, reposter: keypair.pubkey)
        guard !relays.isEmpty else { throw SendError.noRelays }

        sent.insert(dedupKey)
        EngagementRepository.shared.applyOptimisticRepost(
            eventId: targetEvent.id,
            repostEventId: event.id,
            reposterPubkey: keypair.pubkey
        )

        let succeeded = await RelayPool.publish(event: event, to: relays, timeout: 8)
        if succeeded.isEmpty {
            sent.remove(dedupKey)
            EngagementRepository.shared.revertOptimisticRepost(
                eventId: targetEvent.id,
                reposterPubkey: keypair.pubkey
            )
            throw SendError.publishFailed
        }
    }

    func clear() { sent.removeAll() }

    /// Remove a specific entry from the dedup set so the user can repost again after undoing.
    func clearSent(pubkey: String, targetEventId: String) {
        sent.remove("\(pubkey)|\(targetEventId)")
    }

    private func relaySetForRepost(of targetEvent: NostrEvent, reposter: String) async -> [String] {
        var set = Set<String>()
        if let reads = RelayListRepository.shared.cachedReadRelays(targetEvent.pubkey) {
            for relay in reads.prefix(5) { set.insert(relay) }
        } else {
            let reads = await RelayListRepository.shared.getReadRelays(targetEvent.pubkey)
            for relay in reads.prefix(5) { set.insert(relay) }
        }
        if let board = RelayScoreBoard.load(pubkey: reposter) {
            for entry in board.scoredRelays.prefix(3) { set.insert(entry.url) }
        }
        if set.isEmpty {
            set = ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
        }
        return Array(set)
    }
}
