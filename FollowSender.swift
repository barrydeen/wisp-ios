import Foundation

/// Builds, signs, and publishes kind-3 (NIP-02 contact list) updates.
///
/// The follow set is materialized in `UserDefaults` under `follow_pubkeys_<pubkey>`
/// — that's the canonical local source of truth that the feed, notifications,
/// and mention-search all read. `follow(_:)` and `unfollow(_:)` mutate that
/// set, then republish a fresh kind-3 to the user's write relays + indexers
/// so other clients pick it up. Follow / unfollow always carry the user's own
/// pubkey in the set, mirroring `SignUpViewModel.finishFollowsStep`.
@MainActor
final class FollowSender {
    static let shared = FollowSender()
    private init() {}

    enum SendError: Error {
        case missingKey
        case noRelays
        case publishFailed
    }

    private static let indexerRelays = RelayDefaults.indexers

    /// Add `pubkey` to the active user's contact list. No-op if already followed.
    func follow(_ pubkey: String, keypair: Keypair) async throws {
        var current = currentFollows(for: keypair.pubkey)
        guard current.insert(pubkey).inserted else { return }
        try await publish(follows: current, keypair: keypair)
    }

    /// Remove `pubkey` from the active user's contact list. No-op if not present.
    func unfollow(_ pubkey: String, keypair: Keypair) async throws {
        var current = currentFollows(for: keypair.pubkey)
        guard current.remove(pubkey) != nil else { return }
        try await publish(follows: current, keypair: keypair)
    }

    /// Republish a recovered contact list verbatim and make it the local
    /// source of truth. Unlike `follow`/`unfollow` this preserves the
    /// recovered ordering instead of round-tripping through a `Set`, so a
    /// restored list reads the same as the original.
    func restore(follows: [String], keypair: Keypair) async throws {
        var seen = Set<String>()
        var ordered: [String] = []
        for pk in follows where !pk.isEmpty && seen.insert(pk).inserted {
            ordered.append(pk)
        }
        if seen.insert(keypair.pubkey).inserted { ordered.append(keypair.pubkey) }

        var tags: [[String]] = ordered.map { ["p", $0] }
        if let clientTag = NostrEvent.clientTagIfEnabled() {
            tags.append(clientTag)
        }

        let event = try await Signer.sign(
            keypair: keypair,
            kind: 3,
            tags: tags,
            content: ""
        )

        let relays = await publishRelays(for: keypair.pubkey)
        guard !relays.isEmpty else { throw SendError.noRelays }

        FollowsCache.shared.update(pubkey: keypair.pubkey, follows: ordered)
        await EventStore.shared.persist([event])

        let succeeded = await RelayPool.publish(event: event, to: relays, timeout: 8)
        if succeeded.isEmpty {
            throw SendError.publishFailed
        }
    }

    private func currentFollows(for pubkey: String) -> Set<String> {
        FollowsCache.shared.followsSet(for: pubkey)
    }

    private func publish(follows: Set<String>, keypair: Keypair) async throws {
        // Always include self — matches Android + Wisp's onboarding behavior.
        var withSelf = follows
        withSelf.insert(keypair.pubkey)

        var tags: [[String]] = withSelf.map { ["p", $0] }
        if let clientTag = NostrEvent.clientTagIfEnabled() {
            tags.append(clientTag)
        }

        // Route through `Signer.sign` so NIP-46 remote-signer accounts work —
        // the old direct call to `NostrEvent.sign(privkey32:)` required a
        // local private key and threw `missingKey` for every bunker user.
        let event = try await Signer.sign(
            keypair: keypair,
            kind: 3,
            tags: tags,
            content: ""
        )

        let relays = await publishRelays(for: keypair.pubkey)
        guard !relays.isEmpty else { throw SendError.noRelays }

        // Save the new set locally up front so the UI reflects the change
        // immediately even if the relay round-trip takes a moment.
        FollowsCache.shared.update(pubkey: keypair.pubkey, follows: Array(follows))
        await EventStore.shared.persist([event])

        let succeeded = await RelayPool.publish(event: event, to: relays, timeout: 8)
        if succeeded.isEmpty {
            throw SendError.publishFailed
        }
    }

    private func publishRelays(for pubkey: String) async -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        let writes = await RelayListRepository.shared.getWriteRelays(pubkey)
        for url in writes where seen.insert(url).inserted { ordered.append(url) }
        if let board = RelayScoreBoard.load(pubkey: pubkey) {
            for entry in board.scoredRelays.prefix(5) where seen.insert(entry.url).inserted {
                ordered.append(entry.url)
            }
        }
        for url in Self.indexerRelays where seen.insert(url).inserted { ordered.append(url) }
        return ordered
    }
}
