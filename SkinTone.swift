import Foundation
import SwiftUI

/// Fitzpatrick skin-tone modifier applied to tone-capable emoji in the
/// picker. Mirrors the iOS system emoji keyboard's long-press popover:
/// pick once, the choice persists in `UserDefaults` and is applied to
/// every tone-capable cell going forward.
enum EmojiSkinTone: String, CaseIterable, Identifiable {
    case `default`
    case light
    case mediumLight
    case medium
    case mediumDark
    case dark

    var id: String { rawValue }

    /// Fitzpatrick modifier appended to the base codepoint. `nil` for the
    /// default yellow rendering.
    var modifier: String? {
        switch self {
        case .default:      return nil
        case .light:        return "\u{1F3FB}"
        case .mediumLight:  return "\u{1F3FC}"
        case .medium:       return "\u{1F3FD}"
        case .mediumDark:   return "\u{1F3FE}"
        case .dark:         return "\u{1F3FF}"
        }
    }

    /// Single-glyph preview shown in the popover swatch. Uses the open-palm
    /// emoji (👋) under each tone so the user sees the actual rendered
    /// color rather than an abstract swatch.
    var previewSwatch: String {
        let base = "\u{1F44B}" // 👋
        guard let mod = modifier else { return base }
        return base + mod
    }
}

@MainActor
enum EmojiSkinTonePreference {
    private static let key = "com.wisp.emoji.preferredSkinTone"

    static var current: EmojiSkinTone {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let tone = EmojiSkinTone(rawValue: raw) else {
                return .default
            }
            return tone
        }
        set {
            if newValue == .default {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(newValue.rawValue, forKey: key)
            }
            NotificationCenter.default.post(
                name: .emojiSkinTonePreferenceDidChange, object: nil
            )
        }
    }
}

extension Notification.Name {
    /// Fired when `EmojiSkinTonePreference.current` is written. Picker views
    /// listen so cells re-render with the new tone applied without needing
    /// the user to dismiss and re-open the sheet.
    static let emojiSkinTonePreferenceDidChange = Notification.Name(
        "com.wisp.emoji.preferredSkinTone.didChange"
    )
}

extension String {
    /// Strip every Fitzpatrick modifier (U+1F3FB–U+1F3FF) so the base form
    /// can be looked up in the tone-capable set, or so a tone can be
    /// re-applied cleanly.
    func removingSkinTones() -> String {
        String(unicodeScalars.filter { scalar in
            !(0x1F3FB...0x1F3FF).contains(scalar.value)
        })
    }

    /// Apply `tone` to a tone-capable base emoji. For a simple single-glyph
    /// emoji the modifier is appended (👋 + 🏽 → 👋🏽). For a ZWJ sequence
    /// with a single human glyph at the start (e.g. 👨‍🚀) the modifier is
    /// inserted between the base character and the first ZWJ joiner so the
    /// renderer applies it to the human glyph rather than the trailing
    /// component (👨‍🚀 → 👨🏽‍🚀). Returns the base unchanged for the default
    /// (yellow) tone.
    func applyingSkinTone(_ tone: EmojiSkinTone) -> String {
        guard let modifier = tone.modifier else { return removingSkinTones() }
        let base = removingSkinTones()
        // Split on the first ZWJ (U+200D) — if present, inject the modifier
        // before it; otherwise append.
        if let zwjRange = base.range(of: "\u{200D}") {
            // Skip any variation selector (FE0F) that sits right before the
            // ZWJ — the modifier must come BEFORE the VS-16 to render
            // correctly.
            var injectAt = zwjRange.lowerBound
            if injectAt > base.startIndex {
                let prev = base.index(before: injectAt)
                if base[prev] == "\u{FE0F}" {
                    injectAt = prev
                }
            }
            return String(base[..<injectAt]) + modifier + String(base[injectAt...])
        }
        // Plain emoji: append (strip any trailing VS-16 first so the
        // modifier sits flush against the base glyph).
        let trimmed = base.hasSuffix("\u{FE0F}") ? String(base.dropLast()) : base
        return trimmed + modifier
    }
}

/// Set of base emoji that accept Fitzpatrick skin-tone modifiers. Sourced
/// from Unicode emoji-test.txt (lines tagged `; fully-qualified` with a
/// `.tone.` annotation). Keys are normalized (no VS-16, no existing tone)
/// so a lookup matches whether the picker stored the emoji with or without
/// the variation selector.
@MainActor
enum EmojiToneCapability {
    /// Membership check. Strips the variation selector before lookup so
    /// "👋" and "👋\u{FE0F}" both resolve.
    static func accepts(_ emoji: String) -> Bool {
        let key = emoji.removingSkinTones().replacingOccurrences(of: "\u{FE0F}", with: "")
        return baseSet.contains(key)
    }

    /// Base emoji that accept the standard 5-tone Fitzpatrick modifier set.
    /// Multi-person ZWJ sequences (couples, families) accept per-position
    /// tones in principle but are intentionally excluded here — the picker
    /// only offers a single global tone choice.
    private static let baseSet: Set<String> = [
        // Hands — left/right/individual fingers/gestures
        "👋", "🤚", "🖐", "✋", "🖖",
        "🫱", "🫲", "🫳", "🫴", "🫵",
        "🫷", "🫸",
        "👌", "🤌", "🤏", "✌", "🤞",
        "🫰", "🤟", "🤘", "🤙",
        "👈", "👉", "👆", "🖕", "👇",
        "☝", "👍", "👎",
        "✊", "👊", "🤛", "🤜",
        "👏", "🙌", "🫶", "👐", "🤲",
        "🙏", "✍",
        // Body
        "💅", "🦵", "🦶", "👂", "🦻", "👃",
        // People — base glyphs (one per body)
        "👶", "🧒", "👦", "👧",
        "🧑", "👨", "👩",
        "🧓", "👴", "👵",
        // Gestures with body posture
        "🙍", "🙎", "🙅", "🙆", "💁",
        "🙋", "🧏", "🙇", "🤦", "🤷",
        // Roles (single-glyph, no ZWJ)
        "🤴", "👸", "👳", "👲", "🧕",
        "🤵", "👰", "🤰", "🫃", "🫄", "🤱",
        // Activity/motion
        "🚶", "🧍", "🧎", "🏃",
        "💃", "🕺", "🕴",
        "🧖", "🧘",
        "🛀", "🛌",
        // Sport
        "🏄", "🏊", "🚣", "🤽",
        "🚴", "🚵", "🏇", "🏂",
        "🏋", "🤸", "🤾", "⛹",
        "🤹", "🤺",
        // Fantasy
        "🧚", "🧛", "🧜", "🧝", "🧞", "🧟",
        // Nose/ear cleaning + Santa + Mrs Claus
        "🎅", "🤶", "🧙",
    ]
}
