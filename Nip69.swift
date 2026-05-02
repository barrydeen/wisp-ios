import Foundation

/// NIP-69 / Kind 6969: Zap Polls.
///
/// Experimental poll format where votes are cast via Lightning zaps. Each kind-9734
/// zap-request includes a `["poll_option", "<index>"]` tag, which the LNURL server
/// then echoes verbatim into the kind-9735 receipt's `description` field. Tally is
/// by total sats per option; one vote per pubkey, latest-wins.
nonisolated enum Nip69 {
    static let kindZapPoll = 6969

    struct ZapPollOption: Hashable {
        let index: Int
        let label: String
    }

    /// Build kind-6969 tags. Order matches Android: poll_option, value_minimum,
    /// value_maximum, consensus_threshold, closed_at, relays.
    static func buildZapPollTags(
        options: [ZapPollOption],
        valueMinimum: Int? = nil,
        valueMaximum: Int? = nil,
        consensusThreshold: Int? = nil,
        closedAt: Int? = nil,
        relayUrls: [String] = []
    ) -> [[String]] {
        var tags: [[String]] = []
        for option in options {
            tags.append(["poll_option", String(option.index), option.label])
        }
        if let valueMinimum {
            tags.append(["value_minimum", String(valueMinimum)])
        }
        if let valueMaximum {
            tags.append(["value_maximum", String(valueMaximum)])
        }
        if let consensusThreshold {
            tags.append(["consensus_threshold", String(consensusThreshold)])
        }
        if let closedAt {
            tags.append(["closed_at", String(closedAt)])
        }
        for url in relayUrls {
            tags.append(["relay", url])
        }
        return tags
    }

    static func parseZapPollOptions(_ event: NostrEvent) -> [ZapPollOption] {
        event.tags.compactMap { tag in
            guard tag.count >= 3, tag[0] == "poll_option", let idx = Int(tag[1]) else { return nil }
            return ZapPollOption(index: idx, label: tag[2])
        }
    }

    static func parseValueMinimum(_ event: NostrEvent) -> Int? {
        guard let raw = event.tags.first(where: { $0.count >= 2 && $0[0] == "value_minimum" })?[1] else { return nil }
        return Int(raw)
    }

    static func parseValueMaximum(_ event: NostrEvent) -> Int? {
        guard let raw = event.tags.first(where: { $0.count >= 2 && $0[0] == "value_maximum" })?[1] else { return nil }
        return Int(raw)
    }

    static func parseConsensusThreshold(_ event: NostrEvent) -> Int? {
        guard let raw = event.tags.first(where: { $0.count >= 2 && $0[0] == "consensus_threshold" })?[1],
              let value = Int(raw) else { return nil }
        return min(100, max(0, value))
    }

    static func parseClosedAt(_ event: NostrEvent) -> Int? {
        guard let raw = event.tags.first(where: { $0.count >= 2 && $0[0] == "closed_at" })?[1] else { return nil }
        return Int(raw)
    }

    static func isZapPollClosed(_ event: NostrEvent, now: Int = Int(Date().timeIntervalSince1970)) -> Bool {
        guard let closedAt = parseClosedAt(event) else { return false }
        return now > closedAt
    }

    static func parseZapPollRelays(_ event: NostrEvent) -> [String] {
        event.tags.compactMap { tag in
            guard tag.count >= 2, tag[0] == "relay" else { return nil }
            return tag[1]
        }
    }

    /// Decode a kind-9735 receipt's `description` (the embedded kind-9734 zap-request) and
    /// return the `poll_option` index, if present. Returns nil if the description is missing,
    /// malformed, or has no `poll_option` tag.
    static func getZapPollOptionFromZapReceipt(_ zapReceipt: NostrEvent) -> Int? {
        guard let desc = zapReceipt.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1] else { return nil }
        guard let req = NostrEvent.fromJSON(desc) else { return nil }
        guard let raw = req.tags.first(where: { $0.count >= 2 && $0[0] == "poll_option" })?[1] else { return nil }
        return Int(raw)
    }
}
