# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project

`wisp` is a SwiftUI iOS Nostr client. Bundle id `barrydeen.wisp`. Swift 5, iOS deployment target 26.4, supports iPhone/iPad/visionOS (`SUPPORTED_PLATFORMS = iphoneos iphonesimulator macosx xros xrsimulator`).

SwiftPM dependencies (resolved via Xcode, no `Package.swift` exists):
- `objectbox-swift-spm` — embedded event database
- `swift-secp256k1` (21-DOT-DEV) — Schnorr signing/verification + ECDH
- `breez-sdk-spark-swift` — Spark (self-custodial Lightning) wallet
- `giphy-ios-sdk` — GIF picker

## Build / run / test

This is an Xcode project — there is no `Package.swift`, no `make`, no CLI script. Open `wisp.xcodeproj` in Xcode, or use `xcodebuild`:

```
xcodebuild -project wisp.xcodeproj -scheme wisp -destination 'platform=iOS Simulator,name=iPhone 16' build
xcodebuild -project wisp.xcodeproj -scheme wisp -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Tests under `wispTests/` use the Swift Testing framework (`import Testing`, `@Test`), not XCTest. Substantive coverage lives in `Nip44Tests`, `NSpamTests`, `RelaySettingsTests`, `SafetyTests`. UI tests under `wispUITests/` are XCTest.

## Source layout — important

The Xcode project mixes two file-management styles:

- `wisp/`, `wispTests/`, `wispUITests/` are `PBXFileSystemSynchronizedRootGroup`s — anything dropped into those folders on disk is automatically part of the target. The `wisp/` folder holds `wispApp.swift` (the `@main`), `ContentView.swift`, `Assets.xcassets`, `Resources/`, and most of the top-level UI screens (sidebar, compose FAB, group/DM views, thread view, splash, loading, live-stream views under `wisp/Live/`).
- **Most domain code (view models, repositories, NIP implementations, crypto) lives at the repo root, not under `wisp/`** (e.g. `FeedViewModel.swift`, `RelayPool.swift`, `NostrEvent.swift`, `EventStore.swift`, `Nip17.swift`, `Schnorr.swift`, …). These are added to the target via explicit `PBXFileReference` entries in `wisp.xcodeproj/project.pbxproj`. **When you add a new root-level Swift file, you must also add it to `project.pbxproj`** — it will not be picked up automatically. Files inside `wisp/` are exempt from this.

`EntityInfo-wisp.generated.swift` exists in two places: the repo root (compiled into the target) and `generated/` (output of the ObjectBox generator). When the entity model changes, the generator writes to `generated/` and `model-wisp.json` is updated; the root copy must be replaced to match.

## Bundled secrets (no xcconfig)

API keys ship as gitignored text files in `wisp/Resources/`:

- `wisp/Resources/breez-api-key.txt` (Breez Spark SDK)
- `wisp/Resources/giphy-api-key.txt` (Giphy)

Both have `.example` siblings checked in. `.gitignore` excludes the real files. `BreezConfig` and `GiphyConfig` read them from the bundle at startup, falling back to empty/hardcoded values. Do **not** introduce xcconfig + Info.plist injection for new secrets — follow the bundled-resource pattern.

`wisp/Resources/nspam/` ships the on-device LightGBM spam model (`model.txt`, `calibration.npz`) and is checked in. `wisp/Resources/bip39-english.txt` is the BIP-39 wordlist.

## App flow

App flow is driven by a single `@State` enum in `wisp/ContentView.swift`:

```
splash → (login via nsec/mnemonic) → onboarding → main
                                   ↘ (returning user, onboarding done) → loading → main
