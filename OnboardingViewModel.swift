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

    var phase: Phase = .idle
    var isReady = false
    var profileName: String?
    var profilePicture: String?
    var followCount = 0
    var relayListsFound = 0

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

        var followPubkeys: [String] = []
        if let followEvent = profileAndFollows
            .filter({ $0.kind == 3 })
            .max(by: { $0.createdAt < $1.createdAt }) {
            followPubkeys = followEvent.tags.compactMap { tag in
                tag.count >= 2 && tag[0] == "p" ? tag[1] : nil
            }
        }

        followCount = followPubkeys.count
        FollowsCache.shared.update(pubkey: keypair.pubkey, follows: followPubkeys)

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
