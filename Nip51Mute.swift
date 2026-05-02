import Foundation

/// NIP-51 mute list (kind:10000). Wisp publishes everything in the NIP-44-encrypted private
/// body — empty public tags — for parity with the Android client. Other clients that publish
/// `["p", pk]` in plain tags are still respected on read via `parsePublicTags`.
///
/// Encrypted body shape: `[["p", "<hex>"], ["word", "<text>"], ["e", "<rootEventId>"]]`,
/// JSON-encoded as a UTF-8 string, then NIP-44-v2 encrypted with `Nip44.getConversationKey`
/// using the user's privkey × own pubkey (self-encryption).
nonisolated enum Nip51Mute {

    static let kindMuteList = 10000

    struct Lists: Sendable, Equatable {
        var pubkeys: Set<String> = []
        var words: Set<String> = []
        var threads: Set<String> = []

        static let empty = Lists()
    }

    // MARK: - Build

    static func buildPrivateBodyJson(
        pubkeys: Set<String>,
        words: Set<String>,
        threads: Set<String>
    ) -> String {
        // Stable ordering so equal inputs produce equal output (important for tests; not load-bearing
        // at runtime since the relay treats it as opaque ciphertext).
        var entries: [[String]] = []
        entries.reserveCapacity(pubkeys.count + words.count + threads.count)
        for pk in pubkeys.sorted() { entries.append(["p", pk]) }
        for w in words.sorted() { entries.append(["word", w]) }
        for t in threads.sorted() { entries.append(["e", t]) }
        guard let data = try? JSONSerialization.data(withJSONObject: entries, options: []),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }

    static func buildSignedMuteEvent(
        privkey32: Data,
        ownPubkey: String,
        blockedPubkeys: Set<String>,
        mutedWords: Set<String>,
        mutedThreads: Set<String>,
        createdAt: Int = Int(Date().timeIntervalSince1970)
    ) throws -> NostrEvent {
        let json = buildPrivateBodyJson(
            pubkeys: blockedPubkeys, words: mutedWords, threads: mutedThreads
        )
        guard let ownPubkeyData = Hex.decode(ownPubkey) else {
            throw NSError(domain: "Nip51Mute", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid own pubkey hex"])
        }
        let convKey = try Nip44.getConversationKey(
            privkey32: privkey32,
            peerXonlyPubkey32: ownPubkeyData
        )
        // NIP-44 rejects empty plaintext, so even an empty list still contains "[]".
        let cipher = try Nip44.encrypt(plaintext: json, conversationKey: convKey)

        return try NostrEvent.sign(
            privkey32: privkey32,
            pubkey: ownPubkey,
            kind: kindMuteList,
            createdAt: createdAt,
            tags: [],
            content: cipher
        )
    }

    // MARK: - Parse

    /// Parse the NIP-44-encrypted private body and merge with any public tags.
    static func decryptAndParse(event: NostrEvent, privkey32: Data) throws -> Lists {
        guard event.kind == kindMuteList else { return .empty }

        var combined = parsePublicTags(event: event)

        guard !event.content.isEmpty else { return combined }

        guard let peerData = Hex.decode(event.pubkey) else {
            throw NSError(domain: "Nip51Mute", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid event pubkey hex"])
        }
        let convKey = try Nip44.getConversationKey(
            privkey32: privkey32,
            peerXonlyPubkey32: peerData
        )
        let plaintext = try Nip44.decrypt(payload: event.content, conversationKey: convKey)
        let priv = parsePrivateBody(plaintext)
        combined.pubkeys.formUnion(priv.pubkeys)
        combined.words.formUnion(priv.words)
        combined.threads.formUnion(priv.threads)
        return combined
    }

    static func parsePublicTags(event: NostrEvent) -> Lists {
        guard event.kind == kindMuteList else { return .empty }
        var lists = Lists()
        for tag in event.tags {
            guard tag.count >= 2 else { continue }
            switch tag[0] {
            case "p":
                lists.pubkeys.insert(tag[1])
            case "word":
                lists.words.insert(tag[1].lowercased())
            case "e":
                lists.threads.insert(tag[1])
            default:
                break
            }
        }
        return lists
    }

    static func parsePrivateBody(_ json: String) -> Lists {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else {
            return .empty
        }
        var lists = Lists()
        for tag in arr {
            guard tag.count >= 2 else { continue }
            guard let key = tag[0] as? String else { continue }
            guard let value = tag[1] as? String else { continue }
            switch key {
            case "p":
                lists.pubkeys.insert(value)
            case "word":
                lists.words.insert(value.lowercased())
            case "e":
                lists.threads.insert(value)
            default:
                break
            }
        }
        return lists
    }
}
