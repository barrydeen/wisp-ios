import Foundation

nonisolated final class RelayScoreBoard {
    private(set) var relayAuthors: [String: Set<String>] = [:]
    private(set) var authorRelays: [String: Set<String>] = [:]
    private(set) var scoredRelays: [(url: String, count: Int)] = []

    func build(follows: [String], writeRelaysByAuthor: [String: [String]], redundancy: Int = 3) {
        var newRA: [String: Set<String>] = [:]
        var newAR: [String: Set<String>] = [:]

        for pubkey in follows {
            guard let relays = writeRelaysByAuthor[pubkey] else { continue }
            // Canonicalize first: lowercase host + strip trailing slash + validate.
            // Without this, `wss://Relay.Damus.IO/` and `wss://relay.damus.io` count
            // as separate relays — inflates the pool and creates duplicate sockets.
            // Dedupe via Set before taking the first N to use the redundancy budget on
            // distinct relays, not duplicate spellings of the same one.
            var seen = Set<String>()
            var valid: [String] = []
            for url in relays {
                guard let canon = RelayUrlValidator.canonicalize(url),
                      seen.insert(canon).inserted else { continue }
                valid.append(canon)
            }
            let eligible = Array(valid.prefix(redundancy))
            for url in eligible {
                newRA[url, default: []].insert(pubkey)
                newAR[pubkey, default: []].insert(url)
            }
        }

        relayAuthors = newRA
        authorRelays = newAR
        rebuildScored()
    }

    private func rebuildScored() {
        scoredRelays = relayAuthors
            .map { (url: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Persistence

    func save(pubkey: String) {
        let entries = relayAuthors.map { "\($0.key)\t\($0.value.joined(separator: ","))" }
        UserDefaults.standard.set(entries, forKey: "relay_scoreboard_v1_\(pubkey)")
    }

    static func load(pubkey: String) -> RelayScoreBoard? {
        guard let entries = UserDefaults.standard.stringArray(forKey: "relay_scoreboard_v1_\(pubkey)"),
              !entries.isEmpty else { return nil }
        let board = RelayScoreBoard()
        for entry in entries {
            let parts = entry.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            // Canonicalize on load: handles persisted variants (case, trailing slash, .onion, IPs)
            // from older builds. Multiple variants of the same relay merge their author sets.
            guard let url = RelayUrlValidator.canonicalize(String(parts[0])) else { continue }
            let authors = Set(parts[1].split(separator: ",").map(String.init))
            board.relayAuthors[url, default: []].formUnion(authors)
            for author in authors { board.authorRelays[author, default: []].insert(url) }
        }
        board.rebuildScored()
        return board
    }
}
