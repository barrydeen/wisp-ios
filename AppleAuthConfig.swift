import Foundation
import CloudKit

/// Configuration for the "Continue with Apple" flow. Parallel to
/// `GoogleAuthConfig`, but unlike Google there are no client IDs to load —
/// Sign in with Apple + iCloud are entitlement-gated capabilities that
/// require the paid Apple Developer Program. Personal Apple IDs cannot
/// provision them.
///
/// `cachedAccountStatus` is populated by a warm-up call from `wispApp.init`
/// so the splash gate has a synchronous boolean to read on the first frame
/// without hopping to CloudKit. The accessor is lock-protected because the
/// warm-up runs on a detached task while the splash reads from the main
/// actor.
nonisolated enum AppleAuthConfig {
    /// CloudKit container that backs the encrypted nsec blobs. Must match
    /// the value in `wisp.entitlements` and the container provisioned in the
    /// Apple Developer portal. Forks under a different team need their own
    /// container and a local override here.
    static let containerIdentifier = "iCloud.barrydeen.wisp"

    /// True when the build carries the iCloud + Sign in with Apple
    /// entitlements (requires the paid Apple Developer Program and
    /// `CODE_SIGN_ENTITLEMENTS = wisp.entitlements;` in both build configs).
    /// Flip back to `false` if reverting to a personal team — otherwise
    /// `CKContainer` calls log a noisy "your process must have a
    /// com.apple.developer.icloud-services entitlement" warning at runtime.
    ///
    /// Reading this from the signed entitlements at runtime would be ideal
    /// but `SecTaskCopyValueForEntitlement` isn't exposed by the Security
    /// Swift overlay on iOS. The capability is paywalled and the flip is a
    /// one-time manual step, so a compile-time constant is the right shape.
    static let isConfigured = true

    /// Snapshot of the most recent `CKContainer.accountStatus()` result, or
    /// nil if no warm-up has run yet. Read by the splash on the first frame
    /// to decide whether to show the Apple button; refreshed by
    /// `refreshAccountStatus()`.
    static var cachedAccountStatus: CKAccountStatus? {
        statusLock.lock(); defer { statusLock.unlock() }
        return _cachedStatus
    }

    /// `true` once a warm-up call has confirmed iCloud is signed in.
    /// Surfaced as a plain `Bool` so callers (the splash, ContentView) don't
    /// need to import CloudKit just to gate on iCloud availability.
    static var isAvailable: Bool {
        cachedAccountStatus == .available
    }

    /// Tri-state version of `isAvailable`: `nil` until a status has been
    /// determined, `true`/`false` once a refresh has run. Lets callers
    /// short-circuit only when iCloud is *known* unavailable — without
    /// importing CloudKit for `CKAccountStatus`.
    static var cachedIsAvailable: Bool? {
        guard let status = cachedAccountStatus else { return nil }
        return status == .available
    }

    /// Async equivalent of `isAvailable` that forces a fresh status check.
    /// Used by the splash `.task` to update the gate after launch.
    static func refreshIsAvailable() async -> Bool {
        await refreshAccountStatus() == .available
    }

    /// Queries iCloud for the user's account status, caches the result, and
    /// returns it. Safe to call from any actor.
    ///
    /// Short-circuits to `.couldNotDetermine` without contacting CloudKit
    /// when the build lacks the iCloud entitlement — that path avoids the
    /// "Significant issue" log CloudKit emits on personal-team builds, and
    /// keeps the splash button hidden until the entitlement is wired up.
    @discardableResult
    static func refreshAccountStatus() async -> CKAccountStatus {
        guard isConfigured else {
            storeCachedStatus(.couldNotDetermine)
            return .couldNotDetermine
        }
        let status: CKAccountStatus
        do {
            status = try await CKContainer(identifier: containerIdentifier).accountStatus()
        } catch {
            // Treat any error as "unknown" — splash will hide the Apple
            // button until a future refresh succeeds.
            status = .couldNotDetermine
        }
        storeCachedStatus(status)
        return status
    }

    private static func storeCachedStatus(_ status: CKAccountStatus) {
        statusLock.lock(); defer { statusLock.unlock() }
        _cachedStatus = status
    }

    private static let statusLock = NSLock()
    nonisolated(unsafe) private static var _cachedStatus: CKAccountStatus?
}
