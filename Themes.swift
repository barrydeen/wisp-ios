import SwiftUI

nonisolated enum Themes {
    static let all: [ThemePreset] = [
        ThemePreset(
            id: "custom", displayName: "Custom",
            dark: ThemePalette(
                primary: .hex(0xFFFF9800), secondary: .hex(0xFFFFB74D),
                background: .hex(0xFF131215), surface: .hex(0xFF1F1E21),
                surfaceVariant: .hex(0xFF2B2A2E),
                onBackground: .hex(0xFFE0E0E0), onSurface: .hex(0xFFE0E0E0),
                onSurfaceVariant: .hex(0xFF9998A0), outline: .hex(0xFF343338),
                zap: .hex(0xFFFF9800), repost: .hex(0xFF4CAF50),
                bookmark: .hex(0xFFFF9800), paid: .hex(0xFFFFD54F)
            ),
            light: ThemePalette(
                primary: .hex(0xFFCC7000), secondary: .hex(0xFFFFB74D),
                background: .hex(0xFFD8D8D8), surface: .hex(0xFFE8E8E8),
                surfaceVariant: .hex(0xFFCDCDCD),
                onBackground: .hex(0xFF1C1B1F), onSurface: .hex(0xFF1C1B1F),
                onSurfaceVariant: .hex(0xFF333333), outline: .hex(0xFF999999),
                zap: .hex(0xFFB85C00), repost: .hex(0xFF2E7D32),
                bookmark: .hex(0xFFB85C00), paid: .hex(0xFFC9A000)
            )
        ),
        ThemePreset(
            id: "nord", displayName: "Nord",
            dark: ThemePalette(
                primary: .hex(0xFF88C0D0), secondary: .hex(0xFF81A1C1),
                background: .hex(0xFF2E3440), surface: .hex(0xFF3B4252),
                surfaceVariant: .hex(0xFF434C5E),
                onBackground: .hex(0xFFD8DEE9), onSurface: .hex(0xFFD8DEE9),
                onSurfaceVariant: .hex(0xFFECEFF4), outline: .hex(0xFF4C566A),
                zap: .hex(0xFFEBCB8B), repost: .hex(0xFFA3BE8C),
                bookmark: .hex(0xFFEBCB8B), paid: .hex(0xFFEBCB8B)
            ),
            light: ThemePalette(
                primary: .hex(0xFF456085), secondary: .hex(0xFF81A1C1),
                background: .hex(0xFFDDE4EC), surface: .hex(0xFFD0D8E2),
                surfaceVariant: .hex(0xFFC0CAD8),
                onBackground: .hex(0xFF2E3440), onSurface: .hex(0xFF2E3440),
                onSurfaceVariant: .hex(0xFF2E3440), outline: .hex(0xFF8A96A8),
                zap: .hex(0xFFB5862E), repost: .hex(0xFF5B7A3A),
                bookmark: .hex(0xFFB5862E), paid: .hex(0xFFB5862E)
            )
        ),
        ThemePreset(
            id: "dracula", displayName: "Dracula",
            dark: ThemePalette(
                primary: .hex(0xFFFF79C6), secondary: .hex(0xFFBD93F9),
                background: .hex(0xFF282A36), surface: .hex(0xFF2E3040),
                surfaceVariant: .hex(0xFF3E4158),
                onBackground: .hex(0xFFF8F8F2), onSurface: .hex(0xFFF8F8F2),
                onSurfaceVariant: .hex(0xFFB4B8D8), outline: .hex(0xFF4A4D6E),
                zap: .hex(0xFFFFB86C), repost: .hex(0xFF50FA7B),
                bookmark: .hex(0xFFFFB86C), paid: .hex(0xFFF1FA8C)
            ),
            light: ThemePalette(
                primary: .hex(0xFFD05090), secondary: .hex(0xFF9A70C8),
                background: .hex(0xFFEAEAE0), surface: .hex(0xFFE0E0D8),
                surfaceVariant: .hex(0xFFD0D0C8),
                onBackground: .hex(0xFF282A36), onSurface: .hex(0xFF282A36),
                onSurfaceVariant: .hex(0xFF333340), outline: .hex(0xFF9E9E98),
                zap: .hex(0xFFD4894A), repost: .hex(0xFF2E8A4A),
                bookmark: .hex(0xFFD4894A), paid: .hex(0xFFC9B000)
            )
        ),
        ThemePreset(
            id: "gruvbox", displayName: "Gruvbox",
            dark: ThemePalette(
                primary: .hex(0xFFFE8019), secondary: .hex(0xFFFB4934),
                background: .hex(0xFF282828), surface: .hex(0xFF3C3836),
                surfaceVariant: .hex(0xFF504945),
                onBackground: .hex(0xFFEBDBB2), onSurface: .hex(0xFFEBDBB2),
                onSurfaceVariant: .hex(0xFFA89984), outline: .hex(0xFF665C54),
                zap: .hex(0xFFFE8019), repost: .hex(0xFF8EC07C),
                bookmark: .hex(0xFFFE8019), paid: .hex(0xFFD79921)
            ),
            light: ThemePalette(
                primary: .hex(0xFFA04810), secondary: .hex(0xFF8B2010),
                background: .hex(0xFFF5F0E5), surface: .hex(0xFFEBE5D8),
                surfaceVariant: .hex(0xFFDED6C8),
                onBackground: .hex(0xFF3C3836), onSurface: .hex(0xFF3C3836),
                onSurfaceVariant: .hex(0xFF665C54), outline: .hex(0xFFB8A888),
                zap: .hex(0xFFB85A10), repost: .hex(0xFF5B7A3A),
                bookmark: .hex(0xFFB85A10), paid: .hex(0xFFA07018)
            )
        ),
        ThemePreset(
            id: "catppuccin", displayName: "Catppuccin",
            dark: ThemePalette(
                primary: .hex(0xFF89B4FA), secondary: .hex(0xFFCBA6F7),
                background: .hex(0xFF1E1E2E), surface: .hex(0xFF313244),
                surfaceVariant: .hex(0xFF45475A),
                onBackground: .hex(0xFFCDD6F4), onSurface: .hex(0xFFCDD6F4),
                onSurfaceVariant: .hex(0xFFBAC2DE), outline: .hex(0xFF585B70),
                zap: .hex(0xFFFAB387), repost: .hex(0xFFA6E3A1),
                bookmark: .hex(0xFFFAB387), paid: .hex(0xFFF9E2AF)
            ),
            light: ThemePalette(
                primary: .hex(0xFF1848C0), secondary: .hex(0xFF8839EF),
                background: .hex(0xFFE3E5EA), surface: .hex(0xFFD5D8E0),
                surfaceVariant: .hex(0xFFBEC2CC),
                onBackground: .hex(0xFF4C4F69), onSurface: .hex(0xFF4C4F69),
                onSurfaceVariant: .hex(0xFF3C4058), outline: .hex(0xFF9498A8),
                zap: .hex(0xFFCB7030), repost: .hex(0xFF3A7A40),
                bookmark: .hex(0xFFCB7030), paid: .hex(0xFFA09000)
            )
        ),
        ThemePreset(
            id: "everforest", displayName: "Everforest",
            dark: ThemePalette(
                primary: .hex(0xFFA7C080), secondary: .hex(0xFF83C092),
                background: .hex(0xFF1E2326), surface: .hex(0xFF2E383C),
                surfaceVariant: .hex(0xFF374145),
                onBackground: .hex(0xFFD3C6AA), onSurface: .hex(0xFFD3C6AA),
                onSurfaceVariant: .hex(0xFF9DA9A0), outline: .hex(0xFF414B50),
                zap: .hex(0xFFE69875), repost: .hex(0xFFA7C080),
                bookmark: .hex(0xFFE69875), paid: .hex(0xFFDBBC7F)
            ),
            light: ThemePalette(
                primary: .hex(0xFF6A7800), secondary: .hex(0xFF35A77C),
                background: .hex(0xFFEBE5D0), surface: .hex(0xFFDDD6C0),
                surfaceVariant: .hex(0xFFD4CBB4),
                onBackground: .hex(0xFF4F5B62), onSurface: .hex(0xFF4F5B62),
                onSurfaceVariant: .hex(0xFF404A50), outline: .hex(0xFF959088),
                zap: .hex(0xFFB07850), repost: .hex(0xFF5A7A3A),
                bookmark: .hex(0xFFB07850), paid: .hex(0xFF908030)
            )
        ),
        ThemePreset(
            id: "onedark", displayName: "One Dark",
            dark: ThemePalette(
                primary: .hex(0xFF61AFEF), secondary: .hex(0xFFC678DD),
                background: .hex(0xFF282C34), surface: .hex(0xFF1E2228),
                surfaceVariant: .hex(0xFF2C313C),
                onBackground: .hex(0xFFB0B8C4), onSurface: .hex(0xFFB0B8C4),
                onSurfaceVariant: .hex(0xFF9DA5B4), outline: .hex(0xFF4B5263),
                zap: .hex(0xFFE5C07B), repost: .hex(0xFF98C379),
                bookmark: .hex(0xFFE5C07B), paid: .hex(0xFFE5C07B)
            ),
            light: ThemePalette(
                primary: .hex(0xFF4A80B8), secondary: .hex(0xFFC678DD),
                background: .hex(0xFFE5E5E5), surface: .hex(0xFFDADADA),
                surfaceVariant: .hex(0xFFCACACA),
                onBackground: .hex(0xFF282C34), onSurface: .hex(0xFF282C34),
                onSurfaceVariant: .hex(0xFF323640), outline: .hex(0xFFA0A0A0),
                zap: .hex(0xFFB5862E), repost: .hex(0xFF5B8A3A),
                bookmark: .hex(0xFFB5862E), paid: .hex(0xFFA09000)
            )
        ),
        ThemePreset(
            id: "tokyonight", displayName: "Tokyo Night",
            dark: ThemePalette(
                primary: .hex(0xFF2AC3DE), secondary: .hex(0xFFF7768E),
                background: .hex(0xFF16161E), surface: .hex(0xFF1F2335),
                surfaceVariant: .hex(0xFF365A77),
                onBackground: .hex(0xFFC0CAF5), onSurface: .hex(0xFFC0CAF5),
                onSurfaceVariant: .hex(0xFFA9B1D6), outline: .hex(0xFF365A77),
                zap: .hex(0xFFE0AF68), repost: .hex(0xFF9ECE6A),
                bookmark: .hex(0xFFE0AF68), paid: .hex(0xFFE0AF68)
            ),
            light: ThemePalette(
                primary: .hex(0xFF2090B0), secondary: .hex(0xFFF7768E),
                background: .hex(0xFFE0E4EC), surface: .hex(0xFFD4D8E0),
                surfaceVariant: .hex(0xFFC4C8D4),
                onBackground: .hex(0xFF1A1B26), onSurface: .hex(0xFF1A1B26),
                onSurfaceVariant: .hex(0xFF2A2C40), outline: .hex(0xFF9094A8),
                zap: .hex(0xFFB07030), repost: .hex(0xFF4A7A3A),
                bookmark: .hex(0xFFB07030), paid: .hex(0xFF907030)
            )
        ),
        ThemePreset(
            id: "srcery", displayName: "Srcery",
            dark: ThemePalette(
                primary: .hex(0xFF7CB860), secondary: .hex(0xFF6CA0D0),
                background: .hex(0xFF1C1B19), surface: .hex(0xFF262424),
                surfaceVariant: .hex(0xFF303030),
                onBackground: .hex(0xFFBAA67F), onSurface: .hex(0xFFBAA67F),
                onSurfaceVariant: .hex(0xFF918175), outline: .hex(0xFF3A3A3A),
                zap: .hex(0xFFFF5F00), repost: .hex(0xFF6CA0D0),
                bookmark: .hex(0xFF7CB860), paid: .hex(0xFFFBC000)
            ),
            light: ThemePalette(
                primary: .hex(0xFF508040), secondary: .hex(0xFF4A80B0),
                background: .hex(0xFFD4CFC0), surface: .hex(0xFFC8C2B4),
                surfaceVariant: .hex(0xFFB4AFA0),
                onBackground: .hex(0xFF1C1B19), onSurface: .hex(0xFF1C1B19),
                onSurfaceVariant: .hex(0xFF5A5548), outline: .hex(0xFF989088),
                zap: .hex(0xFFB84800), repost: .hex(0xFF4A80B0),
                bookmark: .hex(0xFF508040), paid: .hex(0xFFA08000)
            )
        ),
        ThemePreset(
            id: "kanagawa", displayName: "Kanagawa",
            dark: ThemePalette(
                primary: .hex(0xFFCB4B62), secondary: .hex(0xFF7E9CD8),
                background: .hex(0xFF1F1F28), surface: .hex(0xFF2A2A37),
                surfaceVariant: .hex(0xFF363646),
                onBackground: .hex(0xFFDCD7BA), onSurface: .hex(0xFFDCD7BA),
                onSurfaceVariant: .hex(0xFFC8C093), outline: .hex(0xFF6B6B80),
                zap: .hex(0xFFFF9E3B), repost: .hex(0xFF76946A),
                bookmark: .hex(0xFFCB4B62), paid: .hex(0xFFE6C384)
            ),
            light: ThemePalette(
                primary: .hex(0xFFCB4B62), secondary: .hex(0xFF7E9CD8),
                background: .hex(0xFFF6F3E8), surface: .hex(0xFFECE8DC),
                surfaceVariant: .hex(0xFFE0DCD0),
                onBackground: .hex(0xFF3A3630), onSurface: .hex(0xFF3A3630),
                onSurfaceVariant: .hex(0xFF6A6658), outline: .hex(0xFFB8B0A0),
                zap: .hex(0xFFE6A03B), repost: .hex(0xFF6A9A5A),
                bookmark: .hex(0xFFD27E99), paid: .hex(0xFFB09040)
            )
        ),
        ThemePreset(
            id: "ayu", displayName: "Ayu",
            dark: ThemePalette(
                primary: .hex(0xFFFFB454), secondary: .hex(0xFF5CCFE6),
                background: .hex(0xFF0A0E14), surface: .hex(0xFF141B22),
                surfaceVariant: .hex(0xFF1E262F),
                onBackground: .hex(0xFFD9D7CE), onSurface: .hex(0xFFD9D7CE),
                onSurfaceVariant: .hex(0xFF8B8F8B), outline: .hex(0xFF3D4551),
                zap: .hex(0xFFFFB454), repost: .hex(0xFF87D68D),
                bookmark: .hex(0xFFFFB454), paid: .hex(0xFFFFE99D)
            ),
            light: ThemePalette(
                primary: .hex(0xFFE86A33), secondary: .hex(0xFF1497D6),
                background: .hex(0xFFFAFAFA), surface: .hex(0xFFF0F0F0),
                surfaceVariant: .hex(0xFFE8E8E8),
                onBackground: .hex(0xFF434343), onSurface: .hex(0xFF434343),
                onSurfaceVariant: .hex(0xFF6B6B6B), outline: .hex(0xFFB0B0B0),
                zap: .hex(0xFFE86A33), repost: .hex(0xFF5BA055),
                bookmark: .hex(0xFFE86A33), paid: .hex(0xFFC0A000)
            )
        ),
        ThemePreset(
            id: "emerald", displayName: "Emerald",
            dark: ThemePalette(
                primary: .hex(0xFF50C878), secondary: .hex(0xFF98FB98),
                background: .hex(0xFF1A1D1A), surface: .hex(0xFF252A25),
                surfaceVariant: .hex(0xFF353D35),
                onBackground: .hex(0xFFD4E5D4), onSurface: .hex(0xFFD4E5D4),
                onSurfaceVariant: .hex(0xFF9CB09C), outline: .hex(0xFF404D44),
                zap: .hex(0xFF50C878), repost: .hex(0xFF98FB98),
                bookmark: .hex(0xFF50C878), paid: .hex(0xFFF0E080)
            ),
            light: ThemePalette(
                primary: .hex(0xFF2E8B57), secondary: .hex(0xFF3CB371),
                background: .hex(0xFFE0E8E0), surface: .hex(0xFFD0D8D0),
                surfaceVariant: .hex(0xFFB8C4B8),
                onBackground: .hex(0xFF1A2A1C), onSurface: .hex(0xFF1A2A1C),
                onSurfaceVariant: .hex(0xFF2A3A2C), outline: .hex(0xFF889888),
                zap: .hex(0xFF2E8B57), repost: .hex(0xFF3CB371),
                bookmark: .hex(0xFF2E8B57), paid: .hex(0xFF807010)
            )
        ),
        ThemePreset(
            id: "amethyst", displayName: "Amethyst",
            dark: ThemePalette(
                primary: .hex(0xFF9966CC), secondary: .hex(0xFFDA70D6),
                background: .hex(0xFF1D1A24), surface: .hex(0xFF282433),
                surfaceVariant: .hex(0xFF383248),
                onBackground: .hex(0xFFE0D8F0), onSurface: .hex(0xFFE0D8F0),
                onSurfaceVariant: .hex(0xFFA898C0), outline: .hex(0xFF444058),
                zap: .hex(0xFFBB88DD), repost: .hex(0xFFDA70D6),
                bookmark: .hex(0xFFBB88DD), paid: .hex(0xFFF0E080)
            ),
            light: ThemePalette(
                primary: .hex(0xFF7B4BA8), secondary: .hex(0xFFB04DAD),
                background: .hex(0xFFE8E4F0), surface: .hex(0xFFD8D4E0),
                surfaceVariant: .hex(0xFFC8C4D0),
                onBackground: .hex(0xFF2A2838), onSurface: .hex(0xFF2A2838),
                onSurfaceVariant: .hex(0xFF3A3848), outline: .hex(0xFF9890A8),
                zap: .hex(0xFF9040A0), repost: .hex(0xFF6A4A8A),
                bookmark: .hex(0xFF9040A0), paid: .hex(0xFF7850A0)
            )
        ),
        ThemePreset(
            id: "ruby", displayName: "Ruby",
            dark: ThemePalette(
                primary: .hex(0xFFE0115F), secondary: .hex(0xFFFF6B6B),
                background: .hex(0xFF1D1618), surface: .hex(0xFF2A2024),
                surfaceVariant: .hex(0xFF3A2830),
                onBackground: .hex(0xFFF0D8E0), onSurface: .hex(0xFFF0D8E0),
                onSurfaceVariant: .hex(0xFFB898A0), outline: .hex(0xFF4A3840),
                zap: .hex(0xFFFF6B6B), repost: .hex(0xFFFF6B6B),
                bookmark: .hex(0xFFFF6B6B), paid: .hex(0xFFF0E080)
            ),
            light: ThemePalette(
                primary: .hex(0xFFB00B3A), secondary: .hex(0xFFDD4455),
                background: .hex(0xFFF8E8EC), surface: .hex(0xFFE8D8E0),
                surfaceVariant: .hex(0xFFD8C8D0),
                onBackground: .hex(0xFF2A1820), onSurface: .hex(0xFF2A1820),
                onSurfaceVariant: .hex(0xFF4A2838), outline: .hex(0xFF9890A0),
                zap: .hex(0xFFB00B3A), repost: .hex(0xFF8B3A5A),
                bookmark: .hex(0xFFB00B3A), paid: .hex(0xFF805060)
            )
        ),
        ThemePreset(
            id: "sapphire", displayName: "Sapphire",
            dark: ThemePalette(
                primary: .hex(0xFF4A90D9), secondary: .hex(0xFF6AEFFA),
                background: .hex(0xFF1A1D24), surface: .hex(0xFF252A35),
                surfaceVariant: .hex(0xFF353D4A),
                onBackground: .hex(0xFFD0D8E8), onSurface: .hex(0xFFD0D8E8),
                onSurfaceVariant: .hex(0xFF88A0B8), outline: .hex(0xFF404858),
                zap: .hex(0xFF4A90D9), repost: .hex(0xFF6AEFFA),
                bookmark: .hex(0xFF4A90D9), paid: .hex(0xFFE0E8FF)
            ),
            light: ThemePalette(
                primary: .hex(0xFF2A68A8), secondary: .hex(0xFF3080A0),
                background: .hex(0xFFE4E8F0), surface: .hex(0xFFD0D8E4),
                surfaceVariant: .hex(0xFFB8C4D0),
                onBackground: .hex(0xFF2A3038), onSurface: .hex(0xFF2A3038),
                onSurfaceVariant: .hex(0xFF4A5868), outline: .hex(0xFF8898A8),
                zap: .hex(0xFF2A68A8), repost: .hex(0xFF208090),
                bookmark: .hex(0xFF2A68A8), paid: .hex(0xFF506088)
            )
        )
    ]

    static func get(_ id: String) -> ThemePreset {
        all.first(where: { $0.id == id }) ?? all[0]
    }
}
