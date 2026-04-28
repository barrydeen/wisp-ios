import Foundation
import SwiftUI
import Observation

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    enum ColorSchemePreference: String, CaseIterable {
        case system, light, dark
    }

    enum MediaLayoutStyle: String, CaseIterable {
        /// 2+ media items in a post render as a horizontal gallery (default).
        case grid
        /// 2+ media items render as a vertical stack — the original behaviour.
        case stack
    }

    private struct Keys {
        static let largeText = "wisp_settings_large_text"
        static let themeName = "wisp_settings_theme_name"
        static let colorScheme = "wisp_settings_color_scheme"
        static let accentColorARGB = "wisp_settings_accent_color_argb"
        static let autoLoadMedia = "wisp_settings_auto_load_media"
        static let videoAutoplay = "wisp_settings_video_autoplay"
        static let animateAvatars = "wisp_settings_animate_avatars"
        static let mediaLayoutStyle = "wisp_settings_media_layout_style"
        static let clientTagEnabled = "wisp_settings_client_tag_enabled"
        static let fiatModeEnabled = "wisp_settings_fiat_mode_enabled"
        static let fiatCurrency = "wisp_settings_fiat_currency"
        static let notificationSoundsEnabled = "wisp_settings_notification_sounds_enabled"
    }

    private static let defaultAccentARGB: Int = 0xFFFF9800

    var largeText: Bool {
        didSet { UserDefaults.standard.set(largeText, forKey: Keys.largeText) }
    }
    var themeName: String {
        didSet { UserDefaults.standard.set(themeName, forKey: Keys.themeName) }
    }
    var colorScheme: ColorSchemePreference {
        didSet { UserDefaults.standard.set(colorScheme.rawValue, forKey: Keys.colorScheme) }
    }
    var accentColorARGB: Int {
        didSet { UserDefaults.standard.set(accentColorARGB, forKey: Keys.accentColorARGB) }
    }
    var autoLoadMedia: Bool {
        didSet { UserDefaults.standard.set(autoLoadMedia, forKey: Keys.autoLoadMedia) }
    }
    var videoAutoplay: Bool {
        didSet { UserDefaults.standard.set(videoAutoplay, forKey: Keys.videoAutoplay) }
    }
    var animateAvatars: Bool {
        didSet { UserDefaults.standard.set(animateAvatars, forKey: Keys.animateAvatars) }
    }
    var mediaLayoutStyle: MediaLayoutStyle {
        didSet { UserDefaults.standard.set(mediaLayoutStyle.rawValue, forKey: Keys.mediaLayoutStyle) }
    }
    var clientTagEnabled: Bool {
        didSet { UserDefaults.standard.set(clientTagEnabled, forKey: Keys.clientTagEnabled) }
    }
    var fiatModeEnabled: Bool {
        didSet { UserDefaults.standard.set(fiatModeEnabled, forKey: Keys.fiatModeEnabled) }
    }
    var fiatCurrency: String {
        didSet { UserDefaults.standard.set(fiatCurrency, forKey: Keys.fiatCurrency) }
    }
    var notificationSoundsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationSoundsEnabled, forKey: Keys.notificationSoundsEnabled) }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.largeText = defaults.object(forKey: Keys.largeText) as? Bool ?? false
        self.themeName = defaults.string(forKey: Keys.themeName) ?? "custom"
        let csRaw = defaults.string(forKey: Keys.colorScheme) ?? ColorSchemePreference.dark.rawValue
        self.colorScheme = ColorSchemePreference(rawValue: csRaw) ?? .dark
        self.accentColorARGB = defaults.object(forKey: Keys.accentColorARGB) as? Int ?? Self.defaultAccentARGB
        self.autoLoadMedia = defaults.object(forKey: Keys.autoLoadMedia) as? Bool ?? true
        self.videoAutoplay = defaults.object(forKey: Keys.videoAutoplay) as? Bool ?? true
        self.animateAvatars = defaults.object(forKey: Keys.animateAvatars) as? Bool ?? true
        let layoutRaw = defaults.string(forKey: Keys.mediaLayoutStyle) ?? MediaLayoutStyle.grid.rawValue
        self.mediaLayoutStyle = MediaLayoutStyle(rawValue: layoutRaw) ?? .grid
        self.clientTagEnabled = defaults.object(forKey: Keys.clientTagEnabled) as? Bool ?? true
        self.fiatModeEnabled = defaults.object(forKey: Keys.fiatModeEnabled) as? Bool ?? false
        self.fiatCurrency = defaults.string(forKey: Keys.fiatCurrency) ?? "USD"
        self.notificationSoundsEnabled = defaults.object(forKey: Keys.notificationSoundsEnabled) as? Bool ?? true
    }

    var preferredColorScheme: ColorScheme? {
        switch colorScheme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var accentColor: Color {
        Color(argb: accentColorARGB)
    }
}

extension Color {
    init(argb: Int) {
        let a = Double((argb >> 24) & 0xFF) / 255.0
        let r = Double((argb >> 16) & 0xFF) / 255.0
        let g = Double((argb >> 8) & 0xFF) / 255.0
        let b = Double(argb & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a == 0 ? 1 : a)
    }

    init(rgb: Int) {
        self.init(argb: 0xFF000000 | (rgb & 0x00FFFFFF))
    }

    static func hex(_ argb: UInt32) -> Color {
        Color(argb: Int(bitPattern: UInt(argb)))
    }
}
