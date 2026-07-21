import Foundation

/// Sends a kind-1018 vote on a NIP-88 poll.
///
/// Pipeline: validate → build tags → sign → optimistic apply → publish to user's
/// write relays + poll's advertised `relay` tags + poll-author's read relays. On
/// total publish failure, revert the optimistic apply and return `.rejected`.
@MainActor
enum PollVoteSender {

    enum Failure: Error {
        case alreadyEnded
        case noOptions
        case signingFailed
        case rejected
    }

    /// Cast a vote. `optionIds` are the chosen option ids from the poll's `option` tags.
    static func castVote(
        pollEvent: NostrEvent,
        optionIds: [String],
        keypair: Keypair
    ) async -> Result<NostrEvent, Failure> {
        guard pollEvent.kind == Nip88.kindPoll else { return .failure(.signingFailed) }
        guard !optionIds.isEmpty else { return .failure(.noOptions) }
        if Nip88.isPollEnded(pollEvent) { return .failure(.alreadyEnded) }

        var tags = Nip88.buildResponseTags(pollEventId: pollEvent.id, selectedOptionIds: optionIds)
        if let clientTag = NostrEvent.clientTagIfEnabled() { tags.append(clientTag) }

        let now = NostrClock.now()
        guard let privkeyBytes = Hex.decode(keypair.privkey) else { return .failure(.signingFailed) }

        let signed: NostrEvent
        do {
            signed = try NostrEvent.sign(
                privkey32: privkeyBytes,
                pubkey: keypair.pubkey,
                kind: Nip88.kindPollResponse,
                createdAt: now,
                tags: tags,
                content: ""
            )
        } catch {
            return .failure(.signingFailed)
        }

        // Optimistic apply so the UI updates immediately.
        PollTallyRepository.shared.applyOptimisticVote(
            pollEvent: pollEvent,
            optionIds: optionIds,
            voterPubkey: keypair.pubkey,
            ts: now
        )

        // Target relays: union of user's top write relays + poll's advertised relays
        // + poll author's read relays (top 3).
        var relays = Set<String>(RelayRouting.topWriteRelays(for: keypair.pubkey))
        for r in Nip88.parsePollRelays(pollEvent) { relays.insert(r) }
        let authorReads = await RelayListRepository.shared.getReadRelays(pollEvent.pubkey)
        for r in authorReads.prefix(3) { relays.insert(r) }

        let succeeded = await RelayPool.publish(event: signed, to: Array(relays), timeout: 8)
        if succeeded.isEmpty {
            PollTallyRepository.shared.revertOptimisticVote(
                pollEvent: pollEvent,
                optionIds: optionIds,
                voterPubkey: keypair.pubkey
            )
            return .failure(.rejected)
        }

        // Persist so the user's own vote is reflected on cold-start.
        await EventStore.shared.persist([signed])
        // Re-route through the tally repo to claim the seen-id slot — prevents double-count
        // when relays echo it back through a live subscription.
        PollTallyRepository.shared.ingestPollResponse(signed)
        return .success(signed)
    }
}
