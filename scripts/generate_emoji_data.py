#!/usr/bin/env python3
"""Generate EmojiData.swift from the official Unicode `emoji-test.txt`.

This replaces the old hand-maintained catalog (a frozen port of the Android
client) so the picker no longer silently lags new Unicode releases. Re-run it
whenever a new Unicode emoji version ships:

    python3 scripts/generate_emoji_data.py \
        --input emoji-test.txt --output EmojiData.swift

`emoji-test.txt` is published per-version at
https://www.unicode.org/Public/emoji/<version>/emoji-test.txt (also mirrored in
the unicode-org/unicodetools repo). Only `fully-qualified` rows are emitted, so
every emoji is in its canonical reaction-matching form.

Coverage decisions (see PR discussion):
  * All country / region / subdivision flags are included.
  * Skin-tone variants are excluded — the app applies tones via its own
    selector, so listing every Fitzpatrick variant would just bloat the grid.
  * Clock-face emoji (🕐–🕧) and Japanese squared ideograph buttons are
    excluded as rarely-used noise.
  * The Unicode `Component` group (skin-tone / hair modifiers) is excluded;
    those are not standalone emoji.
"""

from __future__ import annotations

import argparse
import re
import sys

# Unicode group -> app category name + tab-strip icon. Order here is the order
# categories appear in the picker. Groups not listed (e.g. "Component") are
# dropped entirely.
GROUP_MAP: list[tuple[str, str, str]] = [
    # "Expressions" matches the everyday word users reach for; "Smileys"
    # reads narrow when the section also holds animal faces and hands.
    # The Unicode group name stays "Smileys & Emotion" — only our display
    # label changes.
    ("Smileys & Emotion", "Expressions", "😀"),
    ("People & Body", "People", "👋"),
    ("Animals & Nature", "Animals", "🐶"),
    ("Food & Drink", "Food", "🍔"),
    ("Activities", "Activities", "⚽"),
    ("Travel & Places", "Travel", "✈️"),
    ("Objects", "Objects", "💡"),
    # ⁉️ (U+2049) — the heart icon used to belong here when CLDR's
    # heart subgroup landed in Symbols. After the move to the
    # Smileys/Expressions group (matching Unicode 16), pick a glyph
    # that actually evokes Symbols.
    ("Symbols", "Symbols", "⁉️"),
    ("Flags", "Flags", "🏁"),
]

# Override the Unicode-assigned group for a specific emoji. Used when
# CLDR's grouping disagrees with what users intuitively expect to find
# in a category — e.g. 💟 (HEART DECORATION) ships under "Smileys &
# Emotion" but it's a graphic symbol, not a face / emotion, so we
# show it in Symbols.
GROUP_OVERRIDE: dict[str, str] = {
    "💟": "Symbols",
}

# Fitzpatrick skin-tone modifiers.
SKIN_TONES = {chr(c) for c in range(0x1F3FB, 0x1F400)}

# Clock faces: 🕛🕧🕐🕜 … 🕚🕦 (U+1F550–U+1F567). Note ⌛ ⏳ ⏰ ⏱️ ⏲️ 🕰️ are NOT
# in this range and are kept — those are the genuinely useful timepieces.
CLOCK_FACES = {chr(c) for c in range(0x1F550, 0x1F568)}

# Japanese squared-ideograph "buttons" (🈁 🈂️ 🈚 🈯 🈲–🈺 🉐 🉑 ㊗️ ㊙️).
IDEOGRAPH_BUTTONS = {
    "\U0001F201", "\U0001F202", "\U0001F21A", "\U0001F22F",
    "\U0001F232", "\U0001F233", "\U0001F234", "\U0001F235",
    "\U0001F236", "\U0001F237", "\U0001F238", "\U0001F239",
    "\U0001F23A", "\U0001F250", "\U0001F251", "㊗", "㊙",
}

LINE_RE = re.compile(
    r"^([0-9A-Fa-f ]+);\s*(\S+)\s*#\s*(\S+)\s+E[\d.]+\s+(.*)$"
)


def excluded(emoji: str) -> bool:
    if any(t in emoji for t in SKIN_TONES):
        return True
    if emoji in CLOCK_FACES or emoji in IDEOGRAPH_BUTTONS:
        return True
    return False


def parse(path: str) -> dict[str, list[str]]:
    """Return {unicode_group_name: [emoji, ...]} in CLDR (file) order."""
    by_group: dict[str, list[str]] = {}
    seen: set[str] = set()
    cur_group: str | None = None
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("# group:"):
                cur_group = line.split(":", 1)[1].strip()
                continue
            if not line or line.startswith("#"):
                continue
            m = LINE_RE.match(line)
            if not m:
                continue
            _cps, qual, char, _name = m.groups()
            if qual != "fully-qualified":
                continue
            if cur_group is None or excluded(char) or char in seen:
                continue
            seen.add(char)
            by_group.setdefault(cur_group, []).append(char)
    return by_group


