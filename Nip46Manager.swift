import Foundation

/// Runtime singleton holding the currently-active `Nip46Client` for the
/// signed-in account, plus the high-level connection flows (bunker URI paste,
/// nostrconnect:// QR/copy). UI code reaches for `Nip46Manager.shared` rather
/// than constructing clients directly.
@MainActor
final class Nip46Manager {

    static let shared = Nip46Manager()

    /// The client for the currently-active account, if it's a remote-signed
    /// account. `nil` for local accounts and before login restore.
    private(set) var activeClient: Nip46Client?
    private(set) var activeSession: Nip46Session?

    private init() {}

    /// Returns true if the active account is using a remote signer.
    var isRemoteAccountActive: Bool { activeClient != nil }

    // MARK: - Lifecycle

    /// Restore the saved session for `pubkey` (if any) and start its relay
    /// listener. Called from app launch when the active keypair is detected
    /// to be a remote-signer account. No-op if a client is already attached.
    func restoreSession(pubkey: String) async -> Bool {
        if let active = activeSession, active.userPubkey == pubkey, activeClient != nil {
            return true
        }
        guard let session = Nip46SessionStore.load(pubkey: pubkey),
              let priv = Hex.decode(session.appPrivkeyHex), priv.count == 32 else {
            return false
        }
        let client = Nip46Client(
            appPriv32: priv,
            appPubkey: session.appPubkey,
            signerPubkey: session.signerPubkey,
            relays: session.relays
        )
        await client.startListening()
        self.activeClient = client
        self.activeSession = session
        return true
    }

    /// Tear down the active session (e.g. on logout). Does NOT delete the
    /// persisted session — call `Nip46SessionStore.delete(pubkey:)` for that.
    func clearActive() async {
        if let client = activeClient { await client.close() }
        activeClient = nil
        activeSession = nil
    }

    // MARK: - bunker:// flow

    /// Connect from a `bunker://` URI (Clave, Primal, Amber expose these).
    /// Generates fresh ephemeral app keys, performs the `connect` +
    /// `get_public_key` handshake, persists the session, and installs the
    /// resulting client as the active client.
    /// - Returns: the user's real pubkey on success.
    func connectBunker(uri: String) async throws -> String {
        guard let parsed = Nip46.parseBunker(uri) else {
            throw Nip46.NipError.invalidBunkerUri(uri)
        }
        guard !parsed.relays.isEmpty else { throw Nip46.NipError.noRelays }

        // Tear down any prior session before opening fresh sockets. If we
        // skip this, the previous client's three per-relay loops stay alive
        // and the new client's REQ subscription can't get through on relays
        // that throttle concurrent connections from one IP — the signer's
        // response then lands on the *old* subscription (different p-tag,
        // so it's silently dropped) and the new `get_public_key` times out.
        await clearActive()

        let appPriv = Schnorr.randomPrivkey()
        let appPubData = try Schnorr.xonlyPubkey(privkey32: appPriv)
        let appPubHex = Hex.encode(appPubData)

        let client = Nip46Client(
            appPriv32: appPriv,
            appPubkey: appPubHex,
            signerPubkey: parsed.signerPubkey,
            relays: parsed.relays
        )
        await client.startListening()

        // `connect` handshake. When the bunker URI carries a `secret`, the
        // signer MUST echo that exact secret in the response (per spec) —
        // a hostile relay can otherwise inject a kind-24133 event from
        // some other pubkey ahead of the legitimate signer's response,
        // and (since our REQ already author-filters to `parsed.signerPubkey`)
        // the wrong actor would still pass the encryption check if they
        // hold the same shared-secret derivation. Accept "ack" too — older
        // Amber and rust-nostr's default reply with that.
        do {
            let ack = try await client.connect(secret: parsed.secret)
            if let secret = parsed.secret {
                let trimmed = ack.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed == secret || trimmed.lowercased() == "ack" else {
                    await client.close()
                    throw Nip46.NipError.rpcError("Signer did not echo the connect secret (got: \(trimmed))")
                }
            }
        } catch {
            await client.close()
            throw error
        }

        let userPubkey: String
        do {
            userPubkey = try await client.getPublicKey()
        } catch {
            await client.close()
            throw error
        }

        let session = Nip46Session(
            userPubkey: userPubkey,
            appPrivkeyHex: Hex.encode(appPriv),
            appPubkey: appPubHex,
            signerPubkey: parsed.signerPubkey,
            relays: parsed.relays,
            bunkerURI: uri,
            createdAt: Int(Date().timeIntervalSince1970)
        )
        Nip46SessionStore.save(session)

        self.activeClient = client
        self.activeSession = session
        return userPubkey
    }

