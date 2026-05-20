# ZapSheet Redesign Spec

## Problem

The current sheet is a tall scroll view. On a standard iPhone, reaching the message
field or changing zap type requires scrolling — and raising the keyboard pushes
everything above the fold. The hero (icon + "Send Zap" title + giant number) burns
~200 pt before the user can do anything useful.

## Goal

Fit the full interaction — recipient, amount selection, message, privacy — in the
visible area above the keyboard, with no scrolling required for the happy path.

---

## Layout (top → bottom)

### 1. Navigation bar (unchanged)
- Left: `Close` button
- Center: nothing (no title)
- Right: `Edit` (tapping opens `EditPresetsSheet` — same as today)

### 2. Recipient row  (~44 pt)
Compact single-line HStack, no section label:

```
[avatar 32pt]  corndalorian          ··· (overflow icon, tap to copy lud16)
               corndalorian@primal.net  ← caption, secondary color
```

No background card. Light separator line below if desired. Keep it tight.

### 3. Amount area  (~100 pt total)

**Big tappable number** centered, no icon, no "Send Zap" label:

```
         84
        sats          ← hidden in fiat mode
```

- Font: `system(size: 56, weight: .bold, design: .rounded)`, `wispZapColor`
- Tapping the number focuses the hidden `TextField` (same existing behavior —
  `isCustom = true`, seed `customAmountText`, `amountFocused = true`)
- `contentTransition(.numericText)` animation on change (keep existing)

**Preset pills** — single horizontal `ScrollView(.horizontal, showsIndicators: false)` strip
immediately below the number, instead of the current wrapping `FlowLayout`:

```
  [ 10 ]  [ 21 ]  [ 84 ]  [ 100 ]  [ 500 ]  [ 1.0k ]  [ 5.0k ]  [ Custom ]
```

- Selected pill: filled `wispZapColor` capsule, white text (same as today)
- Unselected: `wispSurfaceVariant.opacity(0.5)` capsule
- `Custom` pill stays at the end; when `isCustom && amountSats > 0` it shows the
  formatted amount (same as today)
- "Save as Preset" affordance: keep the existing `canSaveAsPreset` logic, but
  surface it as a small `+` icon button that appears inside/beside the Custom
  pill when applicable — not a separate full-width row

**Custom amount text field** — always rendered but `opacity(0)` / `frame(height: 0)`
when not `isCustom`. This avoids the layout jump when the field appears. The actual
number pad input goes here (fiat binding and sats binding logic unchanged).

### 4. Message field  (~56 pt)
Always visible single-line `TextField`, no section label:

```
  [ Message (optional)                          ]
```

- Same `wispSurfaceVariant` rounded-rect background
- `.submitLabel(.done)` to dismiss keyboard

### 5. Bottom bar  (pinned via `safeAreaInset(edge: .bottom)`)

HStack with two elements side by side:

```
  [ 👁 ]   [  ⚡ Zap 84 sats  ──────────────── ]
```

Left side — **Privacy chip** (minified):
- Small rounded-rect button showing the current type icon only (`eye` / `eye.slash` / `lock`)
- Tapping cycles `Public → Anonymous → Private → Public`
- Background: `wispSurfaceVariant.opacity(0.4)`, size ~44×44
- On long-press (or secondary tap): show a small `Menu` with all three options labeled,
  so power users can jump directly without cycling

Right side — **Zap button** (same as today, fills remaining width):
- `⚡ Zap 84 sats` / `Send $0.84` (fiat mode)
- `wispZapColor` fill, white text, `cornerRadius: 14`
- Disabled + dimmed when `!canZap`

The two elements share the same height (~54 pt) with a small gap (~10 pt) between them.

---

## States & edge cases

| State | Behavior |
|---|---|
| No `lud16` | Recipient row shows red "No lightning address" text; Zap button disabled |
| Keyboard raised | Preset strip + message field stay above keyboard; no scroll needed |
| `isCustom` | Big number updates live as digits typed; Custom pill goes orange |
| `canSaveAsPreset` | `+` badge appears on Custom pill; tap adds to `presetsRaw` |
| Fiat mode | Big number shows `$0.84`; "sats" label hidden; field uses cents-register binding |

---

## What to remove

- Lightning bolt icon above the amount (redundant — it's on the Zap button)
- "Send Zap" / "Send Money" title text
- `QUICK AMOUNTS` section label and `Edit` link in header (Edit moves to nav bar)
- `TYPE` section label and full-width `Picker(.segmented)` — replaced by privacy chip
- `RECIPIENT` section label and background card
- `MESSAGE (OPTIONAL)` section label
- "Save as Preset" full-width `HStack` row — replaced by `+` badge on Custom pill

---

## Files to change

| File | Change |
|---|---|
| `ZapSheet.swift` | Full layout rewrite — body, hero, presets, message, bottom bar. Logic (`send()`, bindings, `heroAmountText`, fiat helpers) **unchanged**. |
| `EditPresetsSheet` | No changes — still presented from nav-bar `Edit` button. |

---

## Implementation notes

- Keep all existing `@State`, `@AppStorage`, `@FocusState` vars as-is.
- The privacy chip cycling: `zapType = ZapType.allCases[(ZapType.allCases.firstIndex(of: zapType)! + 1) % ZapType.allCases.count]`
- Horizontal preset strip: wrap pills in `ScrollView(.horizontal)` → `HStack(spacing: 8)`.
  No `FlowLayout` dependency needed.
- Hidden custom field trick: render outside the visible stack at `frame(width: 0, height: 0).clipped()`, keep `focused($amountFocused)` on it. Tapping the big number still triggers focus via `amountFocused = true`.
- `withAnimation(.easeInOut(duration: 0.15))` on `isCustom` toggle to animate the Custom pill highlight.
