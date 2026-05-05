import Foundation

/// Add or remove an event id from the user's NIP-51 kind-10001 pinned-notes list.
///
/// Replaceable lists are read-modify-write: fetch the latest copy from the user's write
/// relays, mutate the `e` tags, sign, and publish back. Only the active user can pin
/// their own notes (kind 10001 is keyed to the author).
@MainActor
final class PinNoteSender {
    static let shared = PinNoteSender()
    private init() {}

    enum SendError: Error {
        case missingKey
        case noRelays
        case publishFailed
    }

    /// Pin or unpin `noteId` (a hex event id) in the active user's kind-10001 list.
    /// Returns the new full list of pinned ids after the publish.
    @discardableResult
    func setPinned(noteId: String, pinned: Bool, keypair: Keypair) async throws -> [String] {
        let writeRelays = await RelayListRepository.shared.getWriteRelays(keypair.pubkey)
        let readRelays = await RelayListRepository.shared.getReadRelays(keypair.pubkey)
        var fetchSet = Set(writeRelays)
        for r in readRelays { fetchSet.insert(r) }
        if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
            for entry in board.scoredRelays.prefix(5) { fetchSet.insert(entry.url) }
        }
        if fetchSet.isEmpty {
            fetchSet = ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
        }

        let filter = NostrFilter(kinds: [Nip10001.kindPinned], authors: [keypair.pubkey], limit: 1)
        let existing = await RelayPool.query(relays: Array(fetchSet), filter: filter, timeout: 6)
        let latest = existing.max(by: { $0.createdAt < $1.createdAt })
        var ids: [String] = latest.map(Nip10001.pinnedIds(from:)) ?? []

        if pinned {
            ids.removeAll { $0 == noteId }
            ids.insert(noteId, at: 0)
        } else {
            ids.removeAll { $0 == noteId }
        }

        var tags = Nip10001.buildTags(pinnedIds: ids)
        if let clientTag = NostrEvent.clientTagIfEnabled() {
            tags.append(clientTag)
        }

        let event: NostrEvent
        do {
            event = try await Signer.sign(
                keypair: keypair,
                kind: Nip10001.kindPinned,
                tags: tags,
                content: ""
            )
        } catch {
            throw SendError.missingKey
        }

        let publishRelays = !writeRelays.isEmpty
            ? writeRelays
            : Array(fetchSet)
        guard !publishRelays.isEmpty else { throw SendError.noRelays }

        let succeeded = await RelayPool.publish(event: event, to: publishRelays, timeout: 8)
        if succeeded.isEmpty { throw SendError.publishFailed }

        return ids
    }
}
