import Foundation
import Observation

/// Background fetcher for kind-0 profiles whose pubkey we've seen referenced
/// somewhere in the app but don't have cached. Sits on top of
/// `ProfileRepository.ensure(_:)` and adds:
///
/// - Debounced + bounded queue (drain at 100ms or 200 pubkeys, whichever first).
/// - Negative cache: after `MAX_ATTEMPTS` failed indexer fetches a pubkey is
///   moved to `exhausted` and won't be retried from feeds. The profile screen
///   bypasses this via `forceFetch`.
/// - Periodic sweep over registered event sources (FeedViewModel.events, etc.)
///   at 3s/8s/15s after `start`, then every 120s — catches events seeded from
///   ObjectBox before the watcher began observing, and `nostr:npub` mentions
///   that resolve at render time.
/// - A single `updates` AsyncStream broadcasts each freshly-resolved pubkey so
///   ViewModels can merge into their own `profiles` dict without re-running
///   their own batched indexer fetches.
@Observable
@MainActor
final class MissingProfileWatcher {
    static let shared = MissingProfileWatcher()

    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var inflightLocal: Set<String> = []
    @ObservationIgnored private var attempts: [String: Int] = [:]
    @ObservationIgnored private var exhausted: Set<String> = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    @ObservationIgnored private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]
    @ObservationIgnored private var sources: [UUID: @MainActor () -> [NostrEvent]] = [:]
    @ObservationIgnored private var activePubkey: String?

    private static let maxAttempts = 2
    private static let maxBatch = 200
    private static let debounceMs: UInt64 = 100

    private init() {}

    // MARK: - Lifecycle

    /// Idempotent per pubkey. Account switches re-instantiate `MainView`, which
    /// triggers `stop()` then `start(_:)` with the new pubkey — that path resets
    /// `pending` / `attempts` / `exhausted` so the new account doesn't inherit
    /// the prior session's negative cache.
    func start(activePubkey: String) {
        if self.activePubkey == activePubkey, sweepTask != nil { return }
        if self.activePubkey != nil { resetState() }
        self.activePubkey = activePubkey
        scheduleSweeps()
    }

    func stop() {
        flushTask?.cancel()
        sweepTask?.cancel()
        flushTask = nil
        sweepTask = nil
        for c in continuations.values { c.finish() }
        continuations.removeAll()
        sources.removeAll()
        resetState()
        activePubkey = nil
    }

    private func resetState() {
        pending.removeAll(keepingCapacity: true)
        inflightLocal.removeAll(keepingCapacity: true)
        attempts.removeAll(keepingCapacity: true)
        exhausted.removeAll(keepingCapacity: true)
    }

    // MARK: - Ingest

    /// Walk each event's referenced authors (outer pubkey, inner-repost pubkey,
    /// nostr:npub mentions) and enqueue any we don't already have cached.
    func observe(_ events: [NostrEvent]) {
        guard !events.isEmpty else { return }
        var authors = Set<String>()
        for event in events {
            for pk in event.referencedAuthorPubkeys {
                authors.insert(pk)
            }
        }
        observePubkeys(authors)
    }

    func observe(_ event: NostrEvent) {
        observePubkeys(event.referencedAuthorPubkeys)
    }

    func observePubkeys(_ pubkeys: any Sequence<String>) {
        var added = 0
        for pk in pubkeys {
            if pk.isEmpty { continue }
            if exhausted.contains(pk) { continue }
            if inflightLocal.contains(pk) { continue }
            if pending.contains(pk) { continue }
            if ProfileRepository.shared.get(pk) != nil { continue }
            pending.insert(pk)
            added += 1
        }
        guard added > 0 else { return }
        if pending.count >= Self.maxBatch {
            flushTask?.cancel()
            flushTask = Task { @MainActor [weak self] in
                await self?.runFlush()
            }
        } else if flushTask == nil {
            flushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.debounceMs * 1_000_000)
                if Task.isCancelled { return }
                await self?.runFlush()
            }
        }
    }

    // MARK: - Force fetch

    /// Bypass the exhausted set for an explicit user action (profile screen tap).
    /// Updates listeners just like a normal flush.
    func forceFetch(_ pubkey: String) async -> ProfileData? {
        if pubkey.isEmpty { return nil }
        if let cached = ProfileRepository.shared.get(pubkey) { return cached }
        exhausted.remove(pubkey)
        attempts.removeValue(forKey: pubkey)
        let dict = await ProfileRepository.shared.ensure([pubkey])
        let resolved = dict[pubkey]
        if resolved != nil {
            broadcast(pubkey)
        }
        return resolved
    }

    // MARK: - Sources / sweep

    @discardableResult
    func registerSource(_ source: @escaping @MainActor () -> [NostrEvent]) -> UUID {
        let id = UUID()
        sources[id] = source
        return id
    }

    func unregisterSource(_ id: UUID) {
        sources.removeValue(forKey: id)
    }

    /// Walk every registered events source and re-observe their authors. Picks
    /// up profiles for events seeded from ObjectBox before the watcher started,
    /// and `nostr:npub` mentions that resolve at render time rather than at
    /// ingest.
    func sweep() {
        guard !sources.isEmpty else { return }
        var collected: [NostrEvent] = []
        for source in sources.values {
            collected.append(contentsOf: source())
        }
        if !collected.isEmpty {
            observe(collected)
        }
    }

    private func scheduleSweeps() {
        sweepTask?.cancel()
        sweepTask = Task { @MainActor [weak self] in
            // Eager bursts: catches feed/notification ObjectBox seeds that race
            // ahead of the EventPersistQueue flush at cold-start.
            for delaySeconds in [3, 8, 15] {
                try? await Task.sleep(for: .seconds(delaySeconds))
                if Task.isCancelled { return }
                self?.sweep()
            }
            // Steady cadence afterwards.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                if Task.isCancelled { return }
                self?.sweep()
            }
        }
    }

    // MARK: - Updates stream

    /// Multi-subscriber stream of pubkeys whose profile just landed.
    /// Each call returns its own stream. Consumers should iterate inside a
    /// `Task { for await pk in updates { ... } }` and let the task cancel
    /// at view-model teardown — the continuation is removed automatically.
    var updates: AsyncStream<String> {
        AsyncStream<String> { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor [weak self] in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    private func broadcast(_ pubkey: String) {
        for c in continuations.values { c.yield(pubkey) }
    }

    // MARK: - Flush

    private func runFlush() async {
        flushTask = nil
        guard !pending.isEmpty else { return }
        let batchSlice = pending.prefix(Self.maxBatch)
        let batch = Array(batchSlice)
        for pk in batch { pending.remove(pk) }
        for pk in batch { inflightLocal.insert(pk) }
        for pk in batch { attempts[pk, default: 0] += 1 }

        let resolved = await ProfileRepository.shared.ensure(batch)

        for pk in batch {
            inflightLocal.remove(pk)
            if resolved[pk] != nil {
                attempts.removeValue(forKey: pk)
                broadcast(pk)
            } else if (attempts[pk] ?? 0) >= Self.maxAttempts {
                exhausted.insert(pk)
                attempts.removeValue(forKey: pk)
            }
        }

        if !pending.isEmpty {
            flushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.debounceMs * 1_000_000)
                if Task.isCancelled { return }
                await self?.runFlush()
            }
        }
    }
}

