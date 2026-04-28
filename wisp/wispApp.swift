import SwiftUI
import UIKit

@main
struct wispApp: App {
    @State private var settings = AppSettings.shared
    @State private var powPrefs = PowPreferences.shared

    init() {
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
                .preferredColorScheme(settings.preferredColorScheme)
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
    }
}
