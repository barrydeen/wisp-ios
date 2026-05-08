import Foundation

/// NIP-17 private DMs over NIP-59 gift wraps + NIP-44 v2 encryption.
/// Spec: https://github.com/nostr-protocol/nips/blob/master/17.md
struct Rumor {
    let pubkey: String
    let createdAt: Int
    let kind: Int   // 14 (chat), 15 (file), 7 (reaction)
    let content: String
    let tags: [[String]]
    /// The deterministic event id, computed via NIP-01 serialization.
    /// Rumors are unsigned but still need an id for threading (replies, reactions, zap targeting).
    let id: String
}

nonisolated enum Nip17 {

    enum Kind {
        static let chatMessage = 14
        static let fileMessage = 15
        static let reaction = 7
        static let seal = 13
        static let giftWrap = 1059
    }

    enum Error: Swift.Error {
        case wrongKind
        case decryptFailed
        case parseFailed
        case impersonation  // seal pubkey != rumor pubkey
    }

    // MARK: - Build / send

    /// Build an unsigned rumor for a chat message (or other DM rumor kind).
    /// The recipient pubkey is included as a `["p", recipient]` tag; group p-tags
    /// and reply tags should be appended via `extraTags`.
    static func buildRumor(senderPubkey: String, recipientPubkey: String, content: String,
                           kind: Int = Kind.chatMessage, extraTags: [[String]] = [],
                           createdAt: Int) -> Rumor {
        var tags: [[String]] = [["p", recipientPubkey]]
        tags.append(contentsOf: extraTags)
        let id = NostrEvent.computeId(pubkey: senderPubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
        return Rumor(pubkey: senderPubkey, createdAt: createdAt, kind: kind, content: content, tags: tags, id: id)
    }

    /// Compute the rumor id for an existing rumor (idempotent — already cached on Rumor).
    static func computeRumorId(_ r: Rumor) -> String { r.id }

    /// Serialize a rumor as a JSON object for the seal's encrypted plaintext.
    /// Rumors carry `id` but no `sig`.
    static func rumorJSON(_ r: Rumor) -> String {
        var out = "{\"id\":\""
        out.append(r.id)
        out.append("\",\"pubkey\":\"")
        out.append(r.pubkey)
        out.append("\",\"created_at\":")
        out.append(String(r.createdAt))
        out.append(",\"kind\":")
        out.append(String(r.kind))
        out.append(",\"tags\":[")
        for (i, tag) in r.tags.enumerated() {
            if i > 0 { out.append(",") }
            out.append("[")
            for (j, item) in tag.enumerated() {
                if j > 0 { out.append(",") }
                out.append("\"")
                out.append(escapeJSON(item))
                out.append("\"")
            }
            out.append("]")
        }
        out.append("],\"content\":\"")
        out.append(escapeJSON(r.content))
        out.append("\"}")
        return out
    }

    static func parseRumor(_ json: String) -> Rumor? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pubkey = obj["pubkey"] as? String,
              let createdAt = obj["created_at"] as? Int,
              let kind = obj["kind"] as? Int,
              let content = obj["content"] as? String else { return nil }
        let rawTags = obj["tags"] as? [[Any]] ?? []
        let tags = rawTags.map { $0.map { "\($0)" } }
        let id = (obj["id"] as? String)
            ?? NostrEvent.computeId(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
        return Rumor(pubkey: pubkey, createdAt: createdAt, kind: kind, content: content, tags: tags, id: id)
    }

    /// Build a fully signed gift wrap (kind 1059) targeting `recipientPubkey`,
    /// containing a sealed (kind 13) rumor (kind 14 chat by default).
    /// Pass the same `rumorCreatedAt` for every recipient of the same logical message
    /// so all recipients decrypt to identical rumor → same rumor id.
    static func createGiftWrap(senderPrivkey32: Data,
                               senderPubkey: String,
                               recipientPubkey: String,
                               message: String,
                               rumorKind: Int = Kind.chatMessage,
                               extraRumorTags: [[String]] = [],
                               rumorCreatedAt: Int,
                               powTargetBits: Int? = nil,
                               onPowProgress: ((Int) -> Void)? = nil) throws -> NostrEvent {
        // 1. Build rumor.
        let rumor = buildRumor(senderPubkey: senderPubkey,
                               recipientPubkey: recipientPubkey,
                               content: message,
                               kind: rumorKind,
                               extraTags: extraRumorTags,
                               createdAt: rumorCreatedAt)

        // 2. Build seal: encrypt rumor JSON with sender→recipient conversation key, sign with sender.
        let sealConvKey = try Nip44.getConversationKey(privkey32: senderPrivkey32, peerXonlyPubkey32: hexToData(recipientPubkey))
        let sealContent = try Nip44.encrypt(plaintext: rumorJSON(rumor), conversationKey: sealConvKey)
        let sealCreatedAt = randomizeTimestamp(Int(Date().timeIntervalSince1970))
        let seal = try NostrEvent.sign(privkey32: senderPrivkey32,
                                       pubkey: senderPubkey,
                                       kind: Kind.seal,
                                       createdAt: sealCreatedAt,
                                       tags: [],
                                       content: sealContent)

        // 3. Build gift wrap: ephemeral key encrypts seal JSON, signs with ephemeral.
        let ephemeralPriv = Schnorr.randomPrivkey()
        let ephemeralPub = try Schnorr.xonlyPubkey(privkey32: ephemeralPriv)
        let ephemeralPubHex = Hex.encode(ephemeralPub)
        let wrapConvKey = try Nip44.getConversationKey(privkey32: ephemeralPriv, peerXonlyPubkey32: hexToData(recipientPubkey))
        let wrapContent = try Nip44.encrypt(plaintext: seal.toJSON(), conversationKey: wrapConvKey)
        let wrapCreatedAt = randomizeTimestamp(Int(Date().timeIntervalSince1970))
        var wrapTags: [[String]] = [["p", recipientPubkey]]
        var wrapFinalCreatedAt = wrapCreatedAt
        if let bits = powTargetBits, bits > 0 {
            guard let mined = Nip13.mine(
                pubkey: ephemeralPubHex,
                kind: Kind.giftWrap,
                createdAt: wrapCreatedAt,
                tags: wrapTags,
                content: wrapContent,
                targetBits: bits,
                onProgress: onPowProgress
            ) else {
                throw Error.decryptFailed
            }
            wrapTags = mined.tags
            wrapFinalCreatedAt = mined.createdAt
        }
        let wrap = try NostrEvent.sign(privkey32: ephemeralPriv,
                                       pubkey: ephemeralPubHex,
                                       kind: Kind.giftWrap,
                                       createdAt: wrapFinalCreatedAt,
                                       tags: wrapTags,
                                       content: wrapContent)
        return wrap
    }

    // MARK: - Build / send via Signer

    /// Async variant of `createGiftWrap` that routes the seal's encryption + signing through
    /// `Signer`, so remote-signer (NIP-46) accounts can send DMs. The gift wrap layer keeps
    /// using a freshly generated ephemeral key per NIP-59 spec — no Signer needed for that
    /// step. For local accounts the result is byte-equivalent to `createGiftWrap`.
    static func createGiftWrapWithSigner(keypair: Keypair,
                                         recipientPubkey: String,
                                         message: String,
                                         rumorKind: Int = Kind.chatMessage,
                                         extraRumorTags: [[String]] = [],
                                         rumorCreatedAt: Int,
                                         powTargetBits: Int? = nil,
                                         onPowProgress: ((Int) -> Void)? = nil) async throws -> NostrEvent {
        // 1. Build rumor.
        let rumor = buildRumor(senderPubkey: keypair.pubkey,
                               recipientPubkey: recipientPubkey,
                               content: message,
                               kind: rumorKind,
                               extraTags: extraRumorTags,
                               createdAt: rumorCreatedAt)

        // 2. Seal: encrypt + sign via Signer (dispatches to NIP-46 for remote accounts,
        //    in-process Schnorr/NIP-44 for local).
        let sealContent = try await Signer.nip44Encrypt(
            keypair: keypair,
            peerPubkey: recipientPubkey,
            plaintext: rumorJSON(rumor)
        )
        let sealCreatedAt = randomizeTimestamp(Int(Date().timeIntervalSince1970))
        let seal = try await Signer.sign(
            keypair: keypair,
            kind: Kind.seal,
            tags: [],
            content: sealContent,
            createdAt: sealCreatedAt
        )

        // 3. Gift wrap with a fresh ephemeral key (NIP-59 spec — never the user's identity
        //    key, even when the user has a remote signer).
        let ephemeralPriv = Schnorr.randomPrivkey()
        let ephemeralPub = try Schnorr.xonlyPubkey(privkey32: ephemeralPriv)
        let ephemeralPubHex = Hex.encode(ephemeralPub)
        let wrapConvKey = try Nip44.getConversationKey(privkey32: ephemeralPriv, peerXonlyPubkey32: hexToData(recipientPubkey))
        let wrapContent = try Nip44.encrypt(plaintext: seal.toJSON(), conversationKey: wrapConvKey)
        let wrapCreatedAt = randomizeTimestamp(Int(Date().timeIntervalSince1970))
        var wrapTags: [[String]] = [["p", recipientPubkey]]
        var wrapFinalCreatedAt = wrapCreatedAt
        if let bits = powTargetBits, bits > 0 {
            guard let mined = Nip13.mine(
                pubkey: ephemeralPubHex,
                kind: Kind.giftWrap,
                createdAt: wrapCreatedAt,
                tags: wrapTags,
                content: wrapContent,
                targetBits: bits,
                onProgress: onPowProgress
            ) else {
                throw Error.decryptFailed
            }
            wrapTags = mined.tags
            wrapFinalCreatedAt = mined.createdAt
        }
        let wrap = try NostrEvent.sign(privkey32: ephemeralPriv,
                                       pubkey: ephemeralPubHex,
                                       kind: Kind.giftWrap,
                                       createdAt: wrapFinalCreatedAt,
                                       tags: wrapTags,
                                       content: wrapContent)
        return wrap
    }

    // MARK: - Receive / unwrap

    /// Unwrap an incoming kind-1059 gift wrap addressed to `recipientPrivkey32`'s pubkey.
    /// Returns the inner rumor on success, or throws on parse/decrypt/impersonation failure.
    static func unwrapGiftWrap(recipientPrivkey32: Data, giftWrap: NostrEvent) throws -> Rumor {
        guard giftWrap.kind == Kind.giftWrap else { throw Error.wrongKind }

        // Layer 1: decrypt the gift wrap with the ephemeral pubkey on the wrap.
        let wrapConvKey = try Nip44.getConversationKey(privkey32: recipientPrivkey32,
                                                       peerXonlyPubkey32: hexToData(giftWrap.pubkey))
        let sealJSON: String
        do { sealJSON = try Nip44.decrypt(payload: giftWrap.content, conversationKey: wrapConvKey) }
        catch { throw Error.decryptFailed }

        // Layer 2: parse the seal, decrypt with the seal's pubkey (real sender).
        guard let seal = NostrEvent.fromJSON(sealJSON), seal.kind == Kind.seal else { throw Error.parseFailed }
        let sealConvKey = try Nip44.getConversationKey(privkey32: recipientPrivkey32,
                                                       peerXonlyPubkey32: hexToData(seal.pubkey))
        let rumorJSON: String
        do { rumorJSON = try Nip44.decrypt(payload: seal.content, conversationKey: sealConvKey) }
        catch { throw Error.decryptFailed }

        guard let rumor = parseRumor(rumorJSON) else { throw Error.parseFailed }

        // Anti-impersonation check (NIP-59): seal author must match the rumor author.
        guard rumor.pubkey == seal.pubkey else { throw Error.impersonation }
        return rumor
    }

    /// Async variant of `unwrapGiftWrap` that routes both NIP-44 decrypts through `Signer`,
    /// so remote-signer (NIP-46) accounts can read DMs. Two RPC round-trips per gift wrap
    /// for remote accounts (one to peel each layer); local accounts are equivalent to the
    /// sync version with one extra `await`.
    static func unwrapGiftWrapWithSigner(keypair: Keypair, giftWrap: NostrEvent) async throws -> Rumor {
        guard giftWrap.kind == Kind.giftWrap else { throw Error.wrongKind }

        // Layer 1: decrypt the gift wrap. Peer is the wrap's ephemeral pubkey.
        let sealJSON: String
        do {
            sealJSON = try await Signer.nip44Decrypt(
                keypair: keypair,
                peerPubkey: giftWrap.pubkey,
                payload: giftWrap.content
            )
        } catch { throw Error.decryptFailed }

        // Layer 2: parse the seal, decrypt with the seal's pubkey (real sender).
        guard let seal = NostrEvent.fromJSON(sealJSON), seal.kind == Kind.seal else { throw Error.parseFailed }
        let rumorJSON: String
        do {
            rumorJSON = try await Signer.nip44Decrypt(
                keypair: keypair,
                peerPubkey: seal.pubkey,
                payload: seal.content
            )
        } catch { throw Error.decryptFailed }

        guard let rumor = parseRumor(rumorJSON) else { throw Error.parseFailed }

        // Anti-impersonation check (NIP-59): seal author must match the rumor author.
        guard rumor.pubkey == seal.pubkey else { throw Error.impersonation }
        return rumor
    }

    /// Extract the conversation participants from a rumor: sender + p-tags, sorted, excluding `myPubkey`.
    static func getConversationParticipants(rumor: Rumor, myPubkey: String) -> [String] {
        var all = Set<String>()
        all.insert(rumor.pubkey)
        for tag in rumor.tags where tag.count >= 2 && tag[0] == "p" {
            all.insert(tag[1])
        }
        all.remove(myPubkey)
        return all.sorted()
    }

    // MARK: - Helpers

    /// Randomize a Unix timestamp up to 1 day in the past (matches Android wisp).
    /// Spec allows up to 2 days, but tighter bound improves compatibility with strict `since` filters.
    static func randomizeTimestamp(_ base: Int) -> Int {
        let oneDay = 24 * 60 * 60
        return base - Int.random(in: 0..<oneDay)
    }

    private static func hexToData(_ hex: String) -> Data {
        Hex.decode(hex) ?? Data()
    }

    private static func escapeJSON(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if scalar.value < 0x20 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
