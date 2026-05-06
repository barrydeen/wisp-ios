import Foundation

/// Orchestrates the NIP-57 zap send flow: lnurl resolve → kind 9734 zap request →
/// LNURL callback for bolt11 → pay via active wallet. Records `paymentHash → recipient`
/// to UserDefaults so transaction history can show who got zapped.
@MainActor
enum ZapSender {

    enum Failure: Error, LocalizedError {
        case noLightningAddress
        case lnurlUnreachable
        case nostrZapsNotSupported
        case amountOutOfRange(minSats: Int64, maxSats: Int64)
        case invoiceFetchFailed
        case noWallet
        case payFailed(String)

        var errorDescription: String? {
            switch self {
            case .noLightningAddress: "Recipient has no lightning address"
            case .lnurlUnreachable: "Could not reach lightning provider"
            case .nostrZapsNotSupported: "Recipient does not support nostr zaps"
            case .amountOutOfRange(let min, let max): "Amount out of range (\(min)–\(max) sats)"
            case .invoiceFetchFailed: "Could not fetch invoice"
            case .noWallet: "No wallet connected"
            case .payFailed(let reason): "Payment failed: \(reason)"
            }
        }
    }

    /// Send a zap from `keypair` to `recipientPubkey`, optionally tagging an event id.
    /// `relayHints` are preferred relays to put in the receipt's relays tag (e.g. live stream chat).
    /// `extraTags` are additional zap-request tags (e.g. `["a", "30311:host:dTag"]` for stream zaps).
    static func sendZap(
        keypair: Keypair,
        wallet: WalletStore,
        recipientPubkey: String,
        recipientLud16: String?,
        eventId: String?,
        amountSats: Int64,
        message: String = "",
        relayHints: [String] = [],
        extraTags: [[String]] = [],
        isAnonymous: Bool = false,
        isPrivate: Bool = false
    ) async -> Result<Void, Failure> {
        guard let lud16 = recipientLud16, lud16.contains("@") else {
            return .failure(.noLightningAddress)
        }
        guard let payInfo = await Nip57.resolveLud16(lud16) else {
            return .failure(.lnurlUnreachable)
        }
        guard payInfo.allowsNostr else {
            return .failure(.nostrZapsNotSupported)
        }
        let amountMsats = amountSats * 1000
        if amountMsats < payInfo.minSendable || amountMsats > payInfo.maxSendable {
            return .failure(.amountOutOfRange(minSats: payInfo.minSendable / 1000, maxSats: payInfo.maxSendable / 1000))
        }

        // Receipt routing: for private zaps, route exclusively to the sender's DM inbox
        // relays so the receipt is not visible in public feeds. Otherwise use the
        // recipient's read relays + our scored relays. Cap at 5.
        var relays: [String] = []
        relays.append(contentsOf: relayHints)
        if isPrivate {
            let dmRelays = RelaySettingsRepository.shared.dmRelays
            relays.append(contentsOf: dmRelays.isEmpty ? ["wss://relay.damus.io"] : dmRelays)
        } else {
            let recipientReads = await RelayListRepository.shared.getReadRelays(recipientPubkey)
            relays.append(contentsOf: recipientReads)
            if let scoreboard = RelayScoreBoard.load(pubkey: keypair.pubkey) {
                relays.append(contentsOf: scoreboard.scoredRelays.prefix(5).map(\.url))
            }
        }
        var seen = Set<String>()
        let dedupedRelays = relays.filter { seen.insert($0).inserted }.prefix(5)
        let finalRelays = dedupedRelays.isEmpty
            ? ["wss://relay.damus.io", "wss://nos.lol"]
            : Array(dedupedRelays)

        // Build + sign the kind 9734 zap request via the Signer facade
        // (works for both local-key and NIP-46 remote-signer accounts).
        let zapRequest: NostrEvent
        do {
            zapRequest = try await Nip57.buildZapRequest(
                keypair: keypair,
                recipientPubkey: recipientPubkey,
                eventId: eventId,
                amountMsats: amountMsats,
                relays: finalRelays,
                lnurl: lud16,
                message: message,
                extraTags: extraTags + (NostrEvent.clientTagIfEnabled().map { [$0] } ?? []),
                isAnonymous: isAnonymous,
                isPrivate: isPrivate
            )
        } catch {
            return .failure(.payFailed(error.localizedDescription))
        }

        guard let bolt11 = await Nip57.fetchInvoice(callback: payInfo.callback, amountMsats: amountMsats, zapRequest: zapRequest) else {
            return .failure(.invoiceFetchFailed)
        }

        let decodedBolt = Bolt11.decode(bolt11)
        let paymentHash = decodedBolt?.paymentHash ?? ""

        // Record recipient → payment hash for transaction history display.
        if !paymentHash.isEmpty {
            recordZapRecipient(paymentHash: paymentHash, recipientPubkey: recipientPubkey)
        }

        switch await wallet.payInvoice(bolt11) {
        case .success:
            // Optimistic engagement bump: payment is irreversible at this
            // point and the relay-broadcast kind-9735 receipt can take
            // several seconds to reach the engagement query. Show the
            // count + zapper now; the inbound receipt is deduped against
            // this same `paymentHash` so it doesn't double-count.
            if let eventId, !paymentHash.isEmpty {
                let zapperPubkey = isAnonymous ? "" : keypair.pubkey
                await MainActor.run {
                    EngagementRepository.shared.applyOptimisticZap(
                        eventId: eventId,
                        paymentHash: paymentHash,
                        sats: amountSats,
                        zapperPubkey: zapperPubkey,
                        message: message
                    )
                }
            }
            return .success(())
        case .failure(let err):
            return .failure(.payFailed(err.localizedDescription))
        }
    }

    // MARK: - Recipient persistence

    private static let recipientsKey = "wisp_zap_recipients"
    private static let maxEntries = 500

    static func recipient(forPaymentHash hash: String) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: recipientsKey) as? [String: String]
        return map?[hash]
    }

    static func recordZapRecipient(paymentHash: String, recipientPubkey: String) {
        var map = (UserDefaults.standard.dictionary(forKey: recipientsKey) as? [String: String]) ?? [:]
        if map[paymentHash] == recipientPubkey { return }
        map[paymentHash] = recipientPubkey
        // Trim FIFO. Plain dict has no order, so when over cap we drop arbitrary keys.
        // Acceptable: ZapSender only uses this for "who got my last few zaps" display.
        while map.count > maxEntries {
            if let first = map.keys.first { map.removeValue(forKey: first) }
        }
        UserDefaults.standard.set(map, forKey: recipientsKey)
    }
}