```

`MainView` is a five-tab `TabView` (home / wallet / search / messages / notifications). Each tab owns its own `NavigationStack`, and navigation pushes typed `Hashable` route values (`ProfileRoute`, `ThreadRoute`, `HashtagFeedRoute`, `NoteListFeedRoute`, `PeopleListFeedRoute`, `TrendingFeedRoute`, `LiveStreamRoute`) dispatched via `.navigationDestination(for:)`. A left-edge `SidebarDrawerView` overlays the active tab for account switching, settings sheets, and tab selection.

Account state is keyed by hex pubkey throughout. `NostrKey` stores the active keypair plus a per-pubkey list in the iOS Keychain (service `com.wisp.nostr`), and uses `UserDefaults` keys of the form `onboarding_done_<pubkey>`, `follow_pubkeys_<pubkey>`, `relay_scoreboard_v1_<pubkey>`, `latest_feed_ts_<pubkey>`, `profile_<pubkey>`, etc.

## Architecture

### Outbox-model relay routing (NIP-65)

This is the central architectural idea for the home feed. Rather than fanning every query out to every relay:

1. **Onboarding** (`OnboardingViewModel.startOutboxBuilding`): hit a hardcoded set of indexer relays (`indexer.nostrarchives.com`, `indexer.coracle.social`, `relay.damus.io`, `relay.primal.net`) to fetch the user's kind-0 (profile), kind-3 (contacts), then kind-10002 (relay lists) for every followed pubkey, in batches of 150.
2. **`RelayScoreBoard`** inverts that data into `relayAuthors: [relayURL: Set<authorPubkey>]`, taking up to `redundancy=3` write relays per author, then ranks relays by author count. Persisted to UserDefaults as a tab-delimited string list.
3. **Feed loading** (`FeedViewModel.loadFeed`): walks the top-20 scored relays, chunks each relay's authors into groups of 200, fires one `REQ` per (relay, author-chunk) in parallel via `withTaskGroup`, plus a safety-net query against `relay.damus.io` with the first 200 follows. The same indexer set is reused for kind-0 profile lookups.

If you add new feed surfaces, follow this same pattern: read `RelayScoreBoard.load(pubkey:)`, build relay-scoped author chunks, fan out via `RelayPool.query`. Do not re-query indexer relays for note feeds — they are for discovery (kinds 0/3/10002), not content.

### Relay I/O — two pools, different lifecycles

`RelayPool.query` is a one-shot, fire-and-collect helper for feed/profile/list queries:

- Opens one `URLSessionWebSocketTask` per relay, sends a single `REQ`, accumulates `EVENT`s in an `EventCollector` actor, and stops once **any** relay sends `EOSE` (plus a 1.5s grace window for stragglers) or the overall timeout fires (default 8s, callers commonly pass 10–15s).
- Deduplicates by event id inside the collector. **Signature verification is not performed on incoming events** anywhere in the app — `Schnorr.verify` is only exercised by tests. Treat relay output as untrusted but currently unverified.
- All sockets are cancelled at end of call. There is no persistent connection pool; every query opens fresh sockets.

`GroupRelayPool` is the long-lived counterpart used for NIP-29 groups and any other surface that needs persistent subscriptions (live streams, ad-hoc subscribers like `FeedViewModel.fetchOnlineCount`). It keeps per-relay sockets open with auto-reconnect, demultiplexes EVENT/AUTH/EOSE/NOTICE/OK frames inline, exposes per-subscription `AsyncStream`s, refcounts relay usage so unused relays drop, handles NIP-42 AUTH challenges automatically (via `Nip42.buildAuthEvent`), and supports `publishWithAuthRetry` for `auth-required` rejections.

### Storage layers (four of them — pick the right one)

- **ObjectBox event store** (`EventStore`, `EventEntity`) — durable cache of nostr events. Only kinds in `persistedKinds = {0, 1, 6, 7, 9735, 20, 21, 22}` are written. `EventStore` is an `actor`; access via `EventStore.shared`. `seedCache` returns kinds 1/6/20 ordered by `createdAt` desc for instant feed display. `prune` runs opportunistically and protects the active user's pubkey.
- **ObjectBox group store** (`GroupStore`, `GroupMetaEntity`, `GroupMessageEntity`) — separate boxes for NIP-29 group metadata and chat messages. Keyed by `groupRoomKey(ownerPubkey, relayUrl, groupId)` because NIP-29 groups are relay-scoped. Messages buffer in-memory and flush in 200ms windows or every 50 messages.
- **Per-account SQLite** (`SocialGraphDb` → `social_graph_<pubkey>.db`) — adjacency table for follows-of-follows, used by `SocialGraphRepository` to compute the "qualified" extended network (≥10 mutual followers) for FoF visualization and Extended Feed relay set-cover.
- **UserDefaults** — per-user metadata (follows, relay scoreboard, latest feed timestamp, last-seen profile dicts, onboarding flag, app settings, last-read timestamps for DMs/notifications).
- **Keychain** — only the keypair (`privkey:pubkey` string), accessible `WhenUnlockedThisDeviceOnly`. Wallet seed mnemonics use `WalletKeychain` (separate keychain item).

`ProfileRepository` is `@MainActor`-isolated, holds an in-memory cache, and writes a flattened dict to UserDefaults — it does *not* go through ObjectBox. `DmRepository` is also in-memory only (cleared on account switch) — see DMs section below.

### ObjectBox setup

`ObjectBoxSetup.setUp()` is called from `wispApp.init` and creates the store under `Application Support/wisp/objectbox/`. The store is held as a force-unwrapped static (`store: Store!`) — anything that touches `box(for:)` before `setUp()` runs will crash. `EventStore` and `GroupStore` lazily resolve their boxes on first use.

When any entity (`EventEntity`, `GroupMetaEntity`, `GroupMessageEntity`, …) changes shape, the ObjectBox Swift generator must regenerate `EntityInfo-wisp.generated.swift` (write the new copy to both `generated/` and the repo root) and update `model-wisp.json`. **Never hand-edit `model-wisp.json`** — its IDs are load-bearing for schema migration. Keep it checked in.

### Crypto

The crypto stack changed: signing and verification are now real, backed by `swift-secp256k1` (the P256K module).

- `Schnorr.swift` — `sign`, `verify`, and `ecdhRawX` (raw x-coordinate ECDH for NIP-44). Signing is reached via `NostrEvent.sign`, which is called by compose, reactions, zaps, drafts, mutes, follows, NWC requests, and DM gift-wraps.
- `Secp256k1.swift` — the older pure-Swift public-key derivation; still used for nsec→pubkey at login time.
- `Bip39.swift` — pure-Swift 12/15/18/21/24-word mnemonic generation/validation (SHA-256 checksum). Used for Spark wallet recovery; the mnemonic is fed to the Breez SDK to derive the wallet.

Even though `Schnorr.verify` exists, **incoming events from relays are not signature-verified** today. If you add code that consumes events from untrusted sources outside the existing pipeline, decide explicitly whether to verify.

### DMs (NIP-17 primary, NIP-04 only for NWC)

- `Nip44.swift` — versioned NIP-44 v2 (ECDH via `Schnorr.ecdhRawX`, HKDF, ChaCha20 + HMAC-SHA256, padding). `ChaCha20.swift` is the stream cipher used by NIP-44.
- `Nip17.swift` — three-layer envelope: rumor (unsigned inner kind 14/15/etc.) → seal (kind 13, signed by sender, encrypted to recipient) → gift wrap (kind 1059, signed by ephemeral key, encrypted to recipient). Optional NIP-13 PoW on the wrap.
- `Nip04.swift` — legacy AES-256-CBC. **Only used for NIP-47 NWC** wallet services that don't advertise `nip44_v2`. Do not use it for new DM features.
- `MessagesViewModel` subscribes to kind-1059 with `p` = own pubkey on the recipient's kind-10050 DM inbox relays (falling back to NIP-65). No `since` filter — gift-wrap timestamps are randomized.
- `DmRepository` is in-memory; only `lastReadTimestamp` and `latestWrapTimestamp` are persisted to UserDefaults. DMs are **not** written to ObjectBox.
- Group-chat semantics (multi-recipient DMs) are implemented by including all participants as `p` tags on the rumor.

### NIP coverage map

The `Nip*.swift` files at the repo root each implement one NIP. Quick map: 04 (legacy DMs, NWC only), 09 (deletion), 10 (replies/threading), 13 (PoW mining), 17 (gift-wrapped DMs), 18 (reposts), 19 (bech32), 25 (reactions), 29 (relay-scoped groups), 37 (encrypted drafts, kind 31234), 42 (relay AUTH), 44 (encryption v2), 47 (NWC), 51 (lists — split across `Nip51Lists`/`Nip51Groups`/`Nip51Hashtags`/`Nip51UserLists`/`Nip51Mute`), 53 (live activities, in `wisp/Live/`), 57 (zaps), 65 (relay list metadata), 68 (picture-first), 69 (zap polls), 71 (video events), 78 (app-specific data — wallet backup), 88 (polls).

### Wallets and zaps

`WalletMode` is a two-case enum: `.nwc` and `.spark`. `WalletStore` is the orchestrator.

- **Spark** wraps the Breez Spark SDK (`BreezSdkSpark`). API key from `wisp/Resources/breez-api-key.txt`. Mnemonic seed is generated/restored via `Bip39`, stored in `WalletKeychain`, and **backed up encrypted to relays as a NIP-78 kind-30078 event** (`Nip78Backup`, d-tag `spark-wallet-backup:<walletId>`, NIP-44 self-encrypted).
- **NWC** is a home-grown NIP-47 implementation (`NwcWallet`, `NwcConnection`) over a relay socket — no SDK. Uses NIP-04 if the wallet doesn't support NIP-44 v2.
- **Zaps** (`ZapSender`, `Nip57`): resolve LNURL from recipient's `lud16`, build signed kind-9734 zap request, fetch bolt11 invoice from LNURL callback, pay via active wallet. `paymentHash → recipientPubkey` is recorded in UserDefaults for history.

### Blossom media + Giphy

- `BlossomClient.upload` walks the user's server list and tries `/media` then `/upload` per server, returning on first success. Server list is a kind-10063 event published to write relays, cached in UserDefaults; default fallback `https://blossom.primal.net`. Edited via `MediaServersView`.
- Giphy is a separate path: the GIPHY iOS SDK shows the picker, and `GifBlossomUploader.rehost` downloads the Giphy CDN bytes and re-uploads to Blossom, falling back to the original Giphy URL on failure.

