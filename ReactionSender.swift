import Foundation

/// Picked emoji from the reaction picker — either a unicode character or a custom NIP-30 emoji.
enum PickedEmoji: Equatable, Hashable {
    case unicode(String)
    case custom(shortcode: String, url: String)

    /// The frequency-tracker key (also the picker display key): a bare unicode char
    /// for unicode reactions, or `:shortcode:` for custom ones.
    var frequencyKey: String {
        switch self {
        case .unicode(let s): return s
        case .custom(let sc, _): return ":\(sc):"
        }
    }

    /// The kind-7 `content` field for this emoji per NIP-25 + NIP-30.
    var content: String {
        switch self {
        case .unicode(let s): return s
        case .custom(let sc, _): return ":\(sc):"
        }
    }
}

/// Builds, signs, and publishes kind-7 reactions for the feed/thread surfaces.
///
/// Outbox routing follows the Android client: the reaction goes to the **target author's
/// read (inbox) relays** so the author sees it, and to the **reactor's top write relays**
/// so other clients pulling the reactor's outbox can discover it. Optimistic updates flow
/// through `EngagementRepository` so the heart count animates immediately; failures are
/// reverted there.
@MainActor
final class ReactionSender {
    static let shared = ReactionSender()
    private init() {}

    /// `(reactorPubkey, targetEventId, frequencyKey)` already in flight or sent — guards
    /// against double taps. Cleared on logout via `EngagementRepository.shared.clear()`.
    private var sent: Set<String> = []

    enum SendError: Error {
        case missingKey
        case noRelays
        case publishFailed
        case alreadyReacted
    }

    /// Send a reaction. Optimistically updates engagement counts before publish; reverts on failure.
    /// Records frequency only on confirmed publish.
    func react(
        to targetEvent: NostrEvent,
        keypair: Keypair,
        picked: PickedEmoji
    ) async throws {
        let dedupKey = "\(keypair.pubkey)|\(targetEvent.id)|\(picked.frequencyKey)"
        if sent.contains(dedupKey) { throw SendError.alreadyReacted }

        let custom: (shortcode: String, url: String)?
        switch picked {
        case .unicode: custom = nil
        case .custom(let sc, let url): custom = (sc, url)
        }

        let baseTags = Nip25.reactionTags(targetEvent: targetEvent, customEmoji: custom)
        let baseCreatedAt = Int(Date().timeIntervalSince1970)
        let powSnap = PowPreferences.snapshot()
        let signTags: [[String]]
        let signCreatedAt: Int

        // PoW mining: bump nonce until the event id has the requested
        // leading zeroes. Skipped for remote-signer accounts since the
        // signer would mine its own — which most signers don't do, so
        // PoW reactions on a NIP-46 account just publish without PoW.
        if powSnap.reactionEnabled, !keypair.isRemote {
            let pubkey = keypair.pubkey
            let content = picked.content
            let bits = powSnap.reactionDifficulty
            let mined: Nip13.MineResult? = await Task.detached(priority: .userInitiated) {
                Nip13.mine(
                    pubkey: pubkey,
                    kind: Nip25.kindReaction,
                    createdAt: baseCreatedAt,
                    tags: baseTags,
                    content: content,
                    targetBits: bits
                )
            }.value
            guard let mined else { throw SendError.publishFailed }
            signTags = mined.tags
            signCreatedAt = mined.createdAt
        } else {
            signTags = baseTags
            signCreatedAt = baseCreatedAt
        }

        let event: NostrEvent
        do {
            event = try await Signer.sign(
                keypair: keypair,
                kind: Nip25.kindReaction,
                tags: signTags,
                content: picked.content,
                createdAt: signCreatedAt
            )
        } catch {
            throw SendError.missingKey
        }

        let relays = await relaySetForReaction(to: targetEvent, reactor: keypair.pubkey)
        guard !relays.isEmpty else { throw SendError.noRelays }

        // Optimistic UI before publish.
        sent.insert(dedupKey)
        EngagementRepository.shared.applyOptimisticReaction(
            eventId: targetEvent.id,
            reactionEventId: event.id,
            pubkey: keypair.pubkey,
            emoji: picked.content,
            customEmojiUrl: custom?.url
        )

        let succeeded = await RelayPool.publish(event: event, to: relays, timeout: 8)
        if succeeded.isEmpty {
            sent.remove(dedupKey)
            EngagementRepository.shared.revertOptimisticReaction(
                eventId: targetEvent.id,
                pubkey: keypair.pubkey,
                emoji: picked.content
            )
            throw SendError.publishFailed
        }

        EmojiRepository.shared.recordUse(picked.frequencyKey)
    }

    /// Drop the in-memory dedup set on logout.
    func clear() {
        sent.removeAll()
    }

    private func relaySetForReaction(to targetEvent: NostrEvent, reactor: String) async -> [String] {
        var set = Set<String>()
        if let reads = RelayListRepository.shared.cachedReadRelays(targetEvent.pubkey) {
            for relay in reads.prefix(5) { set.insert(relay) }
        } else {
            // Author has no cached relay list; trigger an async lookup but don't block —
            // fall back to top scored relays for this round.
            let reads = await RelayListRepository.shared.getReadRelays(targetEvent.pubkey)
            for relay in reads.prefix(5) { set.insert(relay) }
        }
        if let board = RelayScoreBoard.load(pubkey: reactor) {
            for entry in board.scoredRelays.prefix(3) { set.insert(entry.url) }
        }
        if set.isEmpty {
            set = ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
        }
        return Array(set)
    }
}
