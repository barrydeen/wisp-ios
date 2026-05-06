import Foundation

/// A relay-side NIP-42 challenge that the user hasn't pre-approved. Surfaced via
/// `RelayPool.pendingAuth` so the UI can prompt for approval. Once approved, the
/// caller flips the relay's `auth` flag in `RelaySettingsRepository`; subsequent
/// connects will auto-sign through `RelayPool.authSigner`.
struct PendingAuthRequest: Sendable, Identifiable {
    let relayUrl: String
    let challenge: String
    var id: String { relayUrl }
}

enum RelayPool {

    /// `URLSession.webSocketTask(with:)` throws an uncatchable Objective-C exception when
    /// given a URL whose scheme isn't `ws`/`wss`. `URL(string:)` happily parses something
    /// like `"relay.example.com"` into a non-nil URL with no scheme, so we have to filter
    /// them out ourselves before handing them to URLSession.
    nonisolated static func wsURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss"
        else { return nil }
        return url
    }

    // MARK: - NIP-42 hooks (set once at app start from MainView.task)

    /// Returns a signed kind-22242 AUTH event for the given (relay, challenge), or
    /// nil if signing failed / no keypair is available.
    nonisolated(unsafe) static var authSigner: (@Sendable (_ relayUrl: String, _ challenge: String) -> NostrEvent?)?

    /// Returns true if the relay is pre-approved for AUTH (auth flag on its
    /// `GeneralRelay` entry in `RelaySettingsRepository`).
    nonisolated(unsafe) static var authApprovalCheck: (@Sendable (_ relayUrl: String) -> Bool)?

    private static let _pendingAuth = AsyncStream<PendingAuthRequest>.makeStream(bufferingPolicy: .bufferingNewest(8))

    /// Stream of NIP-42 challenges from relays that are not pre-approved. The
    /// MainView task drains this and presents `RelayAuthApprovalSheet`.
    static var pendingAuth: AsyncStream<PendingAuthRequest> { _pendingAuth.stream }

    private static func emitPendingAuth(url: String, challenge: String) {
        // No-op: AUTH is handled silently via authSigner whenever a keypair is available.
    }

    /// Handle an incoming `["AUTH", challenge]` frame. If auto-approve is enabled (the
    /// default) or the relay is individually approved, signs and sends back an AUTH
    /// response immediately. Returns `true` only when an AUTH event was actually signed
    /// and sent — callers use this to know whether to replay their original REQ/EVENT.
    @discardableResult
    fileprivate static func respondToAuthChallenge(challenge: String, urlString: String,
                                                   ws: URLSessionWebSocketTask) async -> Bool {
        let autoApprove = UserDefaults.standard.object(forKey: "wisp_settings_auto_approve_relay_auth") as? Bool ?? true
        guard (autoApprove || authApprovalCheck?(urlString) == true),
              let event = authSigner?(urlString, challenge) else { return false }
        let payload = "[\"AUTH\",\(event.toJSON())]"
        do {
            try await ws.send(.string(payload))
            return true
        } catch {
            return false
        }
    }

    static func query(
        relays: [String],
        filter: NostrFilter,
        timeout: TimeInterval = 8,
        waitForAllRelays: Bool = false
    ) async -> [NostrEvent] {
        let urls = relays.compactMap(Self.wsURL)
        guard !urls.isEmpty else { return [] }

        let collector = EventCollector()
        let total = urls.count

        let tasks = urls.map { url in
            Task { await streamInto(url: url, filter: filter, timeout: timeout, collector: collector) }
        }

        // The default fast path breaks 1.5s after the *first* relay's EOSE — fine
        // for feed-style queries where any one relay's reply is good enough, but
        // wrong for "rare event might live on any single relay in the set" lookups
        // (e.g. NIP-78 wallet backup search). When `waitForAllRelays` is set we
        // wait for every relay to EOSE or the overall timeout, whichever comes
        // first, so a slow relay holding the only copy of the event gets a chance
        // to respond before its task is cancelled.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if waitForAllRelays {
                if await collector.allEose(of: total) { break }
            } else {
                if await collector.hasEose { break }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        if !waitForAllRelays, await collector.hasEose {
            // Short grace for stragglers on the fast path. With waitForAllRelays
            // the loop above already gave every relay until the deadline, so an
            // additional grace just delays without adding coverage.
            try? await Task.sleep(for: .seconds(1.5))
        }

        for task in tasks { task.cancel() }
        return await collector.events
    }

    private static func streamInto(
        url: URL,
        filter: NostrFilter,
        timeout: TimeInterval,
        collector: EventCollector
    ) async {
        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: url)
        ws.resume()

        let subId = String(UUID().uuidString.prefix(8)).lowercased()
        let req = "[\"REQ\",\"\(subId)\",\(filter.toJSON())]"

        do { try await ws.send(.string(req)) } catch {
            ws.cancel(with: .normalClosure, reason: nil)
            return
        }

        let timeoutTask = Task {
            try await Task.sleep(for: .seconds(timeout))
            ws.cancel(with: .normalClosure, reason: nil)
        }

        var lastChallenge: String?
        var didResendAfterAuth = false
        let urlString = url.absoluteString

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
                    await collector.add(event)
                    let eid = event.id
                    await MainActor.run {
                        NoteSourceTracker.shared.record(eventId: eid, relayUrl: urlString)
                    }
                } else if type == "EOSE" {
                    await collector.markEose()
                    break
                } else if type == "AUTH", arr.count >= 2, let challenge = arr[1] as? String {
                    lastChallenge = challenge
                    let didAuth = await respondToAuthChallenge(challenge: challenge, urlString: urlString, ws: ws)
                    // AUTH-required relays drop the pre-auth REQ. Replay it once on this socket.
                    if didAuth, !didResendAfterAuth {
                        didResendAfterAuth = true
                        try? await ws.send(.string(req))
                    }
                } else if type == "CLOSED", arr.count >= 3,
                          let reason = arr[2] as? String,
                          reason.lowercased().contains("auth-required") {
                    if let challenge = lastChallenge { emitPendingAuth(url: urlString, challenge: challenge) }
                    break
                }
            } catch {
                break
            }
        }

        timeoutTask.cancel()
        try? await ws.send(.string("[\"CLOSE\",\"\(subId)\"]"))
        ws.cancel(with: .normalClosure, reason: nil)
    }
}

