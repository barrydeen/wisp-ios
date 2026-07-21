import Foundation
import CryptoKit

/// NIP-57 Lightning Zaps. Spec: https://github.com/nostr-protocol/nips/blob/master/57.md
///
/// Send flow: resolve recipient lud16 → build kind 9734 zap request → POST to LNURL callback
/// with the request as a `nostr=` query param → receive bolt11 invoice → pay via active wallet.
/// The LNURL server publishes the kind 9735 receipt to the relays in the request's `relays` tag.
nonisolated enum Nip57 {

    struct LnurlPayInfo {
        let callback: String
        let minSendable: Int64
        let maxSendable: Int64
        let allowsNostr: Bool
        let nostrPubkey: String?
    }

    /// Resolve a lud16 lightning address (`user@domain`) to its LNURL-pay endpoint info.
    /// Some servers omit `allowsNostr`; we default it to false in that case so callers fail loudly.
    static func resolveLud16(_ address: String) async -> LnurlPayInfo? {
        let parts = address.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let user = parts[0]
        let domain = parts[1]
        guard let url = URL(string: "https://\(domain)/.well-known/lnurlp/\(user)") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let callback = obj["callback"] as? String else { return nil }

        return LnurlPayInfo(
            callback: callback,
            minSendable: (obj["minSendable"] as? Int64) ?? Int64((obj["minSendable"] as? Int) ?? 1000),
            maxSendable: (obj["maxSendable"] as? Int64) ?? Int64((obj["maxSendable"] as? Int) ?? 100_000_000_000),
            allowsNostr: obj["allowsNostr"] as? Bool ?? false,
            nostrPubkey: obj["nostrPubkey"] as? String
        )
    }

    /// Build + sign a kind 9734 zap request via the Signer facade
    /// (local key or remote NIP-46).
    ///
    /// - `isAnonymous`: random ephemeral signs outer, empty `["anon", ""]` tag —
    ///   sender is hidden from public observation but not from the LNURL
    ///   operator (the LNURL receipt still references the relays + amount).
    /// - `isPrivate`: DIP-03 (https://github.com/damus-io/dips/blob/master/03.md).
    ///   Requires `eventId != nil` (the ephemeral key derives from it). Real
    ///   sender signs an inner kind-9733; that inner is encrypted to the
    ///   recipient and packed into the outer's `anon` tag. Outer is signed
    ///   by a deterministic ephemeral key, so only the sender can later
    ///   self-attribute. DIP-03 is unavailable for remote-signer (NIP-46)
    ///   accounts — the ephemeral derivation needs raw access to the user's
    ///   real privkey. Callers must gate the toggle accordingly.
    @MainActor
    static func buildZapRequest(
        keypair: Keypair,
        recipientPubkey: String,
        eventId: String?,
        amountMsats: Int64,
        relays: [String],
        lnurl: String,
        message: String = "",
        extraTags: [[String]] = [],
        isAnonymous: Bool = false,
        isPrivate: Bool = false
    ) async throws -> NostrEvent {
        var tags: [[String]] = [["p", recipientPubkey]]
        if let eventId { tags.append(["e", eventId]) }
        tags.append(["relays"] + relays)
        tags.append(["amount", String(amountMsats)])
        tags.append(["lnurl", lnurl])
        tags.append(contentsOf: extraTags)

        // Private (DIP-03) requires a target event id. Profile zaps and live-
        // stream a-tag zaps can't derive the deterministic ephemeral key.
        if isPrivate && eventId == nil {
            throw ZapBuildError.privateRequiresEventId
        }
        // Private also requires the user's real privkey (for inner signing +
        // ephemeral derivation). Watch-only / remote-signer keypairs must have
        // been gated at the UI layer; defensively reject here too.
        if isPrivate && (keypair.privkey.isEmpty || Hex.decode(keypair.privkey) == nil) {
            throw ZapBuildError.privateRequiresLocalKey
        }

        let createdAt = NostrClock.now()

        // DIP-03 private path: build inner 9733 (signed by real sender),
        // encrypt to recipient, pack into anon tag, sign outer with derived
        // ephemeral. Done in this order so we can reuse the same createdAt
        // across inner + outer + ephemeral derivation — receivers re-derive
        // the ephemeral key from the same triple to verify outer authorship.
        if isPrivate, let eventId,
           let senderPriv = Hex.decode(keypair.privkey),
           let recipientPub32 = Hex.decode(recipientPubkey) {
            // 1. Build + sign inner kind-9733 with real sender. Inner tags
            //    include only `p` (recipient) — no e/relays/amount, that's
            //    the outer's job.
            let innerTags: [[String]] = [["p", recipientPubkey]]
            let inner = try await Signer.sign(
                keypair: keypair,
                kind: Dip03.kindPrivateZapRequest,
                tags: innerTags,
                content: message,
                createdAt: createdAt
            )

            // 2. Derive ephemeral key + encrypt inner.
            let ephemeralPriv = Dip03.deriveEphemeralPrivkey(
                senderPrivkey32: senderPriv,
                targetEventId: eventId,
                createdAt: createdAt
            )
            let anonValue = try Dip03.encryptInner(
                innerJSON: inner.toJSON(),
                ephemeralPrivkey32: ephemeralPriv,
                recipientPubkey32: recipientPub32
            )
            tags.append(["anon", anonValue])

            // 3. Sign outer with ephemeral. NostrEvent.sign is the local path
            //    since we have the raw 32-byte privkey here.
            let ephemeralPub = try Schnorr.xonlyPubkey(privkey32: ephemeralPriv)
            return try NostrEvent.sign(
                privkey32: ephemeralPriv,
                pubkey: Hex.encode(ephemeralPub),
                kind: 9734,
                createdAt: createdAt,
                tags: tags,
                content: message
            )
        }

        // Anonymous (non-private): sign with a fresh random ephemeral key so
        // the user's real pubkey doesn't appear on the outer. Empty `anon`
        // tag signals "sender hidden, no decryption envelope".
        if isAnonymous {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
            let ephemeralPriv = Data(bytes)
            let ephemeralPub = (try? Schnorr.xonlyPubkey(privkey32: ephemeralPriv)).map { Hex.encode($0) } ?? keypair.pubkey
            tags.append(["anon", ""])
            return try NostrEvent.sign(
                privkey32: ephemeralPriv,
                pubkey: ephemeralPub,
                kind: 9734,
                createdAt: createdAt,
                tags: tags,
                content: message
            )
        }

        // Public zap: sign with the user's real keypair via the Signer facade
        // (remote-signer compatible).
        return try await Signer.sign(
            keypair: keypair,
            kind: 9734,
            tags: tags,
            content: message,
            createdAt: createdAt
        )
    }

    enum ZapBuildError: Swift.Error {
        case privateRequiresEventId
        case privateRequiresLocalKey
    }

    /// GET the LNURL callback with the signed zap request and return the bolt11 invoice (`pr`).
    static func fetchInvoice(callback: String, amountMsats: Int64, zapRequest: NostrEvent) async -> String? {
        let separator = callback.contains("?") ? "&" : "?"
        let zapJson = zapRequest.toJSON()
        guard let encoded = zapJson.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(callback)\(separator)amount=\(amountMsats)&nostr=\(encoded)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["pr"] as? String
    }

    /// Sats amount from a kind-9735 zap receipt's `bolt11` tag, or 0 if unparseable.
    static func zapAmountSats(receipt: NostrEvent) -> Int64 {
        guard receipt.kind == 9735 else { return 0 }
        guard let bolt11 = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "bolt11" })?[1] else { return 0 }
        return Bolt11.decode(bolt11)?.amountSats ?? 0
    }

    /// Pubkey of the zapper, parsed from the embedded kind-9734 zap-request in the receipt's `description` tag.
    static func zapperPubkey(receipt: NostrEvent) -> String? {
        guard receipt.kind == 9735 else { return nil }
        guard let desc = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
              let data = desc.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["pubkey"] as? String
    }

    /// Optional zap-request message (the `content` of the embedded kind-9734).
    static func zapMessage(receipt: NostrEvent) -> String? {
        guard receipt.kind == 9735 else { return nil }
        guard let desc = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
              let data = desc.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let content = json["content"] as? String
        return (content?.isEmpty == false) ? content : nil
    }

    /// Resolve the real sender + message of a possibly-DIP-03 zap receipt.
    /// Falls back to the embedded kind-9734's pubkey/content when the anon
    /// tag is absent or unparseable, so public zaps and DIP-03 zaps go through
    /// the same accessor. Pass the active user's privkey when called as the
    /// recipient; the function will attempt to decrypt the inner kind-9733.
    /// Returns `nil` when the receipt isn't a kind-9735.
    static func resolveZapSender(receipt: NostrEvent, recipientPrivkey32: Data?) -> (pubkey: String, message: String, isPrivate: Bool)? {
        guard receipt.kind == 9735 else { return nil }
        guard let desc = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
              let data = desc.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let publicPubkey = (json["pubkey"] as? String) ?? receipt.pubkey
        let publicMessage = (json["content"] as? String) ?? ""

        // DIP-03 detection: the embedded kind-9734 has an ["anon", ...] tag
        // whose value structurally matches the bech32 pack. If it does and
        // we have a privkey, try to recover the inner kind-9733.
        let descTags = json["tags"] as? [[String]] ?? []
        guard let anonTag = descTags.first(where: { $0.count >= 2 && $0[0] == "anon" }) else {
            return (publicPubkey, publicMessage, false)
        }
        let anonValue = anonTag[1]
        if anonValue.isEmpty {
            // Anonymous (NIP-57 plain) — sender hidden, no decryption envelope.
            return (publicPubkey, publicMessage, true)
        }
        guard Dip03.isDip03AnonValue(anonValue),
              let privkey = recipientPrivkey32,
              let ephemeralPub32 = Hex.decode(publicPubkey) else {
            return (publicPubkey, publicMessage, true)
        }
        do {
            let inner = try Dip03.decryptInner(
                anonValue: anonValue,
                recipientPrivkey32: privkey,
                ephemeralPubkey32: ephemeralPub32
            )
            let message = inner.content.isEmpty ? publicMessage : inner.content
            return (inner.pubkey, message, true)
        } catch {
            return (publicPubkey, publicMessage, true)
        }
    }

    /// Self-attribution: given our own outgoing DIP-03 receipt, re-derive the
    /// ephemeral key and decrypt the inner. Returns the recipient's pubkey on
    /// success — the caller already knows that's "me" via the receipt's `p`
    /// tag, but the inner kind-9733's `pubkey` confirms it's a zap *we* sent.
    static func resolveOwnOutgoingZap(receipt: NostrEvent, senderPrivkey32: Data) -> (pubkey: String, message: String)? {
        guard receipt.kind == 9735 else { return nil }
        guard let desc = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
              let data = desc.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let descTags = json["tags"] as? [[String]] ?? []
        guard let anonTag = descTags.first(where: { $0.count >= 2 && $0[0] == "anon" }),
              Dip03.isDip03AnonValue(anonTag[1]) else { return nil }

        guard let eTag = descTags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1],
              let pTag = descTags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1],
              let createdAtRaw = json["created_at"] as? Int,
              let outerPub32 = Hex.decode((json["pubkey"] as? String) ?? receipt.pubkey),
              let recipientPub32 = Hex.decode(pTag) else { return nil }

        do {
            let inner = try Dip03.decryptInnerSelfAttribution(
                anonValue: anonTag[1],
                senderPrivkey32: senderPrivkey32,
                targetEventId: eTag,
                createdAt: createdAtRaw,
                receiptOuterPubkey32: outerPub32,
                recipientPubkey32: recipientPub32
            )
            return (inner.pubkey, inner.content)
        } catch {
            return nil
        }
    }

    /// Validate a kind 9735 receipt against the LNURL server's nostrPubkey and the expected amount.
    /// Per the spec, receipts are NOT signed by sender or recipient identity keys — the chain of
    /// trust is the LNURL operator's pubkey.
    static func validateReceipt(_ event: NostrEvent, expectedNostrPubkey: String, expectedAmountMsats: Int64?) -> Bool {
        guard event.kind == 9735 else { return false }
        guard event.pubkey.lowercased() == expectedNostrPubkey.lowercased() else { return false }

        if let expected = expectedAmountMsats,
           let bolt11 = event.tags.first(where: { $0.count >= 2 && $0[0] == "bolt11" })?[1],
           let decoded = Bolt11.decode(bolt11),
           let satsAmount = decoded.amountSats {
            // bolt11 is in sats; expected is in msats
            if satsAmount * 1000 != expected { return false }
        }

        if let description = event.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
           let bolt11 = event.tags.first(where: { $0.count >= 2 && $0[0] == "bolt11" })?[1] {
            // description hash is encoded inside bolt11 tag 23. We don't fully decode it; instead
            // confirm description is a JSON object with kind 9734.
            if let data = description.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let kind = json["kind"] as? Int, kind == 9734 {
                _ = bolt11 // amount already validated above
            } else {
                return false
            }
        }

        return true
    }
}
