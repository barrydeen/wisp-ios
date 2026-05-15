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

    enum ZapIconStyle: String, CaseIterable {
        case bolt
        case bitcoin
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
        static let postUndoTimerEnabled = "wisp_settings_post_undo_timer_enabled"
        static let postUndoTimerSeconds = "wisp_settings_post_undo_timer_seconds"
        static let postUndoTimerForReplies = "wisp_settings_post_undo_timer_for_replies"
        static let autoApproveRelayAuth = "wisp_settings_auto_approve_relay_auth"
        static let zapIconStyle = "wisp_settings_zap_icon_style"
        static let videoLoop = "wisp_settings_video_loop"
        static let syncSettingsToRelays = "wisp_settings_sync_settings_to_relays"
    }

    /// Allowed durations for the post-undo countdown. Picker shows these as
    /// the granularity for the slider/segmented control in InterfaceSettings.
    static let postUndoTimerOptions: [Int] = [5, 10, 15, 20, 30]

    private static let defaultAccentARGB: Int = 0xFFFF9800

    var largeText: Bool {
        didSet {
            UserDefaults.standard.set(largeText, forKey: Keys.largeText)
            EmojiRepository.shared.scheduleSettingsSync()
        }
    }
    var themeName: String {
        didSet {
            UserDefaults.standard.set(themeName, forKey: Keys.themeName)
            EmojiRepository.shared.scheduleSettingsSync()
        }
    }
    var colorScheme: ColorSchemePreference {
        didSet {
            UserDefaults.standard.set(colorScheme.rawValue, forKey: Keys.colorScheme)
            EmojiRepository.shared.scheduleSettingsSync()
        }
    }
    var accentColorARGB: Int {
        didSet {
            UserDefaults.standard.set(accentColorARGB, forKey: Keys.accentColorARGB)
            EmojiRepository.shared.scheduleSettingsSync()
        }
    }
    var autoLoadMedia: Bool {
        didSet {
            UserDefaults.standard.set(autoLoadMedia, forKey: Keys.autoLoadMedia)
            EmojiRepository.shared.scheduleSettingsSync()
        }
    }
    var videoAutoplay: Bool {
        didSet {
            UserDefaults.standard.set(videoAutoplay, forKey: Keys.videoAutoplay)
            EmojiRepository.shared.scheduleSettingsSync()
        }
    }
    var animateAvatars: Bool {
        didSet {
            UserDefaults.standard.set(animateAvatars, forKey: Keys.animateAvatars)
            EmojiRepository.shared.scheduleSettingsSync()
        }
    }
    var mediaLayoutStyle: MediaLayoutStyle {
        didSet {
            UserDefaults.standard.set(mediaLayoutStyle.rawValue, forKey: Keys.mediaLayoutStyle)
            EmojiRepository.shared.scheduleSettingsSync()
        }
    }
    var clientTagEnabled: Bool {
        didSet {
            UserDefaults.standard.set(clientTagEnabled, forKey: Keys.clientTagEnabled)
            EmojiRepository.shared.scheduleSettingsSync()
        }
    }
    var fiatModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(fiatModeEnabled, forKey: Keys.fiatModeEnabled)
            EmojiRepository.shared.scheduleSettingsSync()
        }
    }
    var fiatCurrency: String {
        didSet {
            UserDefaults.standard.set(fiatCurrency, forKey: Keys.fiatCurrency)
            EmojiRepository.shared.scheduleSettingsSync()
        }
    }
    var notificationSoundsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationSoundsEnabled, forKey: Keys.notificationSoundsEnabled) }
    }
    /// When true, publishing a top-level post (and optionally replies — see
    /// `postUndoTimerForReplies`) waits `postUndoTimerSeconds` before sending,
    /// giving the user a chance to cancel.
    var postUndoTimerEnabled: Bool {
        didSet {
            UserDefaults.standard.set(postUndoTimerEnabled, forKey: Keys.postUndoTimerEnabled)
            EmojiRepository.shared.scheduleSettingsSync()
        }
    }
    var postUndoTimerSeconds: Int {
        didSet {
            UserDefaults.standard.set(postUndoTimerSeconds, forKey: Keys.postUndoTimerSeconds)
            EmojiRepository.shared.scheduleSettingsSync()
        }
    }
    /// When false, replies skip the undo countdown and publish immediately —
    /// the default. Top-level posts still respect `postUndoTimerEnabled`.
    var postUndoTimerForReplies: Bool {
        didSet {
            UserDefaults.standard.set(postUndoTimerForReplies, forKey: Keys.postUndoTimerForReplies)
            EmojiRepository.shared.scheduleSettingsSync()
        }
    }
    /// When true (default), AUTH challenges from relays are signed and sent automatically
    /// without prompting. When false, each relay must be individually approved in relay settings.
    var autoApproveRelayAuth: Bool {
        didSet { UserDefaults.standard.set(autoApproveRelayAuth, forKey: Keys.autoApproveRelayAuth) }
    }
    var zapIconStyle: ZapIconStyle {
        didSet {
            UserDefaults.standard.set(zapIconStyle.rawValue, forKey: Keys.zapIconStyle)
            EmojiRepository.shared.scheduleSettingsSync()
        }
    }
    /// When true (default), AppSettings + EmojiRepository publish a NIP-78
    /// kind-30078 backup of the user's preferences and quick-reactions so the
    /// same setup follows the account across devices/clients.
    var syncSettingsToRelays: Bool {
        didSet { UserDefaults.standard.set(syncSettingsToRelays, forKey: Keys.syncSettingsToRelays) }
    }
    // TODO: Persist to NIP78 (kind 30078) when that feature is available.
    var videoLoop: Bool {
        didSet { UserDefaults.standard.set(videoLoop, forKey: Keys.videoLoop) }
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
        self.postUndoTimerEnabled = defaults.object(forKey: Keys.postUndoTimerEnabled) as? Bool ?? true
        let storedSeconds = defaults.object(forKey: Keys.postUndoTimerSeconds) as? Int ?? 10
        self.postUndoTimerSeconds = Self.postUndoTimerOptions.contains(storedSeconds) ? storedSeconds : 10
        self.postUndoTimerForReplies = defaults.object(forKey: Keys.postUndoTimerForReplies) as? Bool ?? false
        self.autoApproveRelayAuth = defaults.object(forKey: Keys.autoApproveRelayAuth) as? Bool ?? true
        let zapRaw = defaults.string(forKey: Keys.zapIconStyle) ?? ZapIconStyle.bitcoin.rawValue
        self.zapIconStyle = ZapIconStyle(rawValue: zapRaw) ?? .bitcoin
        self.videoLoop = defaults.object(forKey: Keys.videoLoop) as? Bool ?? true
        self.syncSettingsToRelays = defaults.object(forKey: Keys.syncSettingsToRelays) as? Bool ?? true
    }

    /// Apply settings restored from a NIP-78 backup. Only non-default keys
    /// present in the payload are overwritten; the rest stay as configured
    /// locally. Called from `EmojiRepository.refresh` after a successful
    /// remote fetch — see `Nip78Backup.AppSettingsPayload`.
    func applyRestored(payload: Nip78Backup.AppSettingsPayload) {
        // Currency / zap
        if let s = payload.zapIconStyle, let style = ZapIconStyle(rawValue: s) {
            zapIconStyle = style
        }
        if let m = payload.fiatModeEnabled { fiatModeEnabled = m }
        if let c = payload.fiatCurrency, !c.isEmpty { fiatCurrency = c }
        if let raw = payload.zapPresetsCSV, !raw.isEmpty {
            UserDefaults.standard.set(raw, forKey: "zapPresetAmounts")
        }
        // Appearance
        if let b = payload.largeText { largeText = b }
        if let n = payload.themeName, !n.isEmpty { themeName = n }
        if let s = payload.colorScheme, let pref = ColorSchemePreference(rawValue: s) {
            colorScheme = pref
        }
        if let a = payload.accentColorARGB { accentColorARGB = a }
        // Media
        if let b = payload.autoLoadMedia { autoLoadMedia = b }
        if let b = payload.videoAutoplay { videoAutoplay = b }
        if let b = payload.animateAvatars { animateAvatars = b }
        if let s = payload.mediaLayoutStyle, let style = MediaLayoutStyle(rawValue: s) {
            mediaLayoutStyle = style
        }
        // Posting
        if let b = payload.clientTagEnabled { clientTagEnabled = b }
        if let b = payload.postUndoTimerEnabled { postUndoTimerEnabled = b }
        if let n = payload.postUndoTimerSeconds, Self.postUndoTimerOptions.contains(n) {
            postUndoTimerSeconds = n
        }
        if let b = payload.postUndoTimerForReplies { postUndoTimerForReplies = b }
    }

    /// Build the payload that gets NIP-44 encrypted and published as kind-30078.
    /// Mirrors `applyRestored` — every field the backup carries.
    func snapshotForBackup() -> Nip78Backup.AppSettingsPayload {
        let presetsRaw = UserDefaults.standard.string(forKey: "zapPresetAmounts")
        return Nip78Backup.AppSettingsPayload(
            zapIconStyle: zapIconStyle.rawValue,
            fiatModeEnabled: fiatModeEnabled,
            fiatCurrency: fiatCurrency,
            zapPresetsCSV: presetsRaw,
            largeText: largeText,
            themeName: themeName,
            colorScheme: colorScheme.rawValue,
            accentColorARGB: accentColorARGB,
            autoLoadMedia: autoLoadMedia,
            videoAutoplay: videoAutoplay,
            animateAvatars: animateAvatars,
            mediaLayoutStyle: mediaLayoutStyle.rawValue,
            clientTagEnabled: clientTagEnabled,
            postUndoTimerEnabled: postUndoTimerEnabled,
            postUndoTimerSeconds: postUndoTimerSeconds,
            postUndoTimerForReplies: postUndoTimerForReplies
        )
    }

    /// SF Symbol name for the zap icon. Only valid when `fiatModeEnabled` is false.
    /// Use `zapImage` for rendering — it handles the fiat coin stack automatically.
    var zapSymbolName: String {
        zapIconStyle == .bitcoin ? "bitcoinsign" : "bolt.fill"
    }

    /// The correct zap icon for the current mode. Fiat mode renders the coin stack asset;
    /// otherwise uses the user's bolt / bitcoin SF Symbol preference.
    var zapImage: Image {
        if fiatModeEnabled { return Image("CoinStack") }
        return Image(systemName: zapSymbolName)
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

// `nonisolated` — these initializers and `hex(_:)` are pure value transforms
// (Int → Color), used at module-load time by `Themes` and from any actor.
nonisolated extension Color {
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