private actor EventCollector {
    private var _events: [NostrEvent] = []
    private var seen = Set<String>()
    private var eoseCount = 0

    var events: [NostrEvent] { _events }
    var hasEose: Bool { eoseCount > 0 }
    func allEose(of total: Int) -> Bool { eoseCount >= total }

    func add(_ event: NostrEvent) {
        if seen.insert(event.id).inserted {
            _events.append(event)
        }
    }

    func markEose() { eoseCount += 1 }
}

// MARK: - Streaming query (one-shot, per-relay filters)

/// One (relay, filters) pair for `RelayPool.stream`. Multiple filters are sent as a
/// single multi-filter `REQ` to that relay — matching Android's `OutboxRouter` and
/// avoiding multiple sockets to the same host when an author chunk exceeds the limit.
struct RelayQuery: Sendable {
    let relayUrl: String
    let filters: [NostrFilter]

    init(relayUrl: String, filters: [NostrFilter]) {
        self.relayUrl = relayUrl
        self.filters = filters
    }

    /// Convenience for the common single-filter case.
    init(relayUrl: String, filter: NostrFilter) {
        self.relayUrl = relayUrl
        self.filters = [filter]
    }
}

private actor RelayCounter {
    private var remaining: Int
    init(_ n: Int) { remaining = n }
    /// Returns true when this was the last relay to finish.
    func decrement() -> Bool {
        remaining -= 1
        return remaining <= 0
    }
}

extension RelayPool {

