import Foundation
import UIKit
import os

/// Network-corrected wall clock for nostr event timestamps.
///
/// Every outgoing event's `created_at` used to read the device clock directly.
/// A device clock running fast stamps events in the future — strict relays
/// reject them ("created_at too far in the future") and tolerant relays accept
/// them, after which peers see broken chat ordering (a reply sorts *above* the
/// future-stamped message it answers). The inverse (slow clock) silently drops
/// events behind `since` filters.
///
/// `NostrClock` estimates the device-to-true-time offset from HTTPS `Date`
/// response headers (median of several reliable hosts) and exposes:
///
///   • `now()` — corrected epoch seconds; use for every signed event's
///     `created_at` instead of `Int(Date().timeIntervalSince1970)`.
///   • `clampIncoming(_:)` — caps a peer-supplied timestamp at now + tolerance
///     so a *peer's* fast clock can't scramble conversation ordering.
///
/// Sync runs at launch (`bootstrap()`) and on foreground entry, throttled.
/// On any failure the offset keeps its last value (initially 0) — behavior is
/// then identical to trusting the device clock, never worse.
nonisolated enum NostrClock {

    private static let log = Logger(subsystem: "wisp", category: "clock")

    /// Seconds to ADD to the device clock to get true time. Guarded the same
    /// way as `PerfTrace` (see MainThreadWatchdog.swift) — callers include
    /// `Task.detached` crypto paths, so this must be safe from any isolation.
    private static let offsetSeconds = OSAllocatedUnfairLock(initialState: Int(0))
    /// Device epoch seconds of the last *successful* sync (0 = never). Failed
    /// syncs don't update it, so the next foreground entry retries immediately.
    private static let lastSyncAt = OSAllocatedUnfairLock(initialState: Int(0))

    /// `Date` headers have 1 s granularity and rtt/2 skew; below this the
    /// device clock is considered correct and no correction is applied.
    static let noiseThresholdSeconds = 5
    private static let resyncIntervalSeconds = 15 * 60

    /// Hosts with reliable clocks and globally fast edges. Only the response
    /// `Date` header is read; bodies are never downloaded (HEAD).
    private static let timeSources = [
        "https://www.apple.com",
        "https://www.cloudflare.com",
        "https://www.google.com"
    ]

    // MARK: - Reading

    /// Corrected Unix epoch seconds. The timestamp source for every signed
    /// event's `created_at`.
    static func now() -> Int {
        Int(Date().timeIntervalSince1970) + offsetSeconds.withLock { $0 }
    }

    /// Clamp a peer-supplied `created_at` used for chat ordering to (corrected)
    /// now. A future-stamped message lands at its *arrival* time instead, so a
    /// sender with a fast clock can't push their messages below every subsequent
    /// reply — arrival order is monotonic, which is the natural chat order.
    ///
    /// Deliberately no tolerance: any allowance of N seconds re-opens an
    /// N-second inversion window in active chats (the reply arrives stamped
    /// `now`, the clamped message sits at `now + N`). Honest in-flight stamps
    /// are at most seconds ahead, so the rewrite is negligible — and it only
    /// affects the local view models, never the wire or stored raw events.
    static func clampIncoming(_ ts: Int) -> Int {
        min(ts, now())
    }

    // MARK: - Sync

    /// Start the initial sync and register the (process-lifetime) foreground
    /// re-sync observer. Call once from app init.
    static func bootstrap() {
        Task.detached(priority: .utility) { await sync() }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { _ in
            let deviceNow = Int(Date().timeIntervalSince1970)
            guard deviceNow - lastSyncAt.withLock({ $0 }) >= resyncIntervalSeconds else { return }
            Task.detached(priority: .utility) { await sync() }
        }
    }

    /// Query all time sources in parallel, take the median offset, and apply
    /// it (zeroed when within the noise threshold). Keeps the previous offset
    /// when every source fails.
    static func sync() async {
        let samples = await withTaskGroup(of: Int?.self) { group in
            for source in timeSources {
                group.addTask { await fetchOffsetSample(from: source) }
            }
            var out: [Int] = []
            for await sample in group {
                if let sample { out.append(sample) }
            }
            return out
        }
        guard let offset = computeOffset(samples: samples) else {
            log.warning("NostrClock sync failed: no time source reachable, keeping previous offset")
            return
        }
        offsetSeconds.withLock { $0 = offset }
        lastSyncAt.withLock { $0 = Int(Date().timeIntervalSince1970) }
        if offset != 0 {
            log.info("NostrClock: device clock off by \(-offset, privacy: .public)s, correcting created_at by \(offset, privacy: .public)s (\(samples.count, privacy: .public) sources)")
        }
    }

    /// Median of the per-source offset samples, zeroed inside the noise
    /// threshold; nil when there are no samples. Pure — unit-tested directly.
    static func computeOffset(samples: [Int]) -> Int? {
        guard !samples.isEmpty else { return nil }
        let median = samples.sorted()[samples.count / 2]
        return abs(median) > noiseThresholdSeconds ? median : 0
    }

    /// One source's offset estimate: `Date` header + rtt/2 − local receive
    /// time. The header marks (roughly) the rtt midpoint, so adding half the
    /// rtt aligns it with the local clock read at receive.
    private static func fetchOffsetSample(from source: String) async -> Int? {
        guard let url = URL(string: source) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let sentAt = Date().timeIntervalSince1970
        guard let (_, response) = try? await HttpClientFactory.shortTimeoutClient.data(for: request),
              let http = response as? HTTPURLResponse,
              let header = http.value(forHTTPHeaderField: "Date"),
              let serverDate = parseHttpDate(header) else { return nil }
        let receivedAt = Date().timeIntervalSince1970
        let rtt = receivedAt - sentAt
        return Int((serverDate.timeIntervalSince1970 + rtt / 2 - receivedAt).rounded())
    }

    /// Parse an RFC 7231 IMF-fixdate header ("Tue, 04 Jun 2026 12:34:56 GMT").
    /// A fresh formatter per call — sync runs a handful of times per session
    /// and `DateFormatter` is not thread-safe to share.
    static func parseHttpDate(_ s: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: s)
    }
}
