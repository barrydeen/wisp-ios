import Foundation
import Testing
@testable import wisp

struct NostrClockTests {

    // MARK: - HTTP Date header parsing (RFC 7231 IMF-fixdate)

    @Test func parsesImfFixdate() {
        let date = NostrClock.parseHttpDate("Thu, 04 Jun 2026 12:34:56 GMT")
        #expect(date != nil)
        // 2026-06-04T12:34:56Z
        #expect(Int(date!.timeIntervalSince1970) == 1_780_576_496)
    }

    @Test func parsesEpochReference() {
        let date = NostrClock.parseHttpDate("Thu, 01 Jan 1970 00:00:00 GMT")
        #expect(date?.timeIntervalSince1970 == 0)
    }

    @Test func rejectsGarbageDates() {
        #expect(NostrClock.parseHttpDate("") == nil)
        #expect(NostrClock.parseHttpDate("not a date") == nil)
        #expect(NostrClock.parseHttpDate("2026-06-04T12:34:56Z") == nil)  // ISO 8601, not IMF-fixdate
    }

    // MARK: - Offset computation (median + noise threshold)

    @Test func noSamplesYieldsNil() {
        #expect(NostrClock.computeOffset(samples: []) == nil)
    }

    /// Small skews (≤ threshold) must NOT be corrected — Date headers only have
    /// 1 s granularity and rtt/2 alignment error, so fighting a near-correct
    /// clock would just add jitter.
    @Test func withinNoiseThresholdIsZero() {
        #expect(NostrClock.computeOffset(samples: [0, 1, -2]) == 0)
        #expect(NostrClock.computeOffset(samples: [NostrClock.noiseThresholdSeconds]) == 0)
        #expect(NostrClock.computeOffset(samples: [-NostrClock.noiseThresholdSeconds]) == 0)
    }

    @Test func beyondThresholdAppliesMedian() {
        // Device clock 30 min fast → samples say "subtract ~1800".
        #expect(NostrClock.computeOffset(samples: [-1799, -1800, -1801]) == -1800)
        // Device clock slow → positive correction.
        #expect(NostrClock.computeOffset(samples: [600, 601, 599]) == 600)
    }

    /// One wildly-off source (bad clock, proxy cache) must not poison the estimate.
    @Test func medianRejectsOutlier() {
        #expect(NostrClock.computeOffset(samples: [-2, 999_999, 1]) == 0)
        #expect(NostrClock.computeOffset(samples: [-1800, 999_999, -1803]) == -1800)
    }

    // MARK: - Incoming clamp

    /// A peer-supplied timestamp in the future (their fast clock) is capped at
    /// (corrected) now — its arrival time — so later, correctly-stamped replies
    /// sort after it.
    @Test func clampsFutureTimestampsToNow() {
        let before = NostrClock.now()
        let clamped = NostrClock.clampIncoming(before + 3600)
        let after = NostrClock.now()
        #expect(clamped >= before)
        #expect(clamped <= after)
    }

    @Test func passesThroughPastTimestamps() {
        let now = NostrClock.now()
        #expect(NostrClock.clampIncoming(now - 86_400) == now - 86_400)
        #expect(NostrClock.clampIncoming(now - 1) == now - 1)
        #expect(NostrClock.clampIncoming(0) == 0)
    }

    /// Ordering regression test for the reported bug: A's future-stamped message
    /// arrives, then B's correctly-stamped reply. Without clamping, B's reply
    /// (stamped "now") sorts 30 min BEFORE A's message; with arrival-time
    /// clamping, A's message can never outrank a reply that arrives after it.
    @Test func clampedOrderingKeepsReplyAfterOriginal() {
        let aMessage = NostrClock.clampIncoming(NostrClock.now() + 1800)  // A's clock 30 min fast
        let bReply = NostrClock.clampIncoming(NostrClock.now() + 10)      // B replies, mild skew
        #expect(bReply >= aMessage)   // ascending sort keeps the reply at/after the original
    }
}