### NSpam (on-device LightGBM) + WoT filtering

- `SpamScorer` loads `nspam/model.txt` and `nspam/calibration.npz` from `wisp/Resources/nspam/`. `NSpamFeatures` extracts a fixed-size sparse feature vector (n-grams + structural metrics) — match Android's regexes exactly when changing it. Inference runs on `Task.detached(priority: .utility)`. Threshold ≥ 0.7 is spam; per-pubkey results are cached.
- `SafetyFilter` is a lockless snapshot reader called from `FeedViewModel`, `NotificationsViewModel`, `MessagesViewModel`. It applies mute lists (pubkeys/words/threads from `MuteRepository`, NIP-51 kind 10000, NIP-44-encrypted), spam scores, and an optional Web-of-Trust gate (drop senders not in the qualified extended network from `SocialGraphRepository`). Certain kinds (0, 3, 4, 10002, 1059, …) are exempt from the WoT gate.

### Concurrency conventions

- View models are `@Observable @MainActor final class` (Observation framework, not Combine).
- Storage and shared collectors are `actor`s (`EventStore`, `GroupStore`, `EventCollector`, `WalletStore`, `SpamScorer`).
- `NostrEvent` is a value type with a `nonisolated init` so it can cross actor boundaries freely.
- Feed/relay work uses `withTaskGroup` for parallel fans; respect cancellation in any new long-running task.
- ML inference and other CPU-bound work goes on `Task.detached(priority: .utility)` to keep main thread free.

### Themes and fonts

`AppSettings` (Observable, @MainActor) persists UI prefs to UserDefaults. `Themes.swift` ships five presets (Custom, Nord, Dracula, Gruvbox, Monochrome), each with light/dark palettes; the resolved theme is injected via `@Environment(\.theme)`. `AppFont` provides semantic font sizes that scale +2pt when `largeText` is on. Per-theme accent color is user-configurable.

### Content rendering

`ContentParser` tokenizes note content into `[ContentSegment]` (text, image/video/audio with NIP-92 imeta metadata, links with previews, nostr bech32 entities, custom emoji shortcodes, hashtags, BOLT11 invoices). `RichContentView` splits segments into inline rows (rendered through `RichInlineTextView`, a UITextView wrapper with NSAttributedString and tappable link ranges) and block rows (`InlineImageView`, `InlineVideoView`, `InlineAudioView`, `LinkPreviewView`, `QuotedNoteView`).
