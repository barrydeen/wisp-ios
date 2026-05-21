import Foundation

/// Loads Google OAuth client IDs from bundled resource files (gitignored),
/// following the same pattern as `BreezConfig` and `GiphyConfig`.
///
/// `web-client-id` is required to mint an ID token whose `sub` claim is stable
/// across iOS and Android — it must match the same Web OAuth client used by
/// the Android app so backups created on one platform can be restored on the
/// other.
///
/// `ios-client-id` is the platform-specific OAuth client; GoogleSignIn-iOS
/// uses it when initiating the consent flow.
///
/// If either file is missing (e.g. a contributor without Google Cloud access),
/// the splash hides the "Continue with Google" button and the app continues
/// to work with the existing nsec-paste flow.
nonisolated enum GoogleAuthConfig {
    static let webClientId: String = load("google-web-client-id")
    static let iosClientId: String = load("google-ios-client-id")

    static var hasWebClientId: Bool { !webClientId.isEmpty }
    static var hasIosClientId: Bool { !iosClientId.isEmpty }

    /// True only when both client IDs are present. The Google sign-in UI is
    /// gated on this — there's no useful state where one is present and the
    /// other isn't, and showing a button that's guaranteed to error out is
    /// worse than not showing the button at all.
    static var isConfigured: Bool { hasWebClientId && hasIosClientId }

    private static func load(_ resourceName: String) -> String {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
