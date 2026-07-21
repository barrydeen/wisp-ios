import Foundation
#if DEBUG
import os
#endif

/// A relay-side NIP-42 challenge that the user hasn't pre-approved. Surfaced via
/// `RelayPool.pendingAuth` so the UI can prompt for approval. Once approved, the
/// caller flips the relay's `auth` flag in `RelaySettingsRepository`; subsequent
/// connects will auto-sign through `RelayPool.authSigner`.
struct PendingAuthRequest: Sendable, Identifiable {
    let relayUrl: String
    let challenge: String
    var id: String { relayUrl }
}

/// Public facade over the relay layer. Connection management lives in
/// `RelayConnectionPool` — one persistent, multiplexed WebSocket per relay,
/// reused across every `query`/`stream`/`subscribe` (these previously each
/// opened a brand-new `URLSession` + socket per relay per call, which during
/// scroll exhausted the OS network-flow budget and was the dominant cause of
/// jank). The public API here is unchanged so callers don't move.
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
    /// and sent — `RelayConn` uses this to know whether to replay its active REQs.
    @discardableResult
    static func respondToAuthChallenge(challenge: String, urlString: String,
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

    // MARK: - One-shot query (collect until EOSE / timeout)

    static func query(
        relays: [String],
        filter: NostrFilter,
        timeout: TimeInterval = 8,
        waitForAllRelays: Bool = false
    ) async -> [NostrEvent] {
        await queryDetailed(relays: relays, filter: filter, timeout: timeout, waitForAllRelays: waitForAllRelays).events
    }

    /// Like `query`, but also reports how many distinct relays sent EOSE — i.e. actually
    /// answered the REQ. Lets a caller distinguish "queried successfully, no such event"
    /// (`relaysResponded > 0`) from "couldn't reach anyone" (`== 0`), which matters before
    /// taking a destructive action on an apparent absence — e.g. auto-creating a replaceable
    /// list (kind 10050), where a fresh `createdAt` would clobber a list we merely failed to fetch.
    static func queryDetailed(
        relays: [String],
        filter: NostrFilter,
        timeout: TimeInterval = 8,
        waitForAllRelays: Bool = false
    ) async -> (events: [NostrEvent], relaysResponded: Int) {
        let urls = relays.compactMap(Self.wsURL)
        guard !urls.isEmpty else { return ([], 0) }

        let subId = "q-" + String(UUID().uuidString.prefix(8)).lowercased()
        let reqFrame = "[\"REQ\",\"\(subId)\",\(filter.toJSON())]"
        let relayReqs = urls.map { (url: $0, req: reqFrame) }
        let total = Set(urls.map(\.absoluteString)).count

        let collector = QueryCollector()
        let sink = RelaySink(
            onEvent: { event, _ in collector.add(event) },
            onEose: { _ in collector.markEose() }
        )
        await RelayConnectionPool.shared.register(subId: subId, relays: relayReqs, sink: sink)

        // Same cutoff semantics as before: fast path breaks shortly after the
        // first relay's EOSE; `waitForAllRelays` waits for every relay or the
        // deadline (rare-event lookups that may live on a single relay).
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if waitForAllRelays {
                if collector.eoseCount >= total { break }
            } else {
                if collector.eoseCount > 0 { break }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !waitForAllRelays, collector.eoseCount > 0 {
            try? await Task.sleep(for: .seconds(1.5))  // straggler grace
        }

        await RelayConnectionPool.shared.deregister(subId: subId)
        return (collector.events, collector.eoseCount)
    }

    // MARK: - Streaming query (one-shot, per-relay filters)

    /// Streaming `query`: yields events as they arrive across all relays, dedup'd
    /// by id. Finishes when every relay has EOSE'd or the global `timeout` fires.
    static func stream(
        queries: [RelayQuery],
        timeout: TimeInterval = 15
    ) -> AsyncStream<(event: NostrEvent, relayUrl: String)> {
        AsyncStream { continuation in
            let subId = "s-" + String(UUID().uuidString.prefix(8)).lowercased()
            var relayReqs: [(url: URL, req: String)] = []
            for q in queries {
                guard !q.filters.isEmpty, let url = Self.wsURL(q.relayUrl) else { continue }
                let joined = q.filters.map { $0.toJSON() }.joined(separator: ",")
                relayReqs.append((url, "[\"REQ\",\"\(subId)\",\(joined)]"))
            }
            guard !relayReqs.isEmpty else { continuation.finish(); return }
            let total = Set(relayReqs.map { $0.url.absoluteString }).count

            let dedupe = SyncDedupe()
            let eose = Counter()
            let sink = RelaySink(
                onEvent: { event, relay in
                    if dedupe.insert(event.id) { continuation.yield((event, relay)) }
                },
                onEose: { _ in
                    if eose.increment() >= total { continuation.finish() }
                }
            )

            Task { await RelayConnectionPool.shared.register(subId: subId, relays: relayReqs, sink: sink) }

            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeout))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                timeoutTask.cancel()
                Task { await RelayConnectionPool.shared.deregister(subId: subId) }
            }
        }
    }

    // MARK: - Live subscriptions (persistent)

    /// Open a persistent multi-relay subscription. Stays open after EOSE for live
    /// delivery; the connection pool re-issues the REQ automatically on reconnect
    /// and after NIP-42 AUTH. Cancel via `RelaySubscription.cancel()`.
    static func subscribe(relays: [String], filter: NostrFilter, id: String,
                          bypassConnectionCap: Bool = false) -> RelaySubscription {
        let sub = RelaySubscription(id: id)
        let reqFrame = "[\"REQ\",\"\(id)\",\(filter.toJSON())]"
        sub.setREQ(reqFrame)
        let relayReqs = relays.compactMap(Self.wsURL).map { (url: $0, req: reqFrame) }
        let sink = RelaySink(onEvent: { [weak sub] event, relay in
            sub?.deliver(event: event, relayUrl: relay)
        })
        Task { await RelayConnectionPool.shared.register(subId: id, relays: relayReqs, sink: sink,
                                                         bypassConnectionCap: bypassConnectionCap) }
        return sub
    }

    /// Persistent outbox-routed subscription: one multi-filter REQ per relay (so a
    /// relay with >200 routed authors gets one connection and one REQ). The home
    /// feed uses this.
    static func subscribe(queries: [RelayQuery], id: String) -> RelaySubscription {
        let sub = RelaySubscription(id: id)
        var relayReqs: [(url: URL, req: String)] = []
        for query in queries {
            guard !query.filters.isEmpty, let url = Self.wsURL(query.relayUrl) else { continue }
            let joined = query.filters.map { $0.toJSON() }.joined(separator: ",")
            relayReqs.append((url, "[\"REQ\",\"\(id)\",\(joined)]"))
        }
        let sink = RelaySink(onEvent: { [weak sub] event, relay in
            sub?.deliver(event: event, relayUrl: relay)
        })
        Task { await RelayConnectionPool.shared.register(subId: id, relays: relayReqs, sink: sink) }
        return sub
    }

    // MARK: - Publish

    /// Shared session for one-shot publishes. Publishing is low-volume and
    /// user-initiated (post / reaction / zap), so it stays a short-lived
    /// request-reply rather than going through the persistent pool — but it no
    /// longer spins up a fresh `URLSession` per relay per publish.
    private static let publishSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        return URLSession(configuration: cfg)
    }()

    /// One-shot publish: send an EVENT to each relay, await server reply (OK / NOTICE) or timeout.
    /// Returns the set of relay URLs that responded with OK.
    /// A hard timeout cancels the socket — `ws.receive()` can otherwise block past the deadline
    /// on relays that accept the connection but never send `OK` (some implementations drop OKs).
    /// `onAccept` fires per accepting relay before the URL is returned through the group, so
    /// `PostPublisher` can tick its `Broadcasting n/N` pill counter in real time.
    @discardableResult
    static func publish(
        event: NostrEvent,
        to relays: [String],
        timeout: TimeInterval = 4,
        onAccept: (@Sendable (String) -> Void)? = nil
    ) async -> [String] {
        let urls = relays.compactMap(Self.wsURL)
        guard !urls.isEmpty else { return [] }
        let payload = "[\"EVENT\",\(event.toJSON())]"

        return await withTaskGroup(of: String?.self) { group in
            for url in urls {
                group.addTask {
                    let ws = Self.publishSession.webSocketTask(with: url)
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
                                    if ok {
                                        onAccept?(urlString)
                                        return urlString
                                    }
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

// MARK: - RelayQuery

/// One (relay, filters) pair for `RelayPool.stream` / `subscribe(queries:)`.
/// Multiple filters are sent as a single multi-filter `REQ` to that relay —
/// matching Android's `OutboxRouter` and avoiding multiple sockets to one host
/// when an author chunk exceeds the limit.
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

// MARK: - RelaySubscription

/// A long-lived multi-relay subscription. Events from any relay are deduplicated
/// by id and yielded to `events`. The underlying sockets are owned by
/// `RelayConnectionPool`; cancelling sends `CLOSE` to each relay and detaches
/// this subscription's sink.
final class RelaySubscription: @unchecked Sendable {
    let id: String
    let events: AsyncStream<(event: NostrEvent, relayUrl: String)>
    private let continuation: AsyncStream<(event: NostrEvent, relayUrl: String)>.Continuation
    private let lock = NSLock()
    private var seen = Set<String>()
    private var reqText = ""
    private var cancelled = false

    init(id: String) {
        self.id = id
        var cont: AsyncStream<(event: NostrEvent, relayUrl: String)>.Continuation!
        self.events = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    /// Stash the REQ frame (only the simple `subscribe(relays:filter:id:)` path
    /// uses it for symmetry; the pool re-issues REQs on reconnect on its own).
    func setREQ(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        reqText = text
    }

    /// Deliver an incoming event, deduplicated across relays. Synchronous so the
    /// pool's receive loop can call it directly without spawning a task per event.
    func deliver(event: NostrEvent, relayUrl: String) {
        lock.lock()
        let isNew = seen.insert(event.id).inserted
        let live = !cancelled
        lock.unlock()
        if isNew && live { continuation.yield((event, relayUrl)) }
    }

    /// Re-broadcast the REQ on every live socket — defeats silent server-side
    /// subscription drops the WebSocket itself doesn't surface as an error.
    func resendREQ() async {
        await RelayConnectionPool.shared.resend(subId: id)
    }

    func cancel() {
        lock.lock()
        if cancelled { lock.unlock(); return }
        cancelled = true
        lock.unlock()
        continuation.finish()
        Task { await RelayConnectionPool.shared.deregister(subId: id) }
    }
}

// MARK: - Sync collectors (called directly from the pool's receive loop)

/// Lock-protected event collector for one-shot `query`. Dedupes by id.
private final class QueryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [NostrEvent] = []
    private var seen = Set<String>()
    private var _eose = 0

    func add(_ event: NostrEvent) {
        lock.lock(); defer { lock.unlock() }
        if seen.insert(event.id).inserted { _events.append(event) }
    }
    func markEose() {
        lock.lock(); defer { lock.unlock() }
        _eose += 1
    }
    var events: [NostrEvent] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }
    var eoseCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _eose
    }
}

/// Lock-protected id de-duplicator for `stream`.
private final class SyncDedupe: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<String>()
    func insert(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.insert(id).inserted
    }
}

/// Lock-protected EOSE counter for `stream`.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return n
    }
}