// MARK: - NostrEvent.referencedAuthorPubkeys

extension NostrEvent {
    /// Every pubkey whose kind-0 profile is needed to render this event: the
    /// outer author, the inner-repost author (kind 6), and any
    /// `nostr:npub` / `nostr:nprofile` mentions in the content (or in the
    /// embedded inner note for reposts).
    ///
    /// Lifted from `FeedViewModel` so the missing-profile watcher can reuse
    /// the same author-resolution logic without depending on FeedViewModel.
    var referencedAuthorPubkeys: [String] {
        var result: Set<String> = [pubkey]
        if let inner = repostInnerPubkey {
            result.insert(inner)
        }
        for pk in Self.mentionPubkeys(content: content, tags: tags) {
            result.insert(pk)
        }
        if kind == 6, !content.isEmpty,
           let data = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let innerContent = json["content"] as? String {
            let innerTags = (json["tags"] as? [[String]]) ?? []
            for pk in Self.mentionPubkeys(content: innerContent, tags: innerTags) {
                result.insert(pk)
            }
        }
        return Array(result)
    }

    /// Inner author of a kind-6 repost (pubkey of the embedded original note).
    /// Falls back to the `p` tag when the reposter omits the embedded event
    /// JSON — without it, mute-list filtering misses tag-only reposts.
    var repostInnerPubkey: String? {
        guard kind == 6 else { return nil }
        if !content.isEmpty,
           let data = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pk = json["pubkey"] as? String, !pk.isEmpty {
            return pk
        }
        return tags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1]
    }

    private static func mentionPubkeys(content: String, tags: [[String]]) -> [String] {
        let segments = ContentParser.parse(content: content, tags: tags, trimBlankLines: false)
        var out: [String] = []
        for seg in segments {
            if case .nostrProfile(let pubkey, _) = seg {
                out.append(pubkey)
            }
        }
        return out
    }
}