    /// Streaming `query`: yields events as they arrive across all relays. Each socket runs to its own
    /// EOSE (or per-relay timeout); the stream finishes when every socket has closed or the global
    /// `timeout` fires. No global EOSE-quorum cutoff — a fast empty relay must not cancel a slow one.
    static func stream(
        queries: [RelayQuery],
        timeout: TimeInterval = 15
    ) -> AsyncStream<(event: NostrEvent, relayUrl: String)> {
        AsyncStream { continuation in
            guard !queries.isEmpty else {
                continuation.finish()
                return
            }

            let dedupe = DedupeBox()
            let sockets = SocketBag()
            let urls = queries.compactMap { q -> (URL, [NostrFilter])? in
                guard !q.filters.isEmpty,
                      let url = Self.wsURL(q.relayUrl) else { return nil }
                return (url, q.filters)
            }
            let counter = RelayCounter(urls.count)

            let relayTasks: [Task<Void, Never>] = urls.map { (url, filters) in
                Task {
                    await streamYield(
                        url: url,
                        filters: filters,
                        timeout: timeout,
                        dedupe: dedupe,
                        continuation: continuation,
                        sockets: sockets
                    )
                    if await counter.decrement() {
                        continuation.finish()
                    }
                }
            }

            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeout))
                await sockets.cancelAll()
                continuation.finish()
            }

            continuation.onTermination = { _ in
                timeoutTask.cancel()
                for t in relayTasks { t.cancel() }
                Task { await sockets.cancelAll() }
            }
        }
    }

    private static func streamYield(
        url: URL,
        filters: [NostrFilter],
        timeout: TimeInterval,
        dedupe: DedupeBox,
        continuation: AsyncStream<(event: NostrEvent, relayUrl: String)>.Continuation,
        sockets: SocketBag
    ) async {
        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: url)
        ws.resume()
        await sockets.add(ws)

        let subId = String(UUID().uuidString.prefix(8)).lowercased()
        let filterJoined = filters.map { $0.toJSON() }.joined(separator: ",")
        let req = "[\"REQ\",\"\(subId)\",\(filterJoined)]"

        do { try await ws.send(.string(req)) } catch {
            ws.cancel(with: .normalClosure, reason: nil)
            return
        }

        let perRelayKiller = Task {
            try? await Task.sleep(for: .seconds(timeout))
            ws.cancel(with: .normalClosure, reason: nil)
        }

        var lastChallenge: String?
        var didResendAfterAuth = false
        let urlString = url.absoluteString

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
                    if await dedupe.insert(event.id) {
                        let eid = event.id
                        await MainActor.run {
                            NoteSourceTracker.shared.record(eventId: eid, relayUrl: urlString)
                        }
                        continuation.yield((event, urlString))
                    }
                } else if type == "EOSE" {
                    break
                } else if type == "AUTH", arr.count >= 2, let challenge = arr[1] as? String {
                    lastChallenge = challenge
                    let didAuth = await respondToAuthChallenge(challenge: challenge, urlString: urlString, ws: ws)
                    if didAuth, !didResendAfterAuth {
                        didResendAfterAuth = true
                        try? await ws.send(.string(req))
                    }
                } else if type == "CLOSED", arr.count >= 3,
                          let reason = arr[2] as? String,
                          reason.lowercased().contains("auth-required") {
                    if let challenge = lastChallenge { emitPendingAuth(url: urlString, challenge: challenge) }
                    break
                }
            } catch {
                break
            }
        }

        perRelayKiller.cancel()
        try? await ws.send(.string("[\"CLOSE\",\"\(subId)\"]"))
        ws.cancel(with: .normalClosure, reason: nil)
    }
}

private actor SocketBag {
    private var sockets: [URLSessionWebSocketTask] = []
    private var cancelled = false
    func add(_ ws: URLSessionWebSocketTask) {
        if cancelled { ws.cancel(with: .normalClosure, reason: nil); return }
        sockets.append(ws)
    }
    func cancelAll() {
        cancelled = true
        for ws in sockets { ws.cancel(with: .normalClosure, reason: nil) }
        sockets.removeAll()
    }
}

// MARK: - Live subscriptions (persistent)

/// A long-lived multi-relay subscription. Events from any relay are deduplicated by id
/// and yielded to `events`. The subscription stays open after EOSE for live delivery.
final class RelaySubscription: @unchecked Sendable {
    let id: String
    let events: AsyncStream<(event: NostrEvent, relayUrl: String)>
    private let continuation: AsyncStream<(event: NostrEvent, relayUrl: String)>.Continuation
    private let dedupe = DedupeBox()
    private var listenerTasks: [Task<Void, Never>] = []
    private var liveSockets: [UUID: URLSessionWebSocketTask] = [:]
    private var reqText: String = ""
    private let lock = NSLock()

