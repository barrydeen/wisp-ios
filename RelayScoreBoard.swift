import Foundation

final class RelayScoreBoard {
    private(set) var relayAuthors: [String: Set<String>] = [:]
    private(set) var authorRelays: [String: Set<String>] = [:]
    private(set) var scoredRelays: [(url: String, count: Int)] = []

    func build(follows: [String], writeRelaysByAuthor: [String: [String]], redundancy: Int = 3) {
        var newRA: [String: Set<String>] = [:]
        var newAR: [String: Set<String>] = [:]

        for pubkey in follows {
            guard let relays = writeRelaysByAuthor[pubkey] else { continue }
            // Drop garbage URLs (.onion w/o tor support, localhost, IPs, host:port,
            // http://) before consuming the redundancy budget — otherwise an author
            // with 3 bad relays gets zero coverage instead of falling through to good ones.
            let valid = relays.filter { RelayUrlValidator.isValid($0) }
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
            let url = String(parts[0])
            // Older builds persisted bad URLs; drop them on load so they never reach the pool.
            guard RelayUrlValidator.isValid(url) else { continue }
            let authors = Set(parts[1].split(separator: ",").map(String.init))
            board.relayAuthors[url] = authors
            for author in authors { board.authorRelays[author, default: []].insert(url) }
        }
        board.rebuildScored()
        return board
    }
}
