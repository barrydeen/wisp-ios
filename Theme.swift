import SwiftUI

nonisolated struct ThemePalette: Equatable {
    let primary: Color
    let secondary: Color
    let background: Color
    let surface: Color
    let surfaceVariant: Color
    let onBackground: Color
    let onSurface: Color
    let onSurfaceVariant: Color
    let outline: Color
    let zap: Color
    let repost: Color
    let bookmark: Color
    let paid: Color
}

nonisolated struct ThemePreset: Identifiable, Equatable {
    let id: String
    let displayName: String
    let dark: ThemePalette
    let light: ThemePalette
}

nonisolated struct ResolvedTheme: Equatable {
    let presetId: String
    let isDark: Bool
    let palette: ThemePalette
    let primary: Color

    static let `default` = ResolvedTheme(
        presetId: "custom",
        isDark: true,
        palette: Themes.get("custom").dark,
        primary: Color.hex(0xFFFF9800)
    )
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: ResolvedTheme = .default
}

extension EnvironmentValues {
    var theme: ResolvedTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

@MainActor
extension AppSettings {
    func resolveTheme(systemColorScheme: ColorScheme?) -> ResolvedTheme {
        let preset = Themes.get(themeName)
        let useDark: Bool
        switch colorScheme {
        case .system:
            useDark = (systemColorScheme ?? .dark) == .dark
        case .light:
            useDark = false
        case .dark:
            useDark = true
        }
        let palette = useDark ? preset.dark : preset.light
        let primary: Color
        if preset.id == "custom" {
            let raw = Color(argb: accentColorARGB)
            primary = useDark ? raw : Self.dimmedForLight(raw)
        } else {
            primary = palette.primary
        }
        return ResolvedTheme(
            presetId: preset.id,
            isDark: useDark,
            palette: palette,
            primary: primary
        )
    }

    /// Bright accent colors picked under dark mode (e.g. `#FF9800`) fail contrast against the
    /// light theme's grey background, so cap brightness/saturation when rendering on light.
    private static func dimmedForLight(_ color: Color) -> Color {
        let ui = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return color }
        let cappedB = min(b, 0.55)
        let cappedS = min(s, 0.95)
        return Color(UIColor(hue: h, saturation: cappedS, brightness: cappedB, alpha: a))
    }
}
