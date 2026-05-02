import Foundation

/// NIP-88 polls. Spec: https://github.com/nostr-protocol/nips/pull/320
///
/// Poll author publishes kind 1068. Voters publish kind 1018 with `e` pointing
/// at the poll and one `response` tag per chosen option id.
nonisolated enum Nip88 {
    static let kindPoll = 1068
    static let kindPollResponse = 1018

    enum PollType: String {
        case singlechoice
        case multiplechoice
    }

    struct PollOption: Hashable {
        let id: String
        let label: String
    }

    private static let optionIdAlphabet: [Character] = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    /// Random 9-char alphanumeric option id, matching Android's `OPTION_ID_CHARS.random()`.
    /// Uses `SystemRandomNumberGenerator` (CSPRNG) — collision risk across one poll's
    /// options is negligible, and the spec doesn't require unguessability.
    static func generateOptionId() -> String {
        var generator = SystemRandomNumberGenerator()
        var out = ""
        out.reserveCapacity(9)
        for _ in 0..<9 {
            let idx = Int.random(in: 0..<optionIdAlphabet.count, using: &generator)
            out.append(optionIdAlphabet[idx])
        }
        return out
    }

    /// Build kind-1068 tags. Order matches Android: options, relays, polltype, endsAt.
    static func buildPollTags(
        options: [PollOption],
        pollType: PollType = .singlechoice,
        endsAt: Int? = nil,
        relayUrls: [String] = []
    ) -> [[String]] {
        var tags: [[String]] = []
        for option in options {
            tags.append(["option", option.id, option.label])
        }
        for url in relayUrls {
            tags.append(["relay", url])
        }
        tags.append(["polltype", pollType.rawValue])
        if let endsAt {
            tags.append(["endsAt", String(endsAt)])
        }
        return tags
    }

    /// Build kind-1018 vote tags: e-tag at poll + one response per chosen option id.
    static func buildResponseTags(pollEventId: String, selectedOptionIds: [String]) -> [[String]] {
        var tags: [[String]] = [["e", pollEventId]]
        for optionId in selectedOptionIds {
            tags.append(["response", optionId])
        }
        return tags
    }

    static func parsePollOptions(_ event: NostrEvent) -> [PollOption] {
        event.tags.compactMap { tag in
            guard tag.count >= 3, tag[0] == "option" else { return nil }
            return PollOption(id: tag[1], label: tag[2])
        }
    }

    static func parsePollType(_ event: NostrEvent) -> PollType {
        let value = event.tags.first { $0.count >= 2 && $0[0] == "polltype" }?[1].lowercased()
        return value == "multiplechoice" ? .multiplechoice : .singlechoice
    }

    static func parseEndsAt(_ event: NostrEvent) -> Int? {
        guard let raw = event.tags.first(where: { $0.count >= 2 && $0[0] == "endsAt" })?[1] else { return nil }
        return Int(raw)
    }

    static func parsePollRelays(_ event: NostrEvent) -> [String] {
        event.tags.compactMap { tag in
            guard tag.count >= 2, tag[0] == "relay" else { return nil }
            return tag[1]
        }
    }

    static func isPollEnded(_ event: NostrEvent, now: Int = Int(Date().timeIntervalSince1970)) -> Bool {
        guard let endsAt = parseEndsAt(event) else { return false }
        return now > endsAt
    }

    /// First `e` tag value from a kind-1018 response — the poll being voted on.
    static func getPollEventId(_ response: NostrEvent) -> String? {
        response.tags.first { $0.count >= 2 && $0[0] == "e" }?[1]
    }

    /// Every `response` tag value from a kind-1018 response.
    static func getResponseOptionIds(_ response: NostrEvent) -> [String] {
        response.tags.compactMap { tag in
            guard tag.count >= 2, tag[0] == "response" else { return nil }
            return tag[1]
        }
    }
}