    // MARK: - nostrconnect:// flow

    /// In-flight nostrconnect handshake state. The view holds one of these
    /// while the QR code is on screen, then awaits `complete()`.
    @MainActor
    final class NostrConnectPending {
        let uri: String
        let appPriv: Data
        let appPubkey: String
        let secret: String
        let relays: [String]
        let appName: String
        fileprivate var listenerClient: Nip46Client?

        fileprivate init(uri: String, appPriv: Data, appPubkey: String,
                         secret: String, relays: [String], appName: String) {
            self.uri = uri
            self.appPriv = appPriv
            self.appPubkey = appPubkey
            self.secret = secret
            self.relays = relays
            self.appName = appName
        }
    }

    /// Default relay set for nostrconnect URIs. Order matters — `relay.primal.net`
    /// is placed first because Primal iOS subscribes to whichever relay appears
    /// first in the URI for the inbound `connect` request, and putting it later
    /// makes the handshake slower or hang. Compatible signers we test against
    /// today: Clave, Primal iOS, Amber.
    static let defaultNostrConnectRelays: [String] = [
        "wss://relay.primal.net",
        "wss://relay.damus.io",
        "wss://nos.lol"
    ]

    /// Prepare a nostrconnect:// session: fresh app keys, fresh secret, a URI
    /// to display as a QR or copy-paste. Caller hands the URI to the user, then
    /// calls `awaitNostrConnectHandshake(...)` to wait for the signer to scan.
    func prepareNostrConnect(
        relays: [String] = Nip46Manager.defaultNostrConnectRelays,
        appName: String = "Wisp",
        appURL: String? = "https://wisp.app"
    ) throws -> NostrConnectPending {
        guard !relays.isEmpty else { throw Nip46.NipError.noRelays }
        let appPriv = Schnorr.randomPrivkey()
        let appPubData = try Schnorr.xonlyPubkey(privkey32: appPriv)
        let appPubHex = Hex.encode(appPubData)
        let secret = Nip46.randomSecret16Hex()

        // Order relays: primal first, then the rest (matches deadcat behavior
        // for Primal iOS compatibility).
        var ordered: [String] = []
        for r in relays {
            if r.contains("relay.primal.net") { ordered.insert(r, at: 0) }
            else { ordered.append(r) }
        }

        let uri = Nip46.buildNostrconnectURI(
            appPubkey: appPubHex,
            relays: ordered,
            secret: secret,
            name: appName,
            appURL: appURL,
            perms: ["sign_event:1", "sign_event:6", "sign_event:7", "nip04_encrypt", "nip04_decrypt", "nip44_encrypt", "nip44_decrypt"]
        )
        return NostrConnectPending(uri: uri, appPriv: appPriv, appPubkey: appPubHex,
                                   secret: secret, relays: ordered, appName: appName)
    }

    /// Wait for the signer to scan the URI and respond. Returns the user's
    /// pubkey on success and installs the client + persists the session.
    func awaitNostrConnectHandshake(_ pending: NostrConnectPending) async throws -> String {
        // Tear down any prior session before opening fresh sockets — see
        // `connectBunker` for the rationale (orphaned per-relay loops eat
        // the connection budget and the next handshake silently times out).
        await clearActive()

        // Phase 1: subscribe (no signer pubkey known yet) and watch for the
        // first kind-24133 event addressed to us. Accept either secret-echo
        // or "ack" as a successful connect response.
        let signerPubkey = try await listenForHandshake(pending: pending)

        // Phase 2: build a real client now that we know the signer pubkey,
        // ask for the user's pubkey, persist, install.
        let client = Nip46Client(
            appPriv32: pending.appPriv,
            appPubkey: pending.appPubkey,
            signerPubkey: signerPubkey,
            relays: pending.relays
        )
        await client.startListening()
        let userPubkey: String
        do {
            userPubkey = try await client.getPublicKey()
        } catch {
            await client.close()
            throw error
        }
        let session = Nip46Session(
            userPubkey: userPubkey,
            appPrivkeyHex: Hex.encode(pending.appPriv),
            appPubkey: pending.appPubkey,
            signerPubkey: signerPubkey,
            relays: pending.relays,
            bunkerURI: Nip46.buildBunkerURI(signerPubkey: signerPubkey, relays: pending.relays),
            createdAt: Int(Date().timeIntervalSince1970)
        )
        Nip46SessionStore.save(session)
        self.activeClient = client
        self.activeSession = session
        return userPubkey
    }

