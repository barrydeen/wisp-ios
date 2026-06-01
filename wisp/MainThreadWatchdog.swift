import Foundation
import QuartzCore
import os

/// Diagnostics for the "feed freezes ~5–10s once per session" report.
///
/// A 5–10s main-thread stall is an I/O / IPC / network wait, not CPU, so it
/// won't show up by reading code. This file provides two always-on, near-zero-cost
/// hooks so the freeze self-reports:
///
///   • `PerfTrace` — a single in-memory breadcrumb of the most recent main-thread
///     render op + the feed row that's on screen. Set it at the entry of suspect
///     paths so a detected stall can name a likely culprit and the offending note.
///   • `MainThreadWatchdog` — a background poller that watches a main-run-loop
///     heartbeat and logs the stall's *total* duration + the breadcrumb the moment
///     the main thread recovers.
///
/// The authoritative identifier is still a live backtrace (pause in Xcode during
/// the freeze, inspect Thread 1) — this is the net that captures *which note* and
/// *how long* without Xcode attached.
///
/// Read in Console.app with `subsystem:wisp` (categories `main-stall`, `media-perf`).
/// All breadcrumb work compiles to a no-op in release.
let mainStallLog = Logger(subsystem: "wisp", category: "main-stall")
let mediaPerfLog = Logger(subsystem: "wisp", category: "media-perf")
/// Relay connection-pool churn — register fan-out width + live connection count.
/// Used to catch scroll-triggered connection storms (e.g. quoted-note / repost
/// fan-out to slow relays) that flood the main actor with per-event hops.
let relayPoolLog = Logger(subsystem: "wisp", category: "relay-pool")

/// Snapshot of what the main thread was last doing, captured at stall onset.
struct PerfBreadcrumb: Sendable {
    /// Most recent specific op (e.g. "content.parse", "poster.firstAVFoundation").
    var label: String = "idle"
    /// Short id of the feed row currently on screen (sticky across op marks).
    var note: String? = nil
    /// One-line media summary of the current row (kind / length / imeta / quote).
    var media: String? = nil
    /// URL associated with the most recent op, when relevant.
    var url: String? = nil
}

/// Cheap, lock-guarded global breadcrumb. No-op in release.
enum PerfTrace {
    #if DEBUG
    private static let lock = OSAllocatedUnfairLock(initialState: PerfBreadcrumb())
    #endif

    /// Set the current feed-row context. Sticky until the next row enters, so
    /// op marks below keep the row's note/media attached.
    static func enterRow(note: String, media: String) {
        #if DEBUG
        lock.withLock { $0.note = note; $0.media = media; $0.label = "feed.row" }
        #endif
    }

    /// Mark a specific main-thread op. Keeps the current row's note/media.
    static func mark(_ label: String, url: String? = nil) {
        #if DEBUG
        lock.withLock { $0.label = label; $0.url = url }
        #endif
    }

    static var current: PerfBreadcrumb {
        #if DEBUG
        lock.withLock { $0 }
        #else
        PerfBreadcrumb()
        #endif
    }
}

#if DEBUG
/// Detects main-thread stalls and logs their total duration + the breadcrumb.
///
/// A `CADisplayLink` on the main run loop bumps a heartbeat every frame; a
/// background queue polls it ~10×/s. When the heartbeat goes stale past the
/// threshold the main thread is blocked *right now* — we capture the breadcrumb
/// at onset, then log the full duration once the heartbeat recovers.
final class MainThreadWatchdog: NSObject, @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    /// Report stalls longer than this. 250ms is well past a dropped frame but
    /// short enough to catch every real hang.
    private let stallThreshold: CFTimeInterval = 0.25
    private let pollInterval: TimeInterval = 0.1
    private let watcher = DispatchQueue(label: "wisp.mainwatchdog", qos: .utility)

    private struct Heartbeat { var seq: UInt64 = 0; var lastBeat: CFTimeInterval = 0 }
    private let beat = OSAllocatedUnfairLock(initialState: Heartbeat())
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        beat.withLock { $0.lastBeat = CACurrentMediaTime() }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        watcher.async { [weak self] in self?.pollLoop() }
        mainStallLog.log("MainThreadWatchdog armed (threshold \(Int(self.stallThreshold * 1000))ms)")
    }

    @objc private func tick(_ link: CADisplayLink) {
        let t = link.timestamp
        beat.withLock { $0.seq &+= 1; $0.lastBeat = t }
    }

    private func pollLoop() {
        var inStall = false
        var stallSeq: UInt64 = 0
        var stallStartBeat: CFTimeInterval = 0
        var stallCrumb = PerfBreadcrumb()

        while true {
            Thread.sleep(forTimeInterval: pollInterval)
            let now = CACurrentMediaTime()
            let (seq, lastBeat) = beat.withLock { ($0.seq, $0.lastBeat) }
            let elapsed = now - lastBeat

            if !inStall {
                if elapsed > stallThreshold {
                    inStall = true
                    stallSeq = seq
                    stallStartBeat = lastBeat
                    stallCrumb = PerfTrace.current
                    // Emit at onset too, so we still have a record if a very long
                    // stall gets the app watchdog-killed before it recovers.
                    mainStallLog.error("""
                    MAIN STALL started (>\(Int(elapsed * 1000))ms) \
                    last=\(stallCrumb.label, privacy: .public) \
                    note=\(stallCrumb.note ?? "-", privacy: .public) \
                    media=\(stallCrumb.media ?? "-", privacy: .public) \
                    url=\(stallCrumb.url ?? "-", privacy: .public)
                    """)
                }
            } else if seq != stallSeq {
                // Main resumed — `lastBeat` is the first frame after the stall.
                let total = lastBeat - stallStartBeat
                mainStallLog.error("""
                MAIN STALL \(Int(total * 1000))ms \
                last=\(stallCrumb.label, privacy: .public) \
                note=\(stallCrumb.note ?? "-", privacy: .public) \
                media=\(stallCrumb.media ?? "-", privacy: .public) \
                url=\(stallCrumb.url ?? "-", privacy: .public)
                """)
                inStall = false
            }
        }
    }
}
#endif
