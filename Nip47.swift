import Foundation

/// NIP-47 Nostr Wallet Connect — request/response wire format and event-build helpers.
/// Spec: https://github.com/nostr-protocol/nips/blob/master/47.md
nonisolated enum Nip47 {
    static let infoKind = 13194
    static let requestKind = 23194
    static let responseKind = 23195

    enum Encryption: String {
        case nip04
        case nip44
    }

    enum Request {
        case getBalance
        case getInfo
        case payInvoice(bolt11: String)
        case makeInvoice(amountMsats: Int64, description: String)
        case lookupInvoice(paymentHash: String)
        case listTransactions(limit: Int, offset: Int)
    }

    struct Transaction {
        let type: String
        let invoice: String?
        let description: String?
        let paymentHash: String
        let amountMsats: Int64
        let feesPaidMsats: Int64
        let createdAt: Int64
        let settledAt: Int64?
    }

    enum Response {
        case balance(msats: Int64)
        case payInvoice(preimage: String, feesPaidMsats: Int64?)
        case makeInvoice(invoice: String, paymentHash: String)
        case lookupInvoice(Transaction)
        case listTransactions([Transaction])
        case getInfo(alias: String?, methods: [String], notifications: [String])
    }

    /// Inspect a wallet service's kind 13194 info event for its supported encryption.
    /// Picks NIP-44 only if the wallet explicitly advertises `nip44_v2`; otherwise
    /// falls back to NIP-04, which the NIP-47 spec defines as the legacy default.
    /// Matches the Android client. Sending NIP-44 to a NIP-04-only wallet causes
    /// the wallet's handler to choke (often surfacing as `INTERNAL` errors), so
    /// we err on the conservative side here — the response-side decrypt has a
    /// fallback path either way.
    static func parseInfoEncryption(_ event: NostrEvent) -> Encryption {
        let tag = event.tags.first { $0.count >= 2 && $0[0] == "encryption" }
        if let tag {
            let schemes = tag[1].split(separator: " ").map { $0.lowercased() }
            if schemes.contains("nip44_v2") { return .nip44 }
        }
        return .nip04
    }

    // MARK: - Build request event

    /// Build a signed kind 23194 request event for the given connection.
    /// `encryption` is determined by the connection (negotiated from the wallet's info event).
    static func buildRequestEvent(connection: NwcConnection, request: Request) throws -> NostrEvent {
        let json = jsonForRequest(request)
        let walletPubkeyHex = Hex.encode(connection.walletServicePubkey)

        let encrypted: String
        var tags: [[String]] = [["p", walletPubkeyHex]]
        switch connection.encryption {
        case .nip44:
            let convKey = try Nip44.getConversationKey(privkey32: connection.clientSecret,
                                                       peerXonlyPubkey32: connection.walletServicePubkey)
            encrypted = try Nip44.encrypt(plaintext: json, conversationKey: convKey)
            tags.append(["encryption", "nip44_v2"])
        case .nip04:
            let shared = try Nip04.sharedSecret(privkey32: connection.clientSecret,
                                                peerXonlyPubkey32: connection.walletServicePubkey)
            encrypted = try Nip04.encrypt(json, sharedSecret: shared)
        }

        return try NostrEvent.sign(
            privkey32: connection.clientSecret,
            pubkey: Hex.encode(connection.clientPubkey),
            kind: requestKind,
            createdAt: Int(Date().timeIntervalSince1970),
            tags: tags,
            content: encrypted
        )
    }

    private static func jsonForRequest(_ request: Request) -> String {
        let dict: [String: Any]
        switch request {
        case .getBalance:
            dict = ["method": "get_balance", "params": [String: Any]()]
        case .getInfo:
            dict = ["method": "get_info", "params": [String: Any]()]
        case .payInvoice(let bolt11):
            dict = ["method": "pay_invoice", "params": ["invoice": bolt11]]
        case .makeInvoice(let amount, let description):
            dict = ["method": "make_invoice",
                    "params": ["amount": amount, "description": description]]
        case .lookupInvoice(let hash):
            dict = ["method": "lookup_invoice", "params": ["payment_hash": hash]]
        case .listTransactions(let limit, let offset):
            dict = ["method": "list_transactions",
                    "params": ["limit": limit, "offset": offset]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: - Parse response event

    /// Decrypt and parse a kind 23195 response event. Auto-detects NIP-04 (has `?iv=`)
    /// vs NIP-44; on mismatch tries the other scheme as a fallback.
    static func parseResponseEvent(connection: NwcConnection, event: NostrEvent) throws -> Response {
        let plaintext = try decryptContent(connection: connection, content: event.content)
        guard let data = plaintext.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WalletError.decodeFailed("invalid JSON")
        }

        if let err = obj["error"] as? [String: Any] {
            let code = err["code"] as? String ?? "UNKNOWN"
            let msg = err["message"] as? String ?? "Unknown error"
            throw WalletError.rpcError(code: code, message: msg)
        }

        let resultType = obj["result_type"] as? String ?? ""
        let result = obj["result"] as? [String: Any] ?? [:]

        switch resultType {
        case "get_balance":
            let bal = (result["balance"] as? Int64) ?? Int64((result["balance"] as? Int) ?? 0)
            return .balance(msats: bal)
        case "pay_invoice":
            let preimage = result["preimage"] as? String ?? ""
            let fees = (result["fees_paid"] as? Int64) ?? (result["fees_paid"] as? Int).map(Int64.init)
            return .payInvoice(preimage: preimage, feesPaidMsats: fees)
        case "make_invoice":
            return .makeInvoice(
                invoice: result["invoice"] as? String ?? "",
                paymentHash: result["payment_hash"] as? String ?? ""
            )
        case "lookup_invoice":
            return .lookupInvoice(transaction(from: result))
        case "list_transactions":
            let txs = (result["transactions"] as? [[String: Any]] ?? []).map(transaction(from:))
            return .listTransactions(txs)
        case "get_info":
            return .getInfo(
                alias: result["alias"] as? String,
                methods: result["methods"] as? [String] ?? [],
                notifications: result["notifications"] as? [String] ?? []
            )
        default:
            throw WalletError.decodeFailed("unknown result_type \(resultType)")
        }
    }

    private static func transaction(from o: [String: Any]) -> Transaction {
        Transaction(
            type: o["type"] as? String ?? "outgoing",
            invoice: o["invoice"] as? String,
            description: o["description"] as? String,
            paymentHash: o["payment_hash"] as? String ?? "",
            amountMsats: (o["amount"] as? Int64) ?? Int64((o["amount"] as? Int) ?? 0),
            feesPaidMsats: (o["fees_paid"] as? Int64) ?? Int64((o["fees_paid"] as? Int) ?? 0),
            createdAt: (o["created_at"] as? Int64) ?? Int64((o["created_at"] as? Int) ?? 0),
            settledAt: (o["settled_at"] as? Int64) ?? (o["settled_at"] as? Int).map(Int64.init)
        )
    }

    private static func decryptContent(connection: NwcConnection, content: String) throws -> String {
        let looksLikeNip04 = content.contains("?iv=")
        if looksLikeNip04 {
            do {
                let shared = try Nip04.sharedSecret(privkey32: connection.clientSecret,
                                                    peerXonlyPubkey32: connection.walletServicePubkey)
                return try Nip04.decrypt(content, sharedSecret: shared)
            } catch {
                let convKey = try Nip44.getConversationKey(privkey32: connection.clientSecret,
                                                           peerXonlyPubkey32: connection.walletServicePubkey)
                return try Nip44.decrypt(payload: content, conversationKey: convKey)
            }
        } else {
            do {
                let convKey = try Nip44.getConversationKey(privkey32: connection.clientSecret,
                                                           peerXonlyPubkey32: connection.walletServicePubkey)
                return try Nip44.decrypt(payload: content, conversationKey: convKey)
            } catch {
                let shared = try Nip04.sharedSecret(privkey32: connection.clientSecret,
                                                    peerXonlyPubkey32: connection.walletServicePubkey)
                return try Nip04.decrypt(content, sharedSecret: shared)
            }
        }
    }
}
