# Account Switcher Sheet — iOS implementation plan

## Context

Both Android apps (wisp and dark-wisp) just replaced their drawer's inline expand/collapse account picker with a proper modal bottom sheet, added an icon-only "People + N" badge affordance in the drawer header, and added account reordering (move up/down, persisted). iOS has the exact same pre-port shape — an inline `accountsExpanded` boolean toggled from a "+N" pill/chevron in the header, expanding an inline `accountPickerSection`. This plan ports the same UX to iOS: sheet presentation, header badge, and reordering.

iOS's npub display already fixed on Android during this port (drawer header and account rows were showing raw hex instead of npub when a profile has no NIP-05) does **not** apply here — confirmed `SidebarDrawerView.swift`'s `subtitleText` and `accountPickerSection` already use `Nip19.shortNpub(hex:)` / `npub.prefix(16)`, never raw hex. No fix needed on that front.

## Current state (confirmed in `/Users/daniel/GitHub/wisp-ios`)

**`SidebarDrawerView.swift`**:
- `@State private var accountsExpanded = false` (line 32)
- `accounts: [String]` computed property (lines 61-65) — reads `NostrKey.accounts()` and ensures the current `pubkey` is present (inserted at index 0 if missing)
- Header (lines 193-268): avatar button, then either a solo "+" circle button (`otherCount <= 0`, lines 203-214) or a "+N" capsule + chevron that toggles `accountsExpanded` (lines 215-232), then toolbar icons (Tor toggle, theme toggle, QR button)
- `if accountsExpanded { accountPickerSection.transition(.opacity) }` (lines 115-118) — conditionally rendered inline, directly in the main `ScrollView`'s `VStack`
- `accountPickerSection` (lines 325-385): `ForEach` over `accounts`, each row calls `NostrKey.switchAccount(pubkey:)` on tap (not `loadAccount` — the comment at lines 330-334 explains why: switching must update the keychain's `active` slot and `cachedActive` before the loading splash reads `NostrKey.load()`, otherwise the splash flashes the previous account's avatar). Row shows `CachedAvatarView`, display name (`ProfileRepository.shared.get(acctPubkey)?.displayString ?? Nip19.shortNpub(hex:)`), watch-only eye icon (`NostrKey.isWatchOnly(pubkey:)`, line 79 in `NostrKey.swift`), active checkmark. Then an "Add Account" row (lines 364-382).
- `.sheet(isPresented: $showQRSheet) { ProfileQrSheet(...) }` (lines 179-188) is the existing sheet-presentation convention to mirror.

**`ProfileQrSheet.swift`**: `.presentationDetents([.large])` + `.presentationDragIndicator(.visible)` (lines 99-100) — the direct SwiftUI equivalent of Android's `ModalBottomSheet(skipPartiallyExpanded = true)`.

**`NostrKey.swift`**:
- `accounts()` (lines 101-103): `UserDefaults.standard.stringArray(forKey: "wisp_accounts") ?? []` — a flat ordered `[String]` of pubkeys, no per-account struct.
- `switchAccount(pubkey:)` (lines 94-99), `loadAccount(pubkey:)` (lines 90-92), `isWatchOnly(pubkey:)` (line 79) — existing helpers to reuse as-is.
- No `moveAccount` yet.

**`ProfileRepository.swift`**: `func get(_ pubkey: String) -> ProfileData?` (line 18) — cached profile lookup, used for avatar/display name of non-active accounts.

## Plan

### 1. New file: `AccountSwitcherSheet.swift`

A new SwiftUI view, presented the same way `ProfileQrSheet` is:

```swift
struct AccountSwitcherSheet: View {
    let accounts: [String]
    let activePubkey: String
    let activeProfile: ProfileData?
    let onSwitchAccount: (Keypair) -> Void
    let onAddAccount: () -> Void
    let onMoveAccount: (String, Int) -> Void  // pubkey, offset (-1 up, +1 down)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Title "Accounts", then a List/ScrollView capped at ~45% of
        // screen height (GeometryReader or UIScreen.main.bounds.height * 0.45)
        // so the "Sign in with another account" row stays pinned below it —
        // mirrors Android's heightIn(max = screenHeightDp * 0.45f).
        //
        // Each row: CachedAvatarView, display name, watch-only eye icon,
        // active checkmark, up/down chevron.up/chevron.down buttons
        // (disabled at list ends, hidden entirely when accounts.count <= 1) —
        // ported straight from accountPickerSection's row content.
        //
        // Divider, then "Sign in with another account" row — ported from
        // the existing "Add Account" row.
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
}
```