    init(id: String) {
        self.id = id
        var cont: AsyncStream<(event: NostrEvent, relayUrl: String)>.Continuation!
        self.events = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func add(listener: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        listenerTasks.append(listener)
    }

    /// Stash the REQ frame so `resendREQ` can re-broadcast it. Only the simple
    /// `subscribe(relays:filter:id:)` path uses this — multi-filter outbox subs
    /// don't need refresh and leave it empty.
    func setREQ(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        reqText = text
    }

    func registerSocket(_ ws: URLSessionWebSocketTask) -> UUID {
        let key = UUID()
        lock.lock(); defer { lock.unlock() }
        liveSockets[key] = ws
        return key
    }

    func unregisterSocket(_ key: UUID) {
        lock.lock(); defer { lock.unlock() }
        liveSockets.removeValue(forKey: key)
    }

    /// Re-send the stored REQ on every currently-live socket. Defeats silent
    /// server-side subscription drops that the WebSocket itself doesn't surface
    /// as an error. Best-effort: dead sockets fail and the auto-reconnect loop
    /// will re-issue the REQ on the replacement.
    func resendREQ() async {
        let (req, sockets): (String, [URLSessionWebSocketTask]) = {
            lock.lock(); defer { lock.unlock() }
            return (reqText, Array(liveSockets.values))
        }()
        guard !req.isEmpty else { return }
        for ws in sockets {
            try? await ws.send(.string(req))
        }
    }

    func deliver(event: NostrEvent, relayUrl: String) async {
        if await dedupe.insert(event.id) {
            continuation.yield((event, relayUrl))
        }
    }

    func cancel() {
        lock.lock()
        let tasks = listenerTasks
        listenerTasks.removeAll()
        liveSockets.removeAll()
        lock.unlock()
        for t in tasks { t.cancel() }
        continuation.finish()
    }
}

private actor DedupeBox {
    private var seen = Set<String>()
    func insert(_ id: String) -> Bool { seen.insert(id).inserted }
}

extension RelayPool {