def swift_rows(emojis: list[str], indent: str = " " * 16, per_row: int = 5) -> str:
    rows = []
    for i in range(0, len(emojis), per_row):
        chunk = emojis[i : i + per_row]
        rows.append(indent + ", ".join(f'"{e}"' for e in chunk) + ",")
    # Strip the trailing comma on the very last emoji so the array literal is clean.
    if rows:
        rows[-1] = rows[-1].rstrip(",")
    return "\n".join(rows)


HEADER = '''import Foundation

struct EmojiCategory {
    let name: String
    let icon: String
    let emojis: [String]
}

/// Static catalog of unicode emojis for the reaction picker / library.
///
/// GENERATED FILE — do not edit by hand. Produced from the official Unicode
/// `emoji-test.txt` by `scripts/generate_emoji_data.py`; re-run that script to
/// pull in a new Unicode emoji release. Only fully-qualified forms are emitted,
/// so each entry is in its canonical reaction-matching form. Skin-tone variants
/// are intentionally excluded (the app applies tones via its own selector); so
/// are clock faces and Japanese ideograph buttons.
enum EmojiData {
    static let defaultQuickReactions: [String] = [
        "🧡", "👍", "👎", "🤙", "🚀", "🤗", "😂", "😢", "👨‍💻", "👀", "✅", "🤡", "🐸", "💀", "⚡", "🙏", "🍆"
    ]

    static let categories: [EmojiCategory] = [
'''

FOOTER = '''    ]

    /// Flat list of every unicode emoji across categories, in display order.
    static let allEmojis: [String] = categories.flatMap { $0.emojis }

    /// Lazy lowercased Unicode-name lookup keyed by emoji character. Built on
    /// first access using `String.applyingTransform(.toUnicodeName, ...)` so we
    /// don't ship a hardcoded keyword table — the OS already has the data.
    /// Used by `searchEmojis(_:)` for the library's search field.
    static let nameByEmoji: [String: String] = {
        var map: [String: String] = [:]
        for emoji in allEmojis {
            // `applyingTransform(.toUnicodeName)` returns sequences like
            // `\\N{FACE WITH TEARS OF JOY}` — keep the words, drop the wrapper.
            guard let raw = emoji.applyingTransform(.toUnicodeName, reverse: false) else { continue }
            let cleaned = raw
                .replacingOccurrences(of: "\\\\N{", with: "")
                .replacingOccurrences(of: "}", with: " ")
                .lowercased()
            map[emoji] = cleaned
        }
        return map
    }()

    /// Returns every emoji whose Unicode name contains `query` (case-insensitive
    /// substring match). Empty query returns an empty list — callers should
    /// short-circuit and show the categorized view instead.
    static func searchEmojis(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return allEmojis.filter { (nameByEmoji[$0] ?? "").contains(q) }
    }
}
'''


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", required=True, help="path to emoji-test.txt")
    ap.add_argument("--output", required=True, help="path to EmojiData.swift")
    args = ap.parse_args()

    by_group = parse(args.input)

    # Apply per-emoji group overrides (e.g. 💟 → Symbols). The override
    # value is the Unicode group name to land in, matching `GROUP_MAP`'s
    # first-tuple entries — NOT the display name.
    for char, target_group in GROUP_OVERRIDE.items():
        for grp in list(by_group.keys()):
            if char in by_group[grp]:
                by_group[grp].remove(char)
        by_group.setdefault(target_group, []).append(char)

    blocks = []
    total = 0
    for group, name, icon in GROUP_MAP:
        emojis = by_group.get(group, [])
        if not emojis:
            print(f"warning: no emoji for group {group!r}", file=sys.stderr)
            continue
        total += len(emojis)
        block = (
            f'        EmojiCategory(\n'
            f'            name: "{name}",\n'
            f'            icon: "{icon}",\n'
            f'            emojis: [\n'
            f"{swift_rows(emojis)}\n"
            f'            ]\n'
            f'        )'
        )
        blocks.append(block)
        print(f"  {name:10s} {len(emojis):4d}", file=sys.stderr)

    body = ",\n".join(blocks) + "\n"
    with open(args.output, "w", encoding="utf-8") as fh:
        fh.write(HEADER + body + FOOTER)
    print(f"wrote {args.output}: {total} emoji across {len(blocks)} categories",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
