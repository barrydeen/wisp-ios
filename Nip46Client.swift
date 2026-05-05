import Foundation

/// Long-lived NIP-46 client. Holds a per-relay WebSocket subscription, decrypts
/// incoming kind-24133 events from the signer, and routes responses back to
/// `sendRequest` callers by request `id`. One instance per active remote
/// session — see `Nip46Manager`.
///
/// The client is an `actor` so the pending-request map and listener bookkeeping
/// don't need ad-hoc locks. The actual relay sockets run on detached tasks and
/// hop back into actor context via `handleResponse(...)`.
actor Nip46Client {

    // MARK: - Config

    /// Ephemeral app keys generated at session creation. Persistent across app
    /// restarts (saved by `Nip46Session`).
    let appPriv32: Data
    let appPubkey: String   // hex
    /// Remote signer's pubkey. Identifies the responder. Hex.
    let signerPubkey: String
    /// Relay URLs the session communicates over. Order matters for some signer
    /// implementations (Primal iOS expects `relay.primal.net` to be present).
    let relays: [String]

    // MARK: - State

    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private var listenerTasks: [Task<Void, Never>] = []
    private var isClosed = false
    /// Event ids we've already routed to a continuation in this session.
    /// A relay reconnect can re-deliver an EVENT we already saw and a
    /// hostile relay can replay an old signed-event response — without
    /// this dedupe an old `sign_event` response could resolve a fresh
    /// `pending[id]` entry. Bounded set: we trim down to the most recent
    /// 256 ids so memory doesn't grow over a long session.
    private var seenEventIds: Set<String> = []
    private var seenEventOrder: [String] = []
    /// Subscription `since` floor — set when `startListening` runs so the
    /// REQ filter ignores any event the relay was holding from before
    /// this session began. `limit: 0` already covers most relays, but
    /// the explicit `since` is a belt-and-suspenders against relays
    /// that interpret limit:0 as "unlimited".
    private var subscriptionSince: Int = 0

    // MARK: - Init

    init(appPriv32: Data, appPubkey: String, signerPubkey: String, relays: [String]) {
        self.appPriv32 = appPriv32
        self.appPubkey = appPubkey.lowercased()
        self.signerPubkey = signerPubkey.lowercased()
        self.relays = relays
    }

    /// Spin up the relay subscription. Must be called once before sending any
    /// request, otherwise responses will never arrive. Idempotent.
    func startListening() {
        guard listenerTasks.isEmpty, !isClosed else { return }
        // Pin `since` to the moment listening starts so any old responses
        // a relay may have cached for our app pubkey don't get replayed
        // into our pending map.
        subscriptionSince = Int(Date().timeIntervalSince1970)
        let urls = relays.compactMap(RelayPool.wsURL)
        for url in urls {
            let task: Task<Void, Never> = Task { [weak self] in
                await self?.runRelayLoop(url: url)
            }
            listenerTasks.append(task)
        }
    }

    /// Tear down all sockets and cancel any pending requests. Awaits the
    /// listener tasks so the caller knows the per-relay sockets have actually
    /// been released by the time this returns — critical when a fresh
    /// `Nip46Client` is about to open new sockets to the same relays.
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        let tasks = listenerTasks
        listenerTasks.removeAll()
        for task in tasks { task.cancel() }
        let cancelled = pending
        pending.removeAll()
        for (_, cont) in cancelled {
            cont.resume(throwing: Nip46.NipError.notConnected)
        }
        for task in tasks { await task.value }
    }

    // MARK: - RPC

    /// Send a single RPC and wait for the matching response. Encrypts with NIP-44 v2.
    func sendRequest(method: String, params: [String], timeout: TimeInterval = Nip46.rpcTimeoutSeconds) async throws -> String {
        if isClosed { throw Nip46.NipError.notConnected }
        let id = Nip46.randomRequestId()
        let plaintext = Nip46.makeRequestJSON(id: id, method: method, params: params)
        let cipher = try Nip46.encryptToSigner(plaintext: plaintext, appPriv32: appPriv32, signerPubkeyHex: signerPubkey)
        let createdAt = Int(Date().timeIntervalSince1970)
        let event = try NostrEvent.sign(
            privkey32: appPriv32,
            pubkey: appPubkey,
            kind: Nip46.kind,
            createdAt: createdAt,
            tags: [["p", signerPubkey]],
            content: cipher
        )

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            Task { await self.beginRequest(id: id, event: event, method: method, timeout: timeout, cont: cont) }
        }
    }

    private func beginRequest(id: String,
                              event: NostrEvent,
                              method: String,
                              timeout: TimeInterval,
                              cont: CheckedContinuation<String, Error>) {
        if isClosed {
            cont.resume(throwing: Nip46.NipError.notConnected)
            return
        }
        pending[id] = cont
        let relayList = self.relays
        Task.detached {
            _ = await RelayPool.publish(event: event, to: relayList, timeout: 6)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            await self?.failPending(id: id, error: Nip46.NipError.timeout(method: method))
        }
    }

    private func failPending(id: String, error: Error) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    private func resolvePending(id: String, with result: Result<String, Error>) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        switch result {
        case .success(let s): cont.resume(returning: s)
        case .failure(let e): cont.resume(throwing: e)
        }
    }

    // MARK: - Listener

    private func runRelayLoop(url: URL) async {
        let urlString = url.absoluteString
        let req = "[\"REQ\",\"nip46-\(String(UUID().uuidString.prefix(8)).lowercased())\",\(filterJSON())]"
        var attempt = 0

        while !Task.isCancelled, !isClosed {
            let session = URLSession(configuration: .default)
            let ws = session.webSocketTask(with: url)
            ws.resume()

            // Force-cancel the WebSocket on Task cancellation. Without this,
            // `ws.receive()` ignores Swift task cancellation and keeps blocking
            // until the relay drops the socket — leaving zombie sockets after
            // `close()` and starving the next session of relay connections.
            await withTaskCancellationHandler {
                do { try await ws.send(.string(req)) } catch {
                    return
                }

                while !Task.isCancelled {
                    do {
                        let msg = try await ws.receive()
                        guard case .string(let text) = msg else { continue }
                        guard let data = text.data(using: .utf8),
                              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                              let type = arr.first as? String else { continue }
                        if type == "EVENT", arr.count >= 3,
                           let obj = arr[2] as? [String: Any],
                           let event = NostrEvent(json: obj) {
                            attempt = 0
                            processIncoming(event: event, relay: urlString)
                        } else if type == "CLOSED" {
                            return
                        }
                        // EOSE intentionally ignored — keep the subscription alive.
                    } catch {
                        return
                    }
                }
            } onCancel: {
                ws.cancel(with: .normalClosure, reason: nil)
            }

            ws.cancel(with: .normalClosure, reason: nil)
            if Task.isCancelled { break }
            let delay = min(30.0, pow(2.0, Double(attempt)))
            attempt += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func filterJSON() -> String {
        let f = NostrFilter(
            kinds: [Nip46.kind],
            authors: [signerPubkey],
            pTags: [appPubkey],
            limit: 0,
            since: subscriptionSince > 0 ? subscriptionSince : nil
        )
        return f.toJSON()
    }

    private func processIncoming(event: NostrEvent, relay: String) {
        guard event.kind == Nip46.kind, event.pubkey.lowercased() == signerPubkey else { return }
        // Drop events we've already routed once. A relay reconnect can
        // re-stream an event we just consumed; without this an old
        // sign_event response would resolve the next request we make.
        guard seenEventIds.insert(event.id).inserted else { return }
        seenEventOrder.append(event.id)
        if seenEventOrder.count > 256 {
            let drop = seenEventOrder.removeFirst()
            seenEventIds.remove(drop)
        }
        let plaintext: String
        do {
            plaintext = try Nip46.decryptFromSigner(payload: event.content, appPriv32: appPriv32, signerPubkeyHex: signerPubkey)
        } catch {
            return
        }
        guard let decoded = Nip46.decodeResponse(plaintext) else { return }
        if let err = decoded.error {
            resolvePending(id: decoded.id, with: .failure(Nip46.NipError.rpcError(err)))
        } else if let result = decoded.result {
            resolvePending(id: decoded.id, with: .success(result))
        } else {
            resolvePending(id: decoded.id, with: .failure(Nip46.NipError.malformedResponse))
        }
    }

    // MARK: - High-level RPC helpers

    /// Send `connect`. Per spec, params are `[<signer_pubkey_hex>, <secret?>, <perms?>]`.
    /// Both `"ack"` and the URI's secret echoed back are valid success responses;
    /// we accept either.
    @discardableResult
    func connect(secret: String?, perms: [String] = []) async throws -> String {
        var params: [String] = [signerPubkey]
        if let secret { params.append(secret) }
        if !perms.isEmpty { params.append(perms.joined(separator: ",")) }
        return try await sendRequest(method: Nip46.Method.connect, params: params)
    }

    func getPublicKey() async throws -> String {
        let result = try await sendRequest(method: Nip46.Method.getPublicKey, params: [])
        let lower = result.lowercased()
        guard lower.count == 64, Hex.decode(lower) != nil else {
            throw Nip46.NipError.malformedResponse
        }
        return lower
    }

    /// Sign an unsigned event template. The signer returns a fully-signed
    /// event JSON string.
    func signEvent(unsigned: [String: Any]) async throws -> NostrEvent {
        guard let data = try? JSONSerialization.data(withJSONObject: unsigned),
              let json = String(data: data, encoding: .utf8) else {
            throw Nip46.NipError.malformedResponse
        }
        let result = try await sendRequest(method: Nip46.Method.signEvent, params: [json])
        guard let event = NostrEvent.fromJSON(result) else {
            throw Nip46.NipError.malformedResponse
        }
        return event
    }

    func nip04Encrypt(peerPubkeyHex: String, plaintext: String) async throws -> String {
        try await sendRequest(method: Nip46.Method.nip04Encrypt, params: [peerPubkeyHex, plaintext])
    }

    func nip04Decrypt(peerPubkeyHex: String, ciphertext: String) async throws -> String {
        try await sendRequest(method: Nip46.Method.nip04Decrypt, params: [peerPubkeyHex, ciphertext])
    }

    func nip44Encrypt(peerPubkeyHex: String, plaintext: String) async throws -> String {
        try await sendRequest(method: Nip46.Method.nip44Encrypt, params: [peerPubkeyHex, plaintext])
    }

    func nip44Decrypt(peerPubkeyHex: String, ciphertext: String) async throws -> String {
        try await sendRequest(method: Nip46.Method.nip44Decrypt, params: [peerPubkeyHex, ciphertext])
    }

    func ping() async throws -> String {
        try await sendRequest(method: Nip46.Method.ping, params: [])
    }
}