    /// Open a persistent multi-relay subscription. The returned `RelaySubscription` keeps its
    /// WebSockets open after EOSE and yields incoming `EVENT` messages on `.events`.
    /// Auto-reconnects with exponential backoff on socket errors so long-running consumers
    /// (e.g. live-stream chat) survive transient network drops. A server-sent `CLOSED`
    /// frame is treated as terminal and stops reconnecting.
    static func subscribe(relays: [String], filter: NostrFilter, id: String) -> RelaySubscription {
        let sub = RelaySubscription(id: id)
        let urls = relays.compactMap(Self.wsURL)
        let req = "[\"REQ\",\"\(id)\",\(filter.toJSON())]"
        let closeMsg = "[\"CLOSE\",\"\(id)\"]"
        sub.setREQ(req)
        for url in urls {
            let task = Task {
                var attempt = 0
                outer: while !Task.isCancelled {
                    let session = URLSession(configuration: .default)
                    let ws = session.webSocketTask(with: url)
                    ws.resume()

                    do { try await ws.send(.string(req)) } catch {
                        ws.cancel(with: .normalClosure, reason: nil)
                        if Task.isCancelled { break outer }
                        let delay = min(30.0, pow(2.0, Double(attempt)))
                        attempt += 1
                        try? await Task.sleep(for: .seconds(delay))
                        continue
                    }

                    let socketKey = sub.registerSocket(ws)
                    var serverClosed = false
                    var lastChallenge: String?
                    var didResendAfterAuth = false
                    let urlString = url.absoluteString
                    inner: while !Task.isCancelled {
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
                                let eid = event.id
                                await MainActor.run {
                                    NoteSourceTracker.shared.record(eventId: eid, relayUrl: urlString)
                                }
                                await sub.deliver(event: event, relayUrl: urlString)
                            } else if type == "CLOSED" {
                                let reason = (arr.count >= 3 ? (arr[2] as? String ?? "") : "").lowercased()
                                if reason.contains("auth-required") {
                                    // NIP-42 relays send CLOSED auth-required for the pre-AUTH REQ
                                    // (often interleaved with the AUTH challenge frame on the same
                                    // socket). DO NOT tear down — the AUTH branch below will sign
                                    // and replay the REQ, opening a fresh server-side sub on the
                                    // same connection. Killing the task here was silently dropping
                                    // every AUTH-required relay (auth.nostr1.com, inbox.nostr.wine, …)
                                    // for the rest of the session.
                                    if let challenge = lastChallenge {
                                        emitPendingAuth(url: urlString, challenge: challenge)
                                    }
                                    // Allow re-replay of the REQ on the next AUTH frame.
                                    didResendAfterAuth = false
                                } else {
                                    serverClosed = true
                                    break inner
                                }
                            } else if type == "AUTH", arr.count >= 2, let challenge = arr[1] as? String {
                                lastChallenge = challenge
                                let didAuth = await respondToAuthChallenge(challenge: challenge, urlString: urlString, ws: ws)
                                if didAuth, !didResendAfterAuth {
                                    didResendAfterAuth = true
                                    try? await ws.send(.string(req))
                                }
                            }
                            // EOSE intentionally ignored: keep listening for live events.
                        } catch {
                            break inner
                        }
                    }

                    sub.unregisterSocket(socketKey)
                    if Task.isCancelled {
                        try? await ws.send(.string(closeMsg))
                        ws.cancel(with: .normalClosure, reason: nil)
                        break outer
                    }
                    ws.cancel(with: .normalClosure, reason: nil)
                    if serverClosed { break outer }

                    let delay = min(30.0, pow(2.0, Double(attempt)))
                    attempt += 1
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
            sub.add(listener: task)
        }
        return sub
    }

    /// Persistent variant of `stream` for outbox-routed feeds. Opens one socket per
    /// `RelayQuery`, sends a multi-filter REQ (so a relay with >200 routed authors
    /// gets one connection and one REQ, not N), keeps the socket alive after EOSE,
    /// and auto-reconnects on transient errors. The home feed uses this so new
    /// notes flow in continuously after the initial backlog finishes streaming.
    static func subscribe(queries: [RelayQuery], id: String) -> RelaySubscription {
        let sub = RelaySubscription(id: id)
        let closeMsg = "[\"CLOSE\",\"\(id)\"]"
        for query in queries {
            guard !query.filters.isEmpty,
                  let url = Self.wsURL(query.relayUrl) else { continue }
            let filterJoined = query.filters.map { $0.toJSON() }.joined(separator: ",")
            let req = "[\"REQ\",\"\(id)\",\(filterJoined)]"
            let task = Task {
                var attempt = 0
                outer: while !Task.isCancelled {
                    let session = URLSession(configuration: .default)
                    let ws = session.webSocketTask(with: url)
                    ws.resume()

                    do { try await ws.send(.string(req)) } catch {
                        ws.cancel(with: .normalClosure, reason: nil)
                        if Task.isCancelled { break outer }
                        let delay = min(30.0, pow(2.0, Double(attempt)))
                        attempt += 1
                        try? await Task.sleep(for: .seconds(delay))
                        continue
                    }

                    var serverClosed = false
                    var lastChallenge: String?
                    var didResendAfterAuth = false
                    let urlString = url.absoluteString
                    inner: while !Task.isCancelled {
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
                                let eid = event.id
                                await MainActor.run {
                                    NoteSourceTracker.shared.record(eventId: eid, relayUrl: urlString)
                                }
                                await sub.deliver(event: event, relayUrl: urlString)
                            } else if type == "CLOSED" {
                                let reason = (arr.count >= 3 ? (arr[2] as? String ?? "") : "").lowercased()
                                if reason.contains("auth-required") {
                                    // NIP-42 relays send CLOSED auth-required for the pre-AUTH REQ
                                    // (often interleaved with the AUTH challenge frame on the same
                                    // socket). DO NOT tear down — the AUTH branch below will sign
                                    // and replay the REQ, opening a fresh server-side sub on the
                                    // same connection. Killing the task here was silently dropping
                                    // every AUTH-required relay (auth.nostr1.com, inbox.nostr.wine, …)
                                    // for the rest of the session.
                                    if let challenge = lastChallenge {
                                        emitPendingAuth(url: urlString, challenge: challenge)
                                    }
                                    // Allow re-replay of the REQ on the next AUTH frame.
                                    didResendAfterAuth = false
                                } else {
                                    serverClosed = true
                                    break inner
                                }
                            } else if type == "AUTH", arr.count >= 2, let challenge = arr[1] as? String {
                                lastChallenge = challenge
                                let didAuth = await respondToAuthChallenge(challenge: challenge, urlString: urlString, ws: ws)
                                if didAuth, !didResendAfterAuth {
                                    didResendAfterAuth = true
                                    try? await ws.send(.string(req))
                                }
                            }
                            // EOSE intentionally ignored: keep listening for live events.
                        } catch {
                            break inner
                        }
                    }

                    if Task.isCancelled {
                        try? await ws.send(.string(closeMsg))
                        ws.cancel(with: .normalClosure, reason: nil)
                        break outer
                    }
                    ws.cancel(with: .normalClosure, reason: nil)
                    if serverClosed { break outer }

                    let delay = min(30.0, pow(2.0, Double(attempt)))
                    attempt += 1
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
            sub.add(listener: task)
        }
        return sub
    }

