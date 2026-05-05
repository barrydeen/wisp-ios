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

        // Anonymous or private: sign with an ephemeral random keypair so the
        // user's real pubkey doesn't appear as the kind-9734 author. Private
        // additionally encrypts the real sender identity in the `anon` tag
        // (NIP-04 between the ephemeral key and the recipient) so only the
        // recipient can reveal the sender. The ephemeral key is generated
        // locally and the encryption needs only the ephemeral privkey +
        // recipient pubkey, so this works for both local and remote-signer
        // accounts.
        let signingKeypair: Keypair
        if isAnonymous || isPrivate {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
            let ephemeralPriv = Data(bytes)
            let ephemeralPub = Secp256k1.publicKey(from: ephemeralPriv).map { Hex.encode($0) } ?? keypair.pubkey
            signingKeypair = Keypair(privkey: Hex.encode(ephemeralPriv), pubkey: ephemeralPub)

            if isPrivate {
                let plaintext = "{\"pubkey\":\"\(keypair.pubkey)\"}"
                if let recipientPub32 = Hex.decode(recipientPubkey),
                   let secret = try? Nip04.sharedSecret(privkey32: ephemeralPriv, peerXonlyPubkey32: recipientPub32),
                   let encrypted = try? Nip04.encrypt(plaintext, sharedSecret: secret) {
                    tags.append(["anon", encrypted])
                } else {
                    tags.append(["anon", ""])
                }
            } else {
                tags.append(["anon", ""])
            }
        } else {
            signingKeypair = keypair
        }

        return try await Signer.sign(
            keypair: signingKeypair,
            kind: 9734,
            tags: tags,
            content: message
        )
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
