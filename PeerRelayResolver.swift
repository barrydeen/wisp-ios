import Foundation

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
