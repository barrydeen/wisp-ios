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
    /// Resolved zap-surface color. Matches `palette.zap` for the curated
    /// preset themes (Nord, Dracula, etc.) but tracks `primary` for the
    /// `custom` theme so a user-picked accent flows through to the
    /// zap icon / count / top-zapper indicators as one consistent hue.
    /// See LIGHT_MODE_COLOR_PARITY.md (Wisp Android repo) for the
    /// cross-platform contract.
    let zap: Color
    /// Same rationale as `zap` — bookmarks ride with the throughout-the-
    /// theme accent for the `custom` theme, keep their curated value for
    /// every other preset.
    let bookmark: Color
    /// Vivid variant of `zap` reserved for the celebratory in-flight bolt
    /// animation. Plain `zap` reads muddy in light mode because the
    /// primary is darkened for contrast; the burst needs a brighter
    /// floor or the animation looks dim against the near-white surface.
    /// Static UI everywhere else uses `zap`, not this.
    let zapAnimation: Color

    static let `default` = ResolvedTheme(
        presetId: "custom",
        isDark: true,
        palette: Themes.get("custom").dark,
        primary: Color.hex(0xFFFF9800),
        zap: Color.hex(0xFFFF9800),
        bookmark: Color.hex(0xFFFF9800),
        zapAnimation: Color.hex(0xFFFF9800)
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
            if useDark {
                primary = raw
            } else if accentColorARGB == 0xFFFF9800 {
                // Default accent — use the curated light-primary value
                // (deeper than a generic 18% darken would produce). The
                // matching constant lives on `AppSettings.defaultAccentARGB`.
                primary = palette.primary
            } else {
                // User-picked accent — darken 18% in HSL space so the
                // tinted-button contrast against the near-white surface
                // mirrors what the default accent gets.
                primary = Self.darkenColor(raw, fraction: 0.18)
            }
        } else {
            primary = palette.primary
        }
        // For the `custom` theme, zap + bookmark surfaces ride the resolved
        // primary so a user-picked accent flows through to the zap icon,
        // post-zap count, top-zapper indicator, etc. as one consistent hue.
        // Every other preset has its own curated zap / bookmark swatch
        // chosen for hue contrast against that preset's primary, so we
        // pass those through unchanged.
        let zap: Color
        let bookmark: Color
        if preset.id == "custom" {
            zap = primary
            bookmark = primary
        } else {
            zap = palette.zap
            bookmark = palette.bookmark
        }
        return ResolvedTheme(
            presetId: preset.id,
            isDark: useDark,
            palette: palette,
            primary: primary,
            zap: zap,
            bookmark: bookmark,
            zapAnimation: Self.vividZapColor(zap)
        )
    }

    /// Darkens `color` by `fraction` of its current HSL lightness — the
    /// same operation Wisp Android's `darkenColor` performs. Used to
    /// derive a light-mode primary from a user-picked accent so the
    /// tinted button keeps enough contrast against the near-white
    /// surface.
    nonisolated static func darkenColor(_ color: Color, fraction: CGFloat) -> Color {
        let ui = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return color }
        // UIColor exposes HSB, not HSL. They share hue + saturation but
        // their lightness/brightness scales differ. The HSL `lightness
        // *= (1 - fraction)` operation we want maps almost identically
        // to scaling HSB brightness by the same factor for the orange
        // family we care about (saturated mid-light values), so we
        // apply the multiplier on brightness and skip a full HSL
        // round-trip.
        let darker = max(0, b * (1 - fraction))
        return Color(UIColor(hue: h, saturation: s, brightness: darker, alpha: a))
    }

    /// Vivid variant of a zap color for the in-flight bolt animation.
    /// Bumps saturation 15% (capped at 1.0) and floors brightness at 0.5
    /// so the celebratory pulse never reads muddy or dark on the light
    /// surface. Mirrors `vividZapColor` in Wisp Android's Theme.kt.
    nonisolated static func vividZapColor(_ color: Color) -> Color {
        let ui = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return color }
        let saturation = min(1.0, s * 1.15)
        let brightness = max(0.5, b)
        return Color(UIColor(hue: h, saturation: saturation, brightness: brightness, alpha: a))
    }
}