// MARK: - Connection pool (merged here so the wisp target's explicit
//          root-file membership picks it up without a project-file edit)

/// Sink the pool invokes when frames arrive for a registered subscription.
/// Reference type with `@Sendable` closures so a single sink can be shared
/// across every relay a subscription fans out to. Callbacks are invoked from
/// the owning `RelayConn` actor; do cheap, thread-safe work in them (the
/// existing consumers dedupe under a lock and yield to an `AsyncStream`).
final class RelaySink: @unchecked Sendable {
    let onEvent: @Sendable (_ event: NostrEvent, _ relayUrl: String) -> Void
    let onEose: @Sendable (_ relayUrl: String) -> Void
    let onClosed: @Sendable (_ relayUrl: String, _ reason: String) -> Void

    init(
        onEvent: @escaping @Sendable (_ event: NostrEvent, _ relayUrl: String) -> Void,
        onEose: @escaping @Sendable (_ relayUrl: String) -> Void = { _ in },
        onClosed: @escaping @Sendable (_ relayUrl: String, _ reason: String) -> Void = { _, _ in }
    ) {
        self.onEvent = onEvent
        self.onEose = onEose
        self.onClosed = onClosed
    }
}

/// One persistent, multiplexed WebSocket to a single relay. Every REQ for this
/// relay — feed, engagement, profiles, notifications, DMs — rides this one
/// connection, keyed by subscription id, instead of each opening its own
/// socket. A single receive loop demultiplexes incoming frames back to the
/// per-sub sinks; a single reconnect loop with backoff survives drops and
/// re-issues every active REQ on reconnect (and after NIP-42 AUTH).
actor RelayConn {
    let urlString: String
    private let url: URL
    private let session: URLSession
    private var ws: URLSessionWebSocketTask?
    private var connected = false
    /// subId -> (REQ frame to (re)send, sink to deliver frames to).
    private var subs: [String: (req: String, sink: RelaySink)] = [:]
    private var runLoop: Task<Void, Never>?
    private var attempt = 0
    /// Consecutive connect/receive failures with zero events in between.
    /// Drives the circuit breaker so a dead relay stops being re-dialed.
    private var consecutiveFailures = 0
    private(set) var lastActive = Date()

    init(url: URL, session: URLSession) {
        self.url = url
        self.urlString = url.absoluteString
        self.session = session
    }

    var subCount: Int { subs.count }

    func addSub(id: String, req: String, sink: RelaySink) {
        subs[id] = (req, sink)
        lastActive = Date()
        // If already connected, issue the REQ immediately; otherwise the run
        // loop will send it on (re)connect.
        if connected, let ws { Task { try? await ws.send(.string(req)) } }
        ensureRunLoop()
    }

    func removeSub(id: String) {
        guard subs[id] != nil else { return }
        subs.removeValue(forKey: id)
        lastActive = Date()
        if connected, let ws {
            let closeMsg = "[\"CLOSE\",\"\(id)\"]"
            Task { try? await ws.send(.string(closeMsg)) }
        }
    }

    /// Re-broadcast a sub's REQ on the live socket — defeats silent server-side
    /// subscription drops the WebSocket itself doesn't surface as an error.
    func resend(id: String) {
        guard connected, let ws, let sub = subs[id] else { return }
        Task { try? await ws.send(.string(sub.req)) }
    }

    /// Tear the connection down completely (pool eviction / shutdown).
    func shutdown() {
        runLoop?.cancel()
        runLoop = nil
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
        connected = false
        subs.removeAll()
    }

    private func ensureRunLoop() {
        guard runLoop == nil else { return }
        runLoop = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        while !Task.isCancelled {
            // Nothing to listen for — let the loop end; `addSub` restarts it.
            if subs.isEmpty { runLoop = nil; return }

            // Circuit breaker: after several straight failures, wait longer so a
            // dead/unreachable relay stops churning connect attempts.
            if consecutiveFailures >= 5 {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled || subs.isEmpty { runLoop = nil; return }
            }

            let socket = session.webSocketTask(with: url)
            ws = socket
            socket.resume()
            connected = true

            // (Re)issue every active REQ on this fresh socket.
            for (_, sub) in subs { try? await socket.send(.string(sub.req)) }

            let hadError = await receiveLoop(socket)
            connected = false
            ws = nil
            socket.cancel(with: .normalClosure, reason: nil)

            if Task.isCancelled || subs.isEmpty { runLoop = nil; return }

            if hadError {
                consecutiveFailures += 1
                let delay = min(30.0, pow(2.0, Double(attempt)))
                attempt += 1
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        runLoop = nil
    }

    /// Returns true if the socket ended on an error (so the caller backs off).
    private func receiveLoop(_ socket: URLSessionWebSocketTask) async -> Bool {
        var lastChallenge: String?
        while !Task.isCancelled {
            let msg: URLSessionWebSocketTask.Message
            do {
                msg = try await socket.receive()
            } catch {
                return true
            }
            guard case .string(let text) = msg,
                  let data = text.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let type = arr.first as? String else { continue }

            switch type {
            case "EVENT":
                guard arr.count >= 3,
                      let subId = arr[1] as? String,
                      let obj = arr[2] as? [String: Any],
                      let event = NostrEvent(json: obj),
                      let sub = subs[subId] else { continue }
                attempt = 0
                consecutiveFailures = 0
                lastActive = Date()
                let eid = event.id
                await MainActor.run { NoteSourceTracker.shared.record(eventId: eid, relayUrl: urlString) }
                sub.sink.onEvent(event, urlString)

            case "EOSE":
                guard arr.count >= 2, let subId = arr[1] as? String, let sub = subs[subId] else { continue }
                consecutiveFailures = 0
                sub.sink.onEose(urlString)

            case "CLOSED":
                guard arr.count >= 2, let subId = arr[1] as? String else { continue }
                let reason = arr.count >= 3 ? (arr[2] as? String ?? "") : ""
                if reason.lowercased().contains("auth-required") {
                    // NIP-42: don't tear the sub down — the AUTH branch replays
                    // the REQ on the same socket once we've signed the challenge.
                    continue
                }
                if let sub = subs[subId] {
                    sub.sink.onClosed(urlString, reason)
                    subs.removeValue(forKey: subId)
                }

            case "AUTH":
                guard arr.count >= 2, let challenge = arr[1] as? String else { continue }
                lastChallenge = challenge
                let didAuth = await RelayPool.respondToAuthChallenge(
                    challenge: challenge, urlString: urlString, ws: socket
                )
                if didAuth {
                    // Re-issue every REQ now that the connection is authed.
                    for (_, sub) in subs { try? await socket.send(.string(sub.req)) }
                }

            default:
                // OK / NOTICE / EOSE-for-unknown-sub — ignored on the sub path.
                _ = lastChallenge
                continue
            }
        }
        return false
    }
}

/// Process-wide pool of persistent relay connections. Replaces the old model
/// where every `RelayPool.query`/`subscribe` opened a brand-new `URLSession`
/// and WebSocket per relay — which, during scroll, exhausted the OS network-
/// flow budget (`NECP_CLIENT_ACTION_ADD_FLOW … [12: Cannot allocate memory]`)
/// and starved the main thread. Now one socket per relay is reused across all
/// subscriptions, total connections are capped, and dead relays are not
/// re-dialed forever.
actor RelayConnectionPool {
    static let shared = RelayConnectionPool()

    /// One session for every relay WebSocket. `URLSession` is heavyweight and
    /// meant to be long-lived; the old per-call instantiation was a big part of
    /// the resource blowup.
    private let session: URLSession

    /// Hard ceiling on simultaneous relay connections. The user's follows graph
    /// can route to hundreds of distinct relays; without a cap, scroll-time
    /// outbox routing opens a connection to every one. Idle connections are
    /// evicted LRU to stay under this. 96 holds the feed's relay set
    /// (`FeedViewModel.maxPoolRelays` = 72 + a couple indexer fallbacks) plus
    /// headroom for DM inbox / notification / transient profile-thread-quote
    /// scoped subs (most of which multiplex over the feed's relays anyway). This
    /// must stay comfortably above `maxPoolRelays` — otherwise the feed alone
    /// exceeds the cap and evicts its own relays as other subs register. Still
    /// orders of magnitude below the per-process network-flow limit the old
    /// per-call socket model blew past; the jank came from ephemeral churn, not
    /// the steady-state count. The cap is SOFT for the active user-selected relay
    /// feed (`register(…, bypassConnectionCap: true)`): that one explicit choice
    /// must always connect, so it overflows the cap when nothing is idle to evict;
    /// the 30s idle reaper then shrinks the pool back under the cap.
    private let maxConnections = 96
    /// Close connections that have had no subscribers for this long.
    private let idleTTL: TimeInterval = 45

    private var conns: [String: RelayConn] = [:]
    /// urlString -> number of active subscriptions referencing it.
    private var relayRefCount: [String: Int] = [:]
    /// urlString -> last time a sub was added/removed (LRU eviction key).
    private var relayTouched: [String: Date] = [:]
    /// subId -> the relay urlStrings it was registered on (for deregister).
    private var subToRelays: [String: [String]] = [:]
    /// subIds whose `deregister` raced ahead of their `register` (the two are spawned as
    /// separate unstructured Tasks with no ordering guarantee). `register` consults and
    /// clears this at the end so a cancel-before-register can't leak a pinned subscription.
    private var cancelledSubs: Set<String> = []
    private var reaper: Task<Void, Never>?

    private init() {
        let cfg = URLSessionConfiguration.default
        // Matches the old per-call `.default` behavior. A genuinely dropped
        // socket errors immediately (TCP RST/FIN) and triggers reconnect; this
        // request timeout is just the half-open backstop. Resource timeout is
        // infinite because these WebSockets are intentionally long-lived.
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = .infinity
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg)
    }

    /// Register a multiplexed subscription. `relays` is an ORDERED list of
    /// (relay, REQ frame) — callers build the frame so the pool stays filter-
    /// agnostic, and pass relays in priority order (e.g. the feed's score-sorted
    /// set) so that under the connection cap the highest-priority relays win.
    /// Duplicate relays within the list are collapsed. Relays that can't be
    /// connected under the cap are skipped — the subscription still works on the
    /// rest — UNLESS `bypassConnectionCap` is set, in which case every relay is
    /// guaranteed a connection (evicting an idle conn first, else temporarily
    /// overflowing the cap). Reserved for the active user-selected relay feed,
    /// which is a single explicit choice that must always connect.
    func register(subId: String, relays: [(url: URL, req: String)], sink: RelaySink,
                  bypassConnectionCap: Bool = false) async {
        startReaperIfNeeded()
        #if DEBUG
        let connsBefore = conns.count
        #endif
        var registered: [String] = []
        var seenInThisSub = Set<String>()
        for entry in relays {
            let urlString = entry.url.absoluteString
            guard seenInThisSub.insert(urlString).inserted else { continue }
            guard let conn = connection(for: urlString, url: entry.url, bypassCap: bypassConnectionCap) else { continue }
            await conn.addSub(id: subId, req: entry.req, sink: sink)
            relayRefCount[urlString, default: 0] += 1
            relayTouched[urlString] = Date()
            registered.append(urlString)
        }
        subToRelays[subId] = registered
        #if DEBUG
        // Catch scroll-triggered connection storms: a burst of `q-…` (one-shot
        // query / quoted-note / repost) registers each opening many NEW sockets
        // is the fingerprint of the freeze.
        relayPoolLog.log("register sub=\(subId, privacy: .public) requested=\(relays.count, privacy: .public) registered=\(registered.count, privacy: .public) newConns=\(self.conns.count - connsBefore, privacy: .public) liveConns=\(self.conns.count, privacy: .public) bypass=\(bypassConnectionCap, privacy: .public)")
        #endif
        // A `cancel()` may have raced ahead of this register (its deregister ran while we
        // were awaiting `addSub`, or before this Task was even scheduled). If so, tear down
        // now — otherwise the subscription stays pinned forever (refcount never hits 0),
        // which is exactly the kind of leaked no-`since` stream that caused regression #266.
        if cancelledSubs.remove(subId) != nil {
            await deregister(subId: subId)
        }
    }

    func deregister(subId: String) async {
        guard let relays = subToRelays.removeValue(forKey: subId) else {
            // `register` hasn't populated `subToRelays` yet (no ordering between the two
            // Tasks). Record the cancellation so `register` tears itself down on completion.
            cancelledSubs.insert(subId)
            return
        }
        for urlString in relays {
            if let conn = conns[urlString] { await conn.removeSub(id: subId) }
            let n = (relayRefCount[urlString] ?? 1) - 1
            relayRefCount[urlString] = max(0, n)
            relayTouched[urlString] = Date()
        }
    }

    func resend(subId: String) async {
        guard let relays = subToRelays[subId] else { return }
        for urlString in relays {
            if let conn = conns[urlString] { await conn.resend(id: subId) }
        }
    }

    /// Get-or-create a connection for `urlString`, evicting the least-recently-
    /// used idle connection if at the cap. Returns nil only when the cap is hit
    /// and nothing is idle to evict — unless `bypassCap`, where we still evict an
    /// idle conn if one exists (keeping the pool bounded when possible) but
    /// otherwise overflow the cap rather than refuse the connection.
    private func connection(for urlString: String, url: URL, bypassCap: Bool = false) -> RelayConn? {
        if let existing = conns[urlString] { return existing }
        if conns.count >= maxConnections, !evictOneIdle(), !bypassCap {
            return nil
        }
        let conn = RelayConn(url: url, session: session)
        conns[urlString] = conn
        return conn
    }

    /// Evict the oldest idle (zero-subscriber) connection. Returns false if none
    /// are idle (every connection is in active use).
    @discardableResult
    private func evictOneIdle() -> Bool {
        let idle = conns.keys.filter { (relayRefCount[$0] ?? 0) == 0 }
        guard let victim = idle.min(by: { (relayTouched[$0] ?? .distantPast) < (relayTouched[$1] ?? .distantPast) }) else {
            return false
        }
        if let conn = conns.removeValue(forKey: victim) {
            Task { await conn.shutdown() }
        }
        relayRefCount[victim] = nil
        relayTouched[victim] = nil
        return true
    }

    private func startReaperIfNeeded() {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.reapIdle()
            }
        }
    }

    private func reapIdle() {
        let now = Date()
        for urlString in conns.keys where (relayRefCount[urlString] ?? 0) == 0 {
            let touched = relayTouched[urlString] ?? .distantPast
            if now.timeIntervalSince(touched) >= idleTTL {
                if let conn = conns.removeValue(forKey: urlString) {
                    Task { await conn.shutdown() }
                }
                relayRefCount[urlString] = nil
                relayTouched[urlString] = nil
            }
        }
    }
}
