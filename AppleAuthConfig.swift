import Foundation

/// Configuration for the "Continue with Apple" flow. Parallel to
/// `GoogleAuthConfig`, but unlike Google there are no client IDs to load —
/// Sign in with Apple is an entitlement-gated capability requiring the paid
/// Apple Developer Program. Personal Apple IDs cannot provision it.
///
/// Storage uses iCloud Keychain (`KeychainBackupService`) — no CloudKit
/// container, no schema dashboard, no Production deploy ceremony. Sync is
/// end-to-end encrypted by Apple's iCloud Keychain circle of trust, on top
/// of our own PIN-derived NIP-44 layer.
nonisolated enum AppleAuthConfig {
    /// True when the build carries the Sign in with Apple entitlement
    /// (requires the paid Apple Developer Program and
    /// `CODE_SIGN_ENTITLEMENTS = wisp.entitlements;` in both build configs).
    /// Flip to `false` if reverting to a personal team — otherwise the SIWA
    /// flow will fail at runtime when the button is tapped.
    ///
    /// Reading this from the signed entitlements at runtime would be ideal
    /// but `SecTaskCopyValueForEntitlement` isn't exposed by the Security
    /// Swift overlay on iOS. The capability is paywalled and the flip is a
    /// one-time manual step, so a compile-time constant is the right shape.
    static let isConfigured = true
}
