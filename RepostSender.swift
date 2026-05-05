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