    private func listenForHandshake(pending: NostrConnectPending) async throws -> String {
        let appPriv = pending.appPriv
        let appPub = pending.appPubkey
        let secret = pending.secret
        let relays = pending.relays
        let urls = relays.compactMap(RelayPool.wsURL)
        guard !urls.isEmpty else { throw Nip46.NipError.noRelays }

        // Filter: kind 24133 events p-tagged to our app pubkey. We don't know
        // the signer pubkey yet, so we leave `authors` open.
        let filter = NostrFilter(kinds: [Nip46.kind], pTags: [appPub], limit: 0)
        let req = "[\"REQ\",\"nip46-hs-\(String(UUID().uuidString.prefix(8)).lowercased())\",\(filter.toJSON())]"

        return try await withThrowingTaskGroup(of: String?.self) { group in
            // Per-relay listener: returns nil on socket error (don't fail
            // the whole group; another relay may still complete).
            for url in urls {
                group.addTask {
                    return await Self.listenForHandshakeOnRelay(
                        url: url, req: req, appPriv: appPriv, secret: secret
                    )
                }
            }
            // Timeout sentinel: throws to surface as the failure when no
            // relay produces a real signer pubkey in time. If the group is
            // cancelled (e.g. a relay returned a pubkey first), exit silently
            // — sleep throws CancellationError; we swallow that.
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(Nip46.nostrconnectHandshakeTimeoutSeconds))
                } catch {
                    return nil
                }
                throw Nip46.NipError.timeout(method: "nostrconnect handshake")
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let pubkey = result { return pubkey }
                // socket dead — keep waiting for the next responder
            }
            throw Nip46.NipError.timeout(method: "nostrconnect handshake")
        }
    }

    private static func listenForHandshakeOnRelay(
        url: URL, req: String, appPriv: Data, secret: String
    ) async -> String? {
        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: url)
        ws.resume()
        // `URLSessionWebSocketTask.receive()` does NOT respect Swift task
        // cancellation natively — without this handler, cancelling the parent
        // task (e.g. user dismisses the sheet) would leave receive() pending
        // until the relay drops the socket. The cancellation handler tears
        // the socket down so receive() throws and we exit cleanly.
        return await withTaskCancellationHandler {
            do { try await ws.send(.string(req)) } catch {
                ws.cancel(with: .normalClosure, reason: nil)
                return nil
            }
            defer { ws.cancel(with: .normalClosure, reason: nil) }
            while !Task.isCancelled {
                do {
                    let msg = try await ws.receive()
                    guard case .string(let text) = msg else { continue }
                    guard let data = text.data(using: .utf8),
                          let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = arr.first as? String else { continue }
                    if type == "EVENT", arr.count >= 3,
                       let obj = arr[2] as? [String: Any],
                       let event = NostrEvent(json: obj),
                       event.kind == Nip46.kind {
                        let signerPubkey = event.pubkey.lowercased()
                        let plaintext: String
                        do {
                            plaintext = try Nip46.decryptFromSigner(
                                payload: event.content,
                                appPriv32: appPriv,
                                signerPubkeyHex: signerPubkey
                            )
                        } catch {
                            continue
                        }
                        guard let decoded = Nip46.decodeResponse(plaintext) else { continue }
                        if decoded.error != nil { continue }
                        let result = decoded.result ?? ""
                        // Accept secret-echo (Clave, Primal, recent Amber) or
                        // "ack" (older Amber, rust-nostr default).
                        if result == secret || result.lowercased() == "ack" {
                            return signerPubkey
                        }
                    }
                } catch {
                    return nil
                }
            }
            return nil
        } onCancel: {
            ws.cancel(with: .normalClosure, reason: nil)
        }
    }
}
