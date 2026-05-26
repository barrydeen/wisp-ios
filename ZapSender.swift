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

        // Receipt routing.
        //
        // Private (DIP-03) zaps: receipt must reach a relay both sides can read.
        // Pull *both* the recipient's kind-10050 (peer fallback to kind-10002
        // inbox) AND the sender's own kind-10050. The LNURL operator publishes
        // the receipt to whatever URLs we put in the zap request's `relays` tag,
        // so this is also what the recipient observes. Fail if either side has
        // nothing — silently leaking the receipt to a default public relay
        // would defeat the whole privacy story. Cap at 8 to fit both sides.
        //
        // Public + anonymous zaps: keep the existing recipient-reads + sender-
        // scored routing. Receipts are discoverable on public infrastructure.
        var relays: [String] = []
        relays.append(contentsOf: relayHints)
        if isPrivate {
            // DIP-03 needs the target event id to derive the deterministic
            // ephemeral key. Profile zaps and a-tag stream zaps can't.
            guard eventId != nil else { return .failure(.nostrZapsNotSupported) }
            // Prefer DM relays for receipt routing (kind-10050 on both sides),
            // but never refuse to send when they're empty — DIP-03's sender
            // anonymity property holds even when the receipt lands on public
            // relays (the outer kind-9734 author is the ephemeral pubkey, the
            // inner kind-9733 is encrypted to the recipient). Fall back to
            // recipient's NIP-65 inbox + user's own write relays + scoreboard
            // — matches PrivateReplyPublisher.
            var recipientDm = await PeerRelayResolver.resolveDmTargets(pubkey: recipientPubkey)
            if recipientDm.isEmpty {
                recipientDm = await RelayListRepository.shared.getReadRelays(recipientPubkey)
            }
            var ownDm = RelaySettingsRepository.shared.dmRelays
            if ownDm.isEmpty {
                ownDm = await RelayListRepository.shared.getWriteRelays(keypair.pubkey)
                if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
                    for entry in board.scoredRelays.prefix(5) {
                        if !ownDm.contains(entry.url) { ownDm.append(entry.url) }
                    }
                }
            }
            relays.append(contentsOf: recipientDm)
            relays.append(contentsOf: ownDm)
        } else {
            let recipientReads = await RelayListRepository.shared.getReadRelays(recipientPubkey)
            relays.append(contentsOf: recipientReads)
            if let scoreboard = RelayScoreBoard.load(pubkey: keypair.pubkey) {
                relays.append(contentsOf: scoreboard.scoredRelays.prefix(5).map(\.url))
            }
        }
        var seen = Set<String>()
        let cap = isPrivate ? 8 : 5
        let dedupedRelays = relays.filter { seen.insert($0).inserted }.prefix(cap)
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
                // For DIP-03 private zaps the sender locally knows they sent it
                // (the encryption is *for outside observers*, not the sender's
                // own UI), so we attribute the optimistic bump to ourselves.
                // For plain anonymous zaps we deliberately leave the zapper
                // pubkey empty — those are anonymous to *us* on the card too.
                let zapperPubkey = (isAnonymous && !isPrivate) ? "" : keypair.pubkey
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
    private static let sendersKey = "wisp_zap_senders"
    private static let maxEntries = 500

    static func recipient(forPaymentHash hash: String) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: recipientsKey) as? [String: String]
        return map?[hash]
    }

    /// Pubkey of whoever zapped the active user, keyed by the receipt's
    /// bolt11 payment hash. Populated by `recordIncomingAttribution(from:)`
    /// when a kind-9735 receipt with `p` = my pubkey is observed by the
    /// notifications subscription. Read by `WalletTransactionRow` so an
    /// incoming wallet transaction that matches a known zap receipt can
    /// render the zapper's avatar + display name instead of a generic
    /// "Received" label.
    static func sender(forPaymentHash hash: String) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: sendersKey) as? [String: String]
        return map?[hash]
    }

    static func recordZapRecipient(paymentHash: String, recipientPubkey: String) {
        persistMapping(key: recipientsKey, paymentHash: paymentHash, pubkey: recipientPubkey)
    }

    static func recordZapSender(paymentHash: String, senderPubkey: String) {
        persistMapping(key: sendersKey, paymentHash: paymentHash, pubkey: senderPubkey)
    }

    /// Pull the zapper's pubkey out of a kind-9735 receipt's embedded
    /// kind-9734 description, decode the bolt11 tag for its payment hash,
    /// and persist the mapping. No-op if either piece is missing —
    /// receipts are produced by remote LSPs and occasionally arrive with
    /// malformed descriptions or non-standard bolt11 encodings.
    static func recordIncomingAttribution(from receipt: NostrEvent) {
        guard receipt.kind == 9735 else { return }
        guard let zapper = Nip57.zapperPubkey(receipt: receipt) else { return }
        guard let bolt11 = receipt.tags.first(where: { $0.first == "bolt11" })?.dropFirst().first else { return }
        guard let paymentHash = Bolt11.decode(String(bolt11))?.paymentHash, !paymentHash.isEmpty else { return }
        recordZapSender(paymentHash: paymentHash, senderPubkey: zapper)
    }

    private static func persistMapping(key: String, paymentHash: String, pubkey: String) {
        var map = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        if map[paymentHash] == pubkey { return }
        map[paymentHash] = pubkey
        // Trim FIFO. Plain dict has no order, so when over cap we drop arbitrary keys.
        // Acceptable: this is only used for "who got / sent my last few zaps" display.
        while map.count > maxEntries {
            if let first = map.keys.first { map.removeValue(forKey: first) }
        }
        UserDefaults.standard.set(map, forKey: key)
    }
}
