import SwiftUI
import UIKit
import GoogleSignIn

@main
struct wispApp: App {
    @State private var settings = AppSettings.shared
    @State private var powPrefs = PowPreferences.shared
    @State private var audioPlayer = AudioPlayerStore.shared

    init() {
        NsecPasteGuard.setUp()
        try? ObjectBoxSetup.setUp()
        GiphyConfig.bootstrap()
        Task {
            await ExchangeRateService.shared.refresh()
            await ExchangeRateCache.shared.updateFromService()
        }
        // Aggressively warm avatar cache for every profile we've ever persisted
        // so feed/profile/notifications surfaces render their avatars without a
        // network round-trip after the first launch.
        Task.detached(priority: .utility) {
            await AvatarPrefetcher.shared.sweepPersistedProfiles()
        }

        // Drop UIKit's 1pt hairline shadow under every UINavigationBar so views
        // that paint a custom toolbar background (e.g. ProfileView with a pinned
        // tab strip directly under the nav bar) read as one continuous header.
        // SwiftUI's `.toolbarBackground` doesn't expose shadow control.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            RootContainer()
                .environment(settings)
                .environment(powPrefs)
                .environment(audioPlayer)
                .preferredColorScheme(settings.preferredColorScheme)
                .onOpenURL { url in
                    // Required for Google Sign-In's OAuth redirect to make
                    // its way back into the SDK after the in-app browser
                    // returns from accounts.google.com.
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}

private struct RootContainer: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        let resolved = settings.resolveTheme(systemColorScheme: systemColorScheme)
        ResolvedThemeProxy.update(resolved)
        return ContentView()
            .environment(\.theme, resolved)
            .id("\(settings.themeName)-\(settings.colorScheme.rawValue)-\(settings.accentColorARGB)-\(systemColorScheme == .dark)")
            .task {
                // Pull the cross-device NIP-78 settings snapshot once per
                // pubkey-per-device. Fast no-op when the user has no key
                // or the device has already restored this account.
                await settings.restoreOnLaunchIfNeeded()
            }
    }
}
