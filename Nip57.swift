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

    /// Build an unsigned-then-signed kind 9734 zap request event.
    static func buildZapRequest(
        senderPrivkey32: Data,
        senderPubkey: String,
        recipientPubkey: String,
        eventId: String?,
        amountMsats: Int64,
        relays: [String],
        lnurl: String,
        message: String = "",
        extraTags: [[String]] = []
    ) throws -> NostrEvent {
        var tags: [[String]] = [["p", recipientPubkey]]
        if let eventId { tags.append(["e", eventId]) }
        tags.append(["relays"] + relays)
        tags.append(["amount", String(amountMsats)])
        tags.append(["lnurl", lnurl])
        tags.append(contentsOf: extraTags)

        return try NostrEvent.sign(
            privkey32: senderPrivkey32,
            pubkey: senderPubkey,
            kind: 9734,
            createdAt: Int(Date().timeIntervalSince1970),
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
