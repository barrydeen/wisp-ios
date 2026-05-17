import Foundation
import Observation

@Observable
@MainActor
final class OnboardingViewModel {
    let keypair: Keypair

    enum Phase: Equatable {
        case idle
        case fetchingProfile
        case fetchingFollows
        case fetchingRelayLists
        case buildingScoreBoard
        case done
        case error(String)
    }

    enum RestoreState: Equatable {
        case idle
        case restoring
        case restored(Int)
        case failed
    }

    var phase: Phase = .idle
    var isReady = false
    var profileName: String?
    var profilePicture: String?
    var followCount = 0
    var relayListsFound = 0

    /// A larger contact list recovered from relay history. Non-nil pauses the
    /// outbox build at the waiting step so the user can choose restore vs keep.
    var restoreOffer: FollowRestoreCandidate?
    var restoreState: RestoreState = .idle

    /// The (possibly clobbered) list the user actually arrived with. Kept so
    /// "keep current" and a failed restore both have something to fall back to.
    private var currentFollowPubkeys: [String] = []

    var scoreBoard: RelayScoreBoard?

    private static let indexerRelays = RelayDefaults.indexers

    static let statusMessages = [
        "Mapping your social graph\u{2026}",
        "Finding your friends\u{2019} relays\u{2026}",
        "Connecting to your network\u{2026}",
        "Locating gm notes\u{2026}",
        "Lower your time preference\u{2026}",
        "Almost there\u{2026}"
    ]

    init(keypair: Keypair) {
        self.keypair = keypair
    }

    func startOutboxBuilding() async {
        phase = .fetchingProfile

        let profileAndFollows = await RelayPool.query(
            relays: Self.indexerRelays,
            filter: NostrFilter(kinds: [0, 3], authors: [keypair.pubkey])
        )

        if let profileEvent = profileAndFollows
            .filter({ $0.kind == 0 })
            .max(by: { $0.createdAt < $1.createdAt }) {
            parseProfile(profileEvent)
        }

        phase = .fetchingFollows

        let kind3s = profileAndFollows.filter { $0.kind == 3 }
        var followPubkeys: [String] = []
        if let latest = kind3s.max(by: { $0.createdAt < $1.createdAt }) {
            followPubkeys = FollowHistoryGuard.followedPubkeys(in: latest)
        }

        currentFollowPubkeys = followPubkeys
        followCount = followPubkeys.count

        // Before committing to a possibly-clobbered list, see if a much larger
        // overwritten/tombstoned version is still recoverable from relays. If
        // so, pause here so the waiting step can ask the user what to do.
        if let candidate = await FollowHistoryGuard.evaluateRestore(
            pubkey: keypair.pubkey,
            currentFollows: followPubkeys,
            fetched: kind3s
        ) {
            restoreOffer = candidate
            return
        }

        await finishOutbox(followPubkeys: followPubkeys, recordHighWater: true)
    }

    /// User chose to restore the recovered list: republish it, adopt it as the
    /// trusted baseline, then build the outbox from the larger set.
    func acceptRestore() {
        guard let candidate = restoreOffer else { return }
        restoreOffer = nil
        restoreState = .restoring
        Task { @MainActor in
            do {
                try await FollowSender.shared.restore(
                    follows: candidate.pubkeys,
                    keypair: keypair
                )
                FollowHistoryGuard.didRestore(pubkey: keypair.pubkey, to: candidate.count)
                followCount = candidate.count
                restoreState = .restored(candidate.count)
                await finishOutbox(followPubkeys: candidate.pubkeys, recordHighWater: false)
            } catch {
                restoreState = .failed
                // Couldn't republish — fall back to what they arrived with so
                // the app is still usable.
                await finishOutbox(followPubkeys: currentFollowPubkeys, recordHighWater: false)
            }
        }
    }

    /// User chose to keep the smaller list. Record it as an intentional
    /// baseline so the same drop isn't flagged again, then continue.
    func declineRestore() {
        let candidateCount = restoreOffer?.count ?? followCount
        restoreOffer = nil
        FollowHistoryGuard.didDecline(
            pubkey: keypair.pubkey,
            currentCount: followCount,
            candidateCount: candidateCount
        )
        Task { @MainActor in
            await finishOutbox(followPubkeys: currentFollowPubkeys, recordHighWater: false)
        }
    }

    private func finishOutbox(followPubkeys: [String], recordHighWater: Bool) async {
        FollowsCache.shared.update(pubkey: keypair.pubkey, follows: followPubkeys)
        if recordHighWater {
            FollowHistoryGuard.recordHighWater(for: keypair.pubkey, count: followPubkeys.count)
        }

        guard !followPubkeys.isEmpty else {
            phase = .done
            isReady = true
            return
        }

        phase = .fetchingRelayLists

        let batchSize = 150
        var allRelayListEvents: [NostrEvent] = []
        for start in stride(from: 0, to: followPubkeys.count, by: batchSize) {
            let end = min(start + batchSize, followPubkeys.count)
            let chunk = Array(followPubkeys[start..<end])
            let events = await RelayPool.query(
                relays: Self.indexerRelays,
                filter: NostrFilter(kinds: [10002], authors: chunk),
                timeout: 15
            )
            allRelayListEvents.append(contentsOf: events)
            relayListsFound = allRelayListEvents.count
        }

        phase = .buildingScoreBoard

        var bestByAuthor: [String: NostrEvent] = [:]
        for event in allRelayListEvents {
            if let existing = bestByAuthor[event.pubkey] {
                if event.createdAt > existing.createdAt { bestByAuthor[event.pubkey] = event }
            } else {
                bestByAuthor[event.pubkey] = event
            }
        }

        // Populate the inbox-relay cache from the same kind:10002 events so threads can find
        // each follow's read relays without re-fetching.
        for (_, event) in bestByAuthor {
            RelayListRepository.shared.ingest(event)
        }
        await EventStore.shared.persist(Array(bestByAuthor.values))

        var writeRelaysByAuthor: [String: [String]] = [:]
        for (pubkey, event) in bestByAuthor {
            let relays = event.tags.compactMap { tag -> String? in
                guard tag.count >= 2, tag[0] == "r" else { return nil }
                if tag.count == 2 || tag[2] == "write" { return tag[1] }
                return nil
            }
            if !relays.isEmpty { writeRelaysByAuthor[pubkey] = relays }
        }

        let board = RelayScoreBoard()
        board.build(follows: followPubkeys, writeRelaysByAuthor: writeRelaysByAuthor, redundancy: 3)
        self.scoreBoard = board
        board.save(pubkey: keypair.pubkey)
        NostrKey.markOnboardingComplete(pubkey: keypair.pubkey)

        phase = .done
        isReady = true
    }

    private func parseProfile(_ event: NostrEvent) {
        guard let data = event.content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        profileName = json["display_name"] as? String ?? json["name"] as? String
        profilePicture = json["picture"] as? String
        ProfileRepository.shared.updateFromEvent(event)
    }
}
