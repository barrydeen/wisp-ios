import Foundation

/// Publishes a NIP-09 kind-5 deletion request for an event the active user authored.
///
/// Deletion requests are advisory — relays and other clients MAY honor them but are not
/// required to. Publish goes to both the user's write relays (so anyone pulling their
/// outbox sees the deletion) and any relays we've actually seen the original event on
/// (so those relays can drop their copy).
@MainActor
final class DeletionSender {
    static let shared = DeletionSender()
    private init() {}

    enum SendError: Error {
        case missingKey
        case notAuthor
        case noRelays
        case publishFailed
    }

    /// Publish a kind-5 referencing `targetEvent.id`. The caller MUST verify `targetEvent.pubkey
    /// == keypair.pubkey` at the UI layer; this method also enforces it defensively.
    func delete(_ targetEvent: NostrEvent, keypair: Keypair, reason: String = "") async throws {
        guard targetEvent.pubkey == keypair.pubkey else { throw SendError.notAuthor }

        var tags = Nip09.deletionTagsForEvent(id: targetEvent.id, kind: targetEvent.kind)
        if let clientTag = NostrEvent.clientTagIfEnabled() {
            tags.append(clientTag)
        }

        let event: NostrEvent
        do {
            event = try await Signer.sign(
                keypair: keypair,
                kind: Nip09.kindDeletion,
                tags: tags,
                content: reason
            )
        } catch {
            throw SendError.missingKey
        }

        var set = Set<String>()
        let writes = await RelayListRepository.shared.getWriteRelays(keypair.pubkey)
        for r in writes { set.insert(r) }
        for r in NoteSourceTracker.shared.relays(for: targetEvent.id) { set.insert(r) }
        if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
            for entry in board.scoredRelays.prefix(3) { set.insert(entry.url) }
        }
        if set.isEmpty {
            set = ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
        }

        let succeeded = await RelayPool.publish(event: event, to: Array(set), timeout: 8)
        if succeeded.isEmpty { throw SendError.publishFailed }
    }
}
