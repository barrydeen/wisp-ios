import Foundation

/// Owns the long-lived NIP-53 discovery subscriptions for the current user session.
/// Two subs run in parallel:
///  - kind 30311 (live activities) — feeds `LiveStreamRepository.streams`
///  - kind 1311 since=now-3600 (recent live chat) — feeds chatter counts only (no full message storage)
///
/// Both stay open until `stopDiscovery()` is called (typically on logout). Per-stream chat/reaction/zap
/// subs are owned separately by `LiveStreamViewModel`.
@MainActor
final class LiveStreamCoordinator {
    static let shared = LiveStreamCoordinator()

    private var activitySub: RelaySubscription?
    private var chatDiscoverySub: RelaySubscription?
    private var consumerTasks: [Task<Void, Never>] = []
    private var profileFetchTask: Task<Void, Never>?
    private var pendingHostFetches = Set<String>()

    private static let indexerRelays = RelayDefaults.indexers

    func startDiscovery(myPubkey: String, readRelays: [String]) {
        guard activitySub == nil, chatDiscoverySub == nil else { return }
        let relays = readRelays.isEmpty ? Self.indexerRelays : readRelays

        let activity = RelayPool.subscribe(
            relays: relays,
            filter: NostrFilter(kinds: [Nip53.kindLiveActivity], limit: 50),
            id: "live-activities"
        )
        activitySub = activity

        let since = Int(Date().timeIntervalSince1970) - 3600
        let chat = RelayPool.subscribe(
            relays: relays,
            filter: NostrFilter(kinds: [Nip53.kindLiveChatMessage], limit: 500, since: since),
            id: "live-chat-discovery"
        )
        chatDiscoverySub = chat

        let activityTask = Task { [weak self] in
            for await (event, _) in activity.events {
                guard let self else { return }
                await MainActor.run {
                    LiveStreamRepository.shared.addActivity(event)
                    self.queueHostProfileFetch(event.pubkey)
                    if let streamerPk = Nip53.parseLiveActivity(event)?.streamerPubkey {
                        self.queueHostProfileFetch(streamerPk)
                    }
                }
            }
        }
        consumerTasks.append(activityTask)

        let chatTask = Task {
            for await (event, _) in chat.events {
                await MainActor.run {
                    LiveStreamRepository.shared.trackChatter(event)
                }
            }
        }
        consumerTasks.append(chatTask)
    }

    func stopDiscovery() {
        for t in consumerTasks { t.cancel() }
        consumerTasks.removeAll()
        activitySub?.cancel()
        chatDiscoverySub?.cancel()
        activitySub = nil
        chatDiscoverySub = nil
        profileFetchTask?.cancel()
        profileFetchTask = nil
        pendingHostFetches.removeAll()
    }

    // MARK: - Profile prefetch (debounced batch)

    private func queueHostProfileFetch(_ pubkey: String) {
        if ProfileRepository.shared.get(pubkey) != nil { return }
        pendingHostFetches.insert(pubkey)
        if profileFetchTask == nil || profileFetchTask?.isCancelled == true {
            profileFetchTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.flushProfileFetches()
            }
        }
    }

    private func flushProfileFetches() async {
        let batch = Array(pendingHostFetches.prefix(50))
        pendingHostFetches.subtract(batch)
        profileFetchTask = nil
        guard !batch.isEmpty else { return }
        let events = await RelayPool.query(
            relays: Self.indexerRelays,
            filter: NostrFilter(kinds: [0], authors: batch, limit: batch.count),
            timeout: 6
        )
        for event in events where event.kind == 0 {
            _ = ProfileRepository.shared.updateFromEvent(event)
        }
        if !pendingHostFetches.isEmpty {
            profileFetchTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.flushProfileFetches()
            }
        }
    }
}
