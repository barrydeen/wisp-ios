import Foundation

/// Coalesces small `EventStore.persist` calls into ~200 ms / 50-event batches.
///
/// Without this, a populated feed's backfill burst dispatches one detached
/// task per inbound event (≈100/sec from a busy relay), each opening its own
/// ObjectBox write transaction. The queue trades a tiny bit of write latency
/// for far fewer transactions and less actor contention. Persistence is
/// fire-and-forget — callers don't await.
actor EventPersistQueue {
    static let shared = EventPersistQueue()

    private var pending: [NostrEvent] = []
    private var flushTask: Task<Void, Never>?

    private static let flushDelay: Duration = .milliseconds(200)
    private static let flushThreshold = 50

    private init() {}

    func enqueue(_ event: NostrEvent) {
        pending.append(event)
        scheduleOrFlush()
    }

    func enqueue(_ events: [NostrEvent]) {
        guard !events.isEmpty else { return }
        pending.append(contentsOf: events)
        scheduleOrFlush()
    }

    /// Drain the queue immediately. Useful for tests or shutdown paths.
    func flush() async {
        flushTask?.cancel()
        flushTask = nil
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        guard !batch.isEmpty else { return }
        await EventStore.shared.persist(batch)
    }

    private func scheduleOrFlush() {
        if pending.count >= Self.flushThreshold {
            flushNow()
        } else if flushTask == nil {
            scheduleFlush()
        }
    }

    private func scheduleFlush() {
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            await self?.flushNow()
        }
    }

    private func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        guard !batch.isEmpty else { return }
        // Fire-and-forget: ObjectBox writes serialize inside `EventStore`.
        Task.detached(priority: .utility) {
            await EventStore.shared.persist(batch)
        }
    }
}