    /// One-shot publish: send an EVENT to each relay, await server reply (OK / NOTICE) or timeout.
    /// Returns the set of relay URLs that responded with OK.
    /// A hard timeout cancels the socket — `ws.receive()` can otherwise block past the deadline
    /// on relays that accept the connection but never send `OK` (some implementations drop OKs).
    @discardableResult
    static func publish(event: NostrEvent, to relays: [String], timeout: TimeInterval = 4) async -> [String] {
        let urls = relays.compactMap(Self.wsURL)
        guard !urls.isEmpty else { return [] }
        let payload = "[\"EVENT\",\(event.toJSON())]"

        return await withTaskGroup(of: String?.self) { group in
            for url in urls {
                group.addTask {
                    let session = URLSession(configuration: .default)
                    let ws = session.webSocketTask(with: url)
                    ws.resume()
                    let killer = Task {
                        try? await Task.sleep(for: .seconds(timeout))
                        ws.cancel(with: .normalClosure, reason: nil)
                    }
                    defer {
                        killer.cancel()
                        ws.cancel(with: .normalClosure, reason: nil)
                    }
                    do { try await ws.send(.string(payload)) } catch { return nil }
                    var lastChallenge: String?
                    var didResendAfterAuth = false
                    let urlString = url.absoluteString
                    while !Task.isCancelled {
                        do {
                            let msg = try await ws.receive()
                            if case .string(let text) = msg,
                               let data = text.data(using: .utf8),
                               let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                               let type = arr.first as? String {
                                if type == "OK", arr.count >= 3,
                                   let eventId = arr[1] as? String,
                                   eventId == event.id,
                                   let ok = arr[2] as? Bool {
                                    if ok { return urlString }
                                    let reason = (arr.count >= 4 ? (arr[3] as? String ?? "") : "").lowercased()
                                    if reason.hasPrefix("auth-required"), let challenge = lastChallenge {
                                        emitPendingAuth(url: urlString, challenge: challenge)
                                    }
                                    return nil
                                } else if type == "AUTH", arr.count >= 2, let challenge = arr[1] as? String {
                                    lastChallenge = challenge
                                    let didAuth = await respondToAuthChallenge(challenge: challenge, urlString: urlString, ws: ws)
                                    // AUTH-required relays drop the pre-auth EVENT. Replay once.
                                    if didAuth, !didResendAfterAuth {
                                        didResendAfterAuth = true
                                        try? await ws.send(.string(payload))
                                    }
                                }
                            }
                        } catch { return nil }
                    }
                    return nil
                }
            }
            var ok: [String] = []
            for await r in group { if let r { ok.append(r) } }
            return ok
        }
    }
}
