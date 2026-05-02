import Foundation

nonisolated enum Nip13 {

    /// Count leading zero bits in a hex event id. Each '0' nibble is 4 bits;
    /// the first non-zero nibble contributes its own leading-zero bit count.
    static func countLeadingZeroBits(_ eventIdHex: String) -> Int {
        var bits = 0
        for c in eventIdHex {
            guard let nibble = Int(String(c), radix: 16) else { return bits }
            if nibble == 0 {
                bits += 4
            } else {
                if nibble < 2 { bits += 3 }
                else if nibble < 4 { bits += 2 }
                else if nibble < 8 { bits += 1 }
                break
            }
        }
        return bits
    }

    /// Returns the actual leading zero bits if the event has a `nonce` tag with a
    /// committed difficulty that the id meets; otherwise 0.
    static func verifyDifficulty(_ event: NostrEvent) -> Int {
        guard let committed = committedDifficulty(event) else { return 0 }
        let actual = countLeadingZeroBits(event.id)
        return actual >= committed ? actual : 0
    }

    private static func committedDifficulty(_ event: NostrEvent) -> Int? {
        guard let nonceTag = event.tags.first(where: { $0.count >= 3 && $0.first == "nonce" }) else {
            return nil
        }
        return Int(nonceTag[2])
    }

    struct MineResult {
        let tags: [[String]]
        let createdAt: Int
    }

    /// Mine a nonce until the event id has at least `targetBits` leading zero bits.
    /// Returns nil if the surrounding `Task` is cancelled. Calls `onProgress(attempts)`
    /// every 10,000 iterations. Cooperative cancellation checked every 1024 iterations.
    static func mine(
        pubkey: String,
        kind: Int,
        createdAt: Int,
        tags: [[String]],
        content: String,
        targetBits: Int,
        onProgress: ((Int) -> Void)? = nil
    ) -> MineResult? {
        var nonce = 0
        while true {
            if nonce % 1024 == 0 {
                if Task.isCancelled { return nil }
            }
            if nonce > 0, nonce % 10_000 == 0 {
                onProgress?(nonce)
            }
            var mineTags = tags
            mineTags.append(["nonce", String(nonce), String(targetBits)])
            let id = NostrEvent.computeId(pubkey: pubkey, createdAt: createdAt,
                                          kind: kind, tags: mineTags, content: content)
            if countLeadingZeroBits(id) >= targetBits {
                return MineResult(tags: mineTags, createdAt: createdAt)
            }
            nonce &+= 1
        }
    }
}
