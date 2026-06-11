import Foundation

/// CLINK noffer kind-21001 RPC client (payer side).
///
/// Spec: https://github.com/shocknet/CLINK/blob/main/specs/clink-offers.md
///
/// Flow:
///   1. Build a JSON request payload with the offer id and (when needed) the
///      amount in sats.
///   2. NIP-44 encrypt the payload to the offer's service pubkey.
///   3. Sign + publish a kind-21001 event tagged `["p", servicePubkey]` and
///      `["clink_version","1"]` on the relay carried in the noffer's TLV 1.
///   4. Subscribe to kind-21001 on the same relay, filtered to events from the
///      service tagged for us. Decrypt the first response and parse it as either
///      `{bolt11}` (success) or `{error,code,…}` (typed failure → `NofferError`).
///
/// The caller pays the returned bolt11 via `WalletStore.payInvoice`.
@MainActor
enum NofferClient {

    /// Request an invoice for `noffer`, following a `code: 3` "expired/moved"
    /// response to its `latest` offer once (per spec).
    static func requestInvoice(
        noffer: NofferData,
        keypair: Keypair,
        amountSats: Int64?,
        description: String? = nil,
        zapRequest: String? = nil,
        timeout: TimeInterval = 30,
        allowRetry: Bool = true
    ) async throws -> String {
        do {
            return try await requestInvoiceOnce(
                noffer: noffer, keypair: keypair, amountSats: amountSats,
                description: description, zapRequest: zapRequest, timeout: timeout
            )
        } catch let err as NofferError where allowRetry && err.code == 3 {
            // Expired or moved — if the service handed us a replacement, decode
            // it and retry exactly once against the new offer.
            guard let latest = err.latest, let updated = try? Noffer.decode(latest) else { throw err }
            return try await requestInvoice(
                noffer: updated, keypair: keypair, amountSats: amountSats,
                description: description, zapRequest: zapRequest, timeout: timeout, allowRetry: false
            )
        }
    }

    private static func requestInvoiceOnce(
        noffer: NofferData,
        keypair: Keypair,
        amountSats: Int64?,
        description: String?,
        zapRequest: String?,
        timeout: TimeInterval
    ) async throws -> String {
        guard !keypair.privkey.isEmpty,
              let priv = Hex.decode(keypair.privkey), priv.count == 32,
              let peer = Hex.decode(noffer.pubkey), peer.count == 32 else {
            throw NofferError(code: 0, message: "Sign in with a key that can sign to pay an offer.")
        }
        let convKey = try Nip44.getConversationKey(privkey32: priv, peerXonlyPubkey32: peer)

        // Build the encrypted request payload. amount_sats is required for
        // Spontaneous/Variable offers; harmless to include for Fixed.
        var payload: [String: Any] = ["offer": noffer.offerId]
        if let amountSats, amountSats > 0 { payload["amount_sats"] = amountSats }
        if let description, !description.isEmpty { payload["description"] = String(description.prefix(100)) }
        if let zapRequest, !zapRequest.isEmpty { payload["zap"] = zapRequest }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let plaintext = String(data: data, encoding: .utf8) else {
            throw NofferError(code: 0, message: "Could not build the offer request.")
        }
        let ciphertext = try Nip44.encrypt(plaintext: plaintext, conversationKey: convKey)

        let event = try await Signer.sign(
            keypair: keypair,
            kind: 21001,
            tags: [["p", noffer.pubkey], ["clink_version", "1"]],
            content: ciphertext
        )

        let relay = noffer.relay
        let servicePubkey = noffer.pubkey

        // Subscribe BEFORE publishing so a fast response isn't raced away. 5s
        // grace on `since` covers slight clock skew with the service.
        let sub = RelayPool.subscribe(
            relays: [relay],
            filter: NostrFilter(
                kinds: [21001],
                authors: [servicePubkey],
                pTags: [keypair.pubkey],
                since: Int(Date().timeIntervalSince1970) - 5
            ),
            id: "noffer-\(UUID().uuidString.prefix(8))"
        )
        defer { sub.cancel() }

        let publishTask = Task { _ = await RelayPool.publish(event: event, to: [relay], timeout: 8) }
        defer { publishTask.cancel() }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for await (responseEvent, _) in sub.events {
                    if Task.isCancelled { break }
                    // `authors` already guards this server-side; defend against
                    // relays that ignore filters.
                    guard responseEvent.pubkey == servicePubkey else { continue }
                    guard let json = try? Nip44.decrypt(payload: responseEvent.content, conversationKey: convKey),
                          let parsed = NofferResponse.parse(json) else { continue }
                    if let bolt11 = parsed.bolt11, !bolt11.isEmpty {
                        return bolt11
                    }
                    if parsed.code != nil || (parsed.error != nil) {
                        throw NofferError(
                            code: parsed.code ?? 0,
                            message: parsed.error ?? "The offer request failed.",
                            range: parsed.range,
                            latest: parsed.latest
                        )
                    }
                    // Unrecognised payload — keep listening; maybe a stale event.
                }
                throw NofferError(code: 0, message: "The offer request failed.")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw NofferError(code: 0, message: "The offer request timed out. The recipient's service may be offline.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw NofferError(code: 0, message: "The offer request failed.")
            }
            return result
        }
    }
}
