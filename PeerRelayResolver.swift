import Foundation

/// Which of a peer's published relay lists a gift-wrap delivery set was drawn
/// from. Surfaced in the conversation relay panel so the user can see *why* we
/// route to a given relay. Only the recipient's *inbox* lists are valid DM
/// delivery targets — see `resolveWithSource`.
enum DeliveryRelaySource {
    case dmRelays    // kind-10050 NIP-17 DM relays
    case readRelays  // kind-10002 NIP-65 read/inbox relays
}

/// A resolved delivery target set plus its provenance. Mirrors Android
/// `PeerDeliveryRelays`.
struct PeerDeliveryRelays: Equatable {
    let urls: [String]
    let source: DeliveryRelaySource
}

/// Resolve a peer's gift-wrap delivery targets. Applies the NIP-17 routing
/// hierarchy used by Android: kind-10050 DM relays first, kind-10002 read
/// (inbox) relays second, empty third. Never falls back to write relays —
/// senders publish gift wraps to the recipient's *inbox*, not their outbox.
@MainActor
enum PeerRelayResolver {
    /// Returns the set of relays the caller should publish a gift wrap to.
    /// Caller must surface a "no relays" error when this returns empty —
    /// silently routing to default relays would leak the wrap to public
    /// infrastructure the recipient never opted into.
    static func resolveDmTargets(pubkey: String) async -> [String] {
        if let dm = await RelayListRepository.shared.getDmRelays(pubkey), !dm.isEmpty {
            return canonicalize(dm)
        }
        let inbox = await RelayListRepository.shared.getReadRelays(pubkey)
        return canonicalize(inbox)
    }

    /// Resolve a peer's gift-wrap delivery targets AND record which list they came from,
    /// for the conversation relay panel. ALWAYS the recipient's own *inbox*: their kind-10050
    /// DM relays, else their kind-10002 read (inbox) relays. Never the sender's relays and
    /// never the recipient's write/outbox — a wrap published there would never reach them
    /// (they don't read our relays, and NIP-17 delivers to the inbox, not the outbox).
    /// Returns empty urls when the peer has published no inbox; the caller picks the
    /// last-ditch fallback (a public best-effort, never our own relays).
    static func resolveWithSource(pubkey: String) async -> PeerDeliveryRelays {
        if let dm = await RelayListRepository.shared.getDmRelays(pubkey), !dm.isEmpty {
            return PeerDeliveryRelays(urls: canonicalize(dm), source: .dmRelays)
        }
        // Strict read/inbox split (unmarked relays count as read) — no write fallback.
        let read = await RelayListRepository.shared.readWriteSplit(pubkey).read
        return PeerDeliveryRelays(urls: canonicalize(read), source: .readRelays)
    }

    private static func canonicalize(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for url in urls {
            guard let n = RelayUrlValidator.canonicalize(url) else { continue }
            if seen.insert(n).inserted { out.append(n) }
        }
        return out
    }
}