Row switch logic must preserve the `switchAccount` (not `loadAccount`) ordering comment from the existing code — don't simplify that away.

### 2. `SidebarDrawerView.swift` changes

- Replace `@State private var accountsExpanded = false` with `@State private var showAccountSwitcher = false`.
- Replace the header's solo-"+"-vs-"+N"-pill branching (lines 203-232) with a single icon-only affordance: SF Symbol `person.2` (or `person.2.fill`) in a capsule, with a "+N" badge shown only when `otherCount > 0` — one code path regardless of count, same simplification Android made. Tapping it sets `showAccountSwitcher = true`.
- Delete the `if accountsExpanded { accountPickerSection... }` block (lines 115-118) and the `accountPickerSection` computed property (lines 325-385) entirely — its content moves into `AccountSwitcherSheet`.
- Add `.sheet(isPresented: $showAccountSwitcher) { AccountSwitcherSheet(accounts: accounts, activePubkey: pubkey, activeProfile: profile, onSwitchAccount: onSwitchAccount, onAddAccount: onAddAccount, onMoveAccount: { pk, offset in NostrKey.moveAccount(pubkey: pk, offset: offset) }, ...) }` alongside the existing QR sheet modifier.
- Check whether anything else in this file was conditionally gated on `accountsExpanded` (Android's dark-wisp had an Anon Mode toggle sharing the same collapse state that needed hoisting out — confirm iOS doesn't have an equivalent before assuming a straight deletion is safe).

### 3. `NostrKey.swift` — add `moveAccount`

Mirror `KeyRepository.moveAccount` from both Android apps, adapted to iOS's flat pubkey-array persistence (no JSON-encoded struct list to update):

```swift
static func moveAccount(pubkey: String, offset: Int) {
    var list = accounts()
    guard let index = list.firstIndex(of: pubkey) else { return }
    let target = index + offset
    guard target >= 0, target < list.count else { return }
    list.remove(at: index)
    list.insert(pubkey, at: target)
    UserDefaults.standard.set(list, forKey: "wisp_accounts")
}
```

### 4. Thread `onMoveAccount` to wherever `SidebarDrawerView` is instantiated

`onSwitchAccount` and `onAddAccount` are already closures passed into `SidebarDrawerView` from its parent (`var onSwitchAccount: (Keypair) -> Void = { _ in }`, `var onAddAccount: () -> Void = {}`, lines 10-11). Find that call site (grep for `SidebarDrawerView(` — likely `MainView.swift` or `ComposeView.swift`, both of which reference account-picker-adjacent code per the earlier repo-wide grep) and confirm whether `onMoveAccount` needs to be threaded through further, or whether `NostrKey.moveAccount` can be called directly from inside `AccountSwitcherSheet` without a closure indirection (simpler than Android, since iOS's `NostrKey` is a static namespace, not an instance-scoped repository — check whether calling it directly from the sheet, bypassing a closure entirely, breaks any existing pattern before deciding).

## Out of scope

Same carve-outs as the Android port and already confirmed against this repo:
- No login-button recolor — iOS uses its own theme system (`Color.wispPrimary`, etc.), not zap-cooking's hardcoded food-brand hex.
- No splash food-photo/tagline changes — `SplashViewModel.swift` only populates generic `profilePictures`, no `#foodstr` content.
- No npub-vs-hex display fix — already correct on iOS (see Context above).

## Verification

- Build in Xcode, run on simulator/device.
- Open the drawer with 2+ signed-in accounts:
  - Header shows the people-icon badge with "+N"; tapping it presents the sheet (no more inline expand).
  - Sheet lists all accounts with correct active checkmark, watch-only badge where applicable, up/down buttons disabled at list ends and hidden entirely with only 1 account.
  - Tapping a non-active account switches to it (verify via the `switchAccount`-before-splash-read comment's underlying behavior: the new account's avatar should show immediately, not the previous one, through the loading transition) and dismisses the sheet.
  - Tapping up/down reorders and persists across app relaunch.
  - "Sign in with another account" row starts the add-account flow and dismisses the sheet.
- Confirm no other code path still references `accountsExpanded` or `accountPickerSection` after the edit (`grep -n "accountsExpanded\|accountPickerSection" SidebarDrawerView.swift` should return nothing).
