# Wisp

A minimal, performant iOS client for the [Nostr](https://nostr.com) protocol. Built natively with SwiftUI, Wisp prioritizes decentralization, intelligent relay routing, strong privacy, and a clean native experience across iPhone, iPad, and Apple Vision Pro.

> **Status:** v1.0 — initial release; actively developed.

---

## Table of Contents

- [Why Wisp](#why-wisp)
- [Key Features](#key-features)
- [Architecture](#architecture)
- [Supported NIPs](#supported-nips)
- [Getting Started](#getting-started)
- [Building from Source](#building-from-source)
- [Contributing](#contributing)
- [Tech Stack](#tech-stack)
- [License](#license)

---

## Why Wisp

Most Nostr clients treat relays as interchangeable dumb pipes and lean on a small handful of "mega-relays." Wisp takes a different approach — it implements the full outbox/inbox relay model with reliability scoring, routes messages based on where users actually publish and read, and is built so that decentralization is the default path, not an opt-in.

The result is faster event delivery, less wasted bandwidth, and a client that actively reinforces the architecture Nostr was designed for. Wisp is built to be fast, lightweight, and respectful of both your device and the relay network — and it ships natively for iPhone, iPad, and Apple Vision Pro from a single Swift codebase.

---

## Key Features

### Intelligent Outbox/Inbox Relay Routing

Wisp implements a full NIP-65 outbox/inbox model with relay scoring:

- **Outbox reads** — fetches a user's posts from their *write relays* (where they actually publish), not from a hardcoded list
- **Inbox writes** — delivers replies, reactions, and DMs to the recipient's *read relays* so they actually see them
- **Relay scoring** — `RelayScoreBoard` ranks relays by author coverage and picks the smallest useful set for each query (top-20 by default for the home feed)
- **Two-pool model** — `RelayPool` opens fresh sockets per query for one-shot reads (feeds, profiles, threads), while `GroupRelayPool` keeps long-lived sockets for groups and other persistent subscriptions, with auto-reconnect, refcounted relay usage, and inline frame demultiplexing
- **NIP-42 authentication** — handles relay AUTH challenges automatically and supports `auth-required` retries on publish, used by groups, DMs, and the scheduler relay
- **Indexer-vs-content separation** — discovery queries (kinds 0/3/10002) hit a small set of indexer relays; content queries follow each author's own outbox

### Privacy & Private Messaging

- **NIP-17 gift-wrap DMs** — three-layer privacy model (rumor → seal → gift wrap) with timestamp randomization and optional NIP-13 PoW on the wrap
- **NIP-44 v2 encryption** — ECDH (raw x-coordinate) + HKDF + ChaCha20 + HMAC-SHA256, with variable-length padding and conversation-key caching
- **Dedicated DM inbox relays** — receive DMs on your kind-10050 relay set when set, with NIP-65 fallback
- **Group DMs** — multi-recipient gift-wrapped chats by including all participants as `p` tags on the rumor
- **Anti-impersonation** — seal author is matched against rumor author on every received message
- **NIP-04 only as legacy fallback** — used solely for NIP-47 wallet services that don't yet advertise `nip44_v2`

### Lightning & Zaps

A built-in non-custodial Lightning wallet powered by [Breez SDK (Spark)](https://github.com/breez/breez-sdk-spark), plus NWC as an alternative:

- **Embedded Spark wallet** — self-custodial Lightning that runs on-device
- **12-word seed backup** — standard BIP-39 mnemonic recovery
- **Encrypted relay backup** — wallet credentials encrypted to your own pubkey (NIP-44) and published as a NIP-78 app-data event (kind 30078) so you can restore from any session; format-compatible with the Android Wisp client and other Spark wallets
- **NWC (NIP-47)** — connect any `nostr+walletconnect://` compatible wallet as an alternative
- **Zaps** — send (NIP-57), display zap receipts on the feed, and vote in **zap polls** (NIP-69)
- **Transaction history** with counterparty resolution from zap receipts
- **Fiat conversion** — sats ⇄ fiat display with cached exchange rates
- **QR scanning** for invoices and addresses
- **Payment targets** (NIP-A3, kind 10133) — publish `payto:` addresses for other chains and payment apps (Bitcoin, Monero, Ethereum, Cash App, …) from Settings, and pay anyone else's from their profile or the zap sheet

### Safety & Content Filtering

- **nspam ML classifier** — on-device LightGBM spam model with MurmurHash3 feature hashing; filters out low-quality content without sending anything off-device
- **Social graph filtering** — optional Web-of-Trust scope built from an on-device social graph database (per-account SQLite), restricting feeds to "follows + follows-of-follows" with ≥10 mutual followers
- **Mute lists** (NIP-51 kind 10000) for blocking pubkeys, words, and threads — encrypted with NIP-44 and synced via Nostr
- All safety lists sync across clients via published Nostr events

### Rich Content Types

- **Notes** — NIP-01 short text notes with full inline rendering
- **Picture posts** (NIP-68, kind 20) and **video posts** (NIP-71, kinds 21/22) with NIP-92 imeta parsing, blurhash, and thumbnails
- **Live streams** (NIP-53, kind 30311) — watch and chat on live activities
- **Polls** (NIP-88, kinds 1068/1018) — create and vote on single- or multiple-choice polls
- **Reposts** (NIP-18) with attribution
- **Emoji reactions** (NIP-25) with **custom emoji packs** (NIP-30)
- **Reply threading** (NIP-10) with root resolution and marked e-tags
- **Drafts** (NIP-37, kind 31234) — save unfinished posts encrypted to yourself and synced through your relays so they follow you across devices
- **Scheduled posts** — publish in the future via a dedicated NIP-42-authenticated scheduler relay
- **Proof-of-work** (NIP-13) — optional PoW mining with configurable difficulty and cooperative cancellation

### Groups & Communities

- **NIP-29 relay-based groups** — join, browse, chat (kind 9), with metadata and member events
- **Group persistence** — joined groups and recent messages are cached locally in a dedicated ObjectBox store, scoped by `(ownerPubkey, relayUrl, groupId)` since NIP-29 groups are relay-scoped by design
- **Persistent group sockets** — `GroupRelayPool` keeps connections open with auto-reconnect, NIP-42 AUTH, and refcounted relay teardown
- **AUTH-gated publishes** — group joins, creates, and admin operations wait for NIP-42 AUTH and retry on `auth-required`

### Media & Storage

- **Blossom** — upload images and media to decentralized [Blossom](https://github.com/hzrd149/blossom) servers
- Per-account Blossom server list (kind 10063), edited in app
- Multi-server fallback — tries each configured server until one succeeds
- **Giphy** — built-in GIF picker; selected GIFs are re-hosted to your Blossom servers, with the original Giphy URL as a fallback

### Performance

- **Selective on-device persistence** — ObjectBox stores only the kinds worth keeping warm (notes, reposts, picture posts, reactions, zap receipts) for fast cold-start; everything else stays in RAM
- **In-memory caches** for profiles, emoji images, link previews, and quoted notes
- **Off-main-thread work** — relay I/O, NIP-44 crypto, ML inference, and PoW mining all run on background tasks with cancellation support
- **Lockless safety filter** — `SafetyFilter` reads a single snapshot per check and runs Set lookups; spam scoring is cached per pubkey
- **EOSE-driven query completion** — relay queries return as soon as any relay sends EOSE (with a short grace window for stragglers) rather than waiting for a fixed timeout
- **Atomic dedup** — events and gift-wraps are deduped by id across relays inside dedicated actors

### Identity, Keys & Accounts

- **Multiple accounts** with per-account state, settings, follows, and relay scoreboard
- **iOS Keychain** for the keypair (`WhenUnlockedThisDeviceOnly`) — `nsec` never lives in `UserDefaults`
- **NIP-19 bech32** — npub, nsec, note, nevent, nprofile encode/decode, with `nostr:` URI rendering in post content
- **NIP-05 DNS verification** with result caching
- **BIP-39** mnemonic support for wallet recovery
- **QR code display** for sharing keys and profiles

### Additional Features

- **Tab-based navigation** with declarative routing per tab — Home, Wallet, Search, Messages, Notifications
- **Sidebar drawer** for account switching, settings, and quick navigation
- **Thread view** with NIP-10 root/reply resolution
- **Notifications** aggregating mentions, reactions, zaps, and reposts
- **Hashtag feeds** and **hashtag sets** (NIP-51 interest sets, kind 30015)
- **Follow sets** (kind 30000) and **note lists** (kind 30003) as alternative feed sources
- **Search** for profiles, content, and hashtags
- **Trending feed** for discovery
- **Social graph visualization** of your follow network
- **Profile editing** with metadata publishing
- **Onboarding flow** — key creation/import, outbox-relay discovery, and follow ingestion for new users
- **Five built-in themes** (Custom, Nord, Dracula, Gruvbox, Monochrome) with light/dark variants and a customizable accent color
- **Native iPad and Vision Pro** support — the same SwiftUI codebase ships across all three platforms

---

## Architecture

Wisp follows an MVVM architecture with clear layer separation:

```
┌──────────────────────────────────────────────────────┐
│                      UI Layer                         │
│                  SwiftUI Screens                      │
│   MainView, FeedView, ThreadView, DmConversation,     │
│   GroupRoom, LiveStream, WalletView, Notifications…   │
├──────────────────────────────────────────────────────┤
│                   View Model Layer                    │
│  FeedVM, ThreadVM, DmConversationVM, WalletStore,     │
│  GroupRoomVM, LiveStreamVM, SocialGraphVM…            │
│  (@Observable @MainActor — Observation framework)     │
├──────────────────────────────────────────────────────┤
│                   Repository Layer                    │
│   ProfileRepo, DmRepo, GroupRepo, RelayListRepo,      │
│   BlossomClient, MuteRepo, NoteListRepo,              │
│   SocialGraphRepo, EngagementRepo, EmojiRepo…         │
├──────────────────────────────────────────────────────┤
│                    Protocol Layer                     │
│   Nip04 Nip09 Nip10 Nip13 Nip17 Nip18 Nip19 Nip25     │
│   Nip29 Nip37 Nip42 Nip44 Nip47 Nip51 Nip53 Nip57     │
│   Nip65 Nip68 Nip69 Nip71 Nip78 Nip88 + Blossom +     │
│   Bolt11 + Schnorr + Bip39                            │
├──────────────────────────────────────────────────────┤
│                     Relay Layer                       │
│   RelayPool (one-shot), GroupRelayPool (persistent),  │
│   RelayScoreBoard, EventCollector,                    │
│   URLSessionWebSocketTask                             │
└──────────────────────────────────────────────────────┘
```

### Key Design Decisions

- **Mostly in-memory, selectively persistent** — most state lives in actor-backed in-memory caches; ObjectBox persists a narrow set of kinds (notes, reposts, picture posts, reactions, zap receipts, profiles) for fast cold-start, plus a separate ObjectBox store for joined groups and group messages. Per-account preferences live in `UserDefaults`; private keys live in the iOS Keychain.
- **Two relay pools, two lifecycles** — `RelayPool.query` is fire-and-collect for feeds and lookups; `GroupRelayPool` keeps persistent sockets with NIP-42 AUTH for groups and live subscriptions. Treat them as different tools, not interchangeable.
- **NIP files** — each NIP is implemented in `NipXX.swift` as a small set of static helpers (e.g. `Nip17.createGiftWrap()`, `Nip44.encrypt()`), making the protocol layer modular and easy to test.
- **Observation, not Combine** — view models are `@Observable @MainActor final class`; storage and shared collectors are Swift `actor`s. `NostrEvent` is a value type with a `nonisolated init` so events can cross actor boundaries freely.
- **Off-main-thread crypto** — Schnorr signing, NIP-44 encryption, ML inference, and PoW mining run on detached tasks with cancellation support.
- **Keychain for keys** — the keypair is stored as a `WhenUnlockedThisDeviceOnly` Keychain item under service `com.wisp.nostr`; wallet seeds get their own Keychain item.

### Project Structure

```
wisp.xcodeproj
├── wisp/                      # Synchronized folder (auto-included in target)
│   ├── wispApp.swift          # @main + ObjectBox setup
│   ├── ContentView.swift      # Splash → onboarding → main flow
│   ├── MainView.swift         # Five-tab TabView with per-tab NavigationStack
│   ├── SidebarDrawerView.swift, ComposeFAB.swift
│   ├── DmListView.swift, DmConversationView.swift, MessagesView.swift
│   ├── GroupListView.swift, GroupRoomView.swift, …
│   ├── Live/                  # NIP-53 live streams
│   ├── Resources/             # Bundled resources (gitignored secrets, BIP-39 wordlist, NSpam model)
│   └── Assets.xcassets
├── *.swift                    # Domain code at repo root: view models,
│                              # repositories, NIP implementations, crypto,
│                              # storage actors. Added to target via explicit
│                              # PBXFileReference entries in project.pbxproj.
├── wispTests/                 # Swift Testing (@Test) — Nip44, NSpam, Safety, …
├── wispUITests/               # XCTest UI tests
└── generated/                 # ObjectBox generator output
```

---

## Supported NIPs

| NIP | Description | Status |
|-----|-------------|--------|
| [01](https://github.com/nostr-protocol/nips/blob/master/01.md) | Basic protocol flow | ✅ |
| [02](https://github.com/nostr-protocol/nips/blob/master/02.md) | Follow lists | ✅ |
| [04](https://github.com/nostr-protocol/nips/blob/master/04.md) | Encrypted DMs (legacy) | ✅ (NWC fallback only) |
| [05](https://github.com/nostr-protocol/nips/blob/master/05.md) | DNS-based verification | ✅ |
| [09](https://github.com/nostr-protocol/nips/blob/master/09.md) | Event deletion | ✅ |
| [10](https://github.com/nostr-protocol/nips/blob/master/10.md) | Reply threading | ✅ |
| [13](https://github.com/nostr-protocol/nips/blob/master/13.md) | Proof of Work | ✅ |
| [17](https://github.com/nostr-protocol/nips/blob/master/17.md) | Private DMs (gift wrap) | ✅ |
| [18](https://github.com/nostr-protocol/nips/blob/master/18.md) | Reposts | ✅ |
| [19](https://github.com/nostr-protocol/nips/blob/master/19.md) | Bech32 encoding | ✅ |
| [25](https://github.com/nostr-protocol/nips/blob/master/25.md) | Reactions | ✅ |
| [29](https://github.com/nostr-protocol/nips/blob/master/29.md) | Relay-based groups | ✅ |
| [30](https://github.com/nostr-protocol/nips/blob/master/30.md) | Custom emoji | ✅ |
| [37](https://github.com/nostr-protocol/nips/blob/master/37.md) | Draft events | ✅ |
| [42](https://github.com/nostr-protocol/nips/blob/master/42.md) | Relay AUTH | ✅ |
| [44](https://github.com/nostr-protocol/nips/blob/master/44.md) | Versioned encryption (v2) | ✅ |
| [47](https://github.com/nostr-protocol/nips/blob/master/47.md) | Wallet Connect (NWC) | ✅ |
| [51](https://github.com/nostr-protocol/nips/blob/master/51.md) | Lists (mute, follow sets, note lists, hashtag sets, relay sets) | ✅ |
| [53](https://github.com/nostr-protocol/nips/blob/master/53.md) | Live activities | ✅ |
| [57](https://github.com/nostr-protocol/nips/blob/master/57.md) | Lightning zaps | ✅ |
| [65](https://github.com/nostr-protocol/nips/blob/master/65.md) | Relay list metadata | ✅ |
| [68](https://github.com/nostr-protocol/nips/blob/master/68.md) | Picture-first posts | ✅ |
| 69 | Zap polls | ✅ |
| [71](https://github.com/nostr-protocol/nips/blob/master/71.md) | Video posts | ✅ |
| [78](https://github.com/nostr-protocol/nips/blob/master/78.md) | App-specific data (wallet backup) | ✅ |
| [88](https://github.com/nostr-protocol/nips/blob/master/88.md) | Polls | ✅ |
| 92 | Inline media metadata (imeta) | ✅ |
| A3 | `payto:` payment targets (kind 10133) | ✅ |

Also: **Blossom** media servers, **NWC** transport, and **bolt11** invoice parsing.

> Notable Android-only features not (yet) in iOS: Tor, NIP-55 remote signing (Amber), NIP-11 relay info documents, NIP-23 long-form articles. Contributions welcome.

---

## Getting Started

### Requirements

- iOS 26.4 / iPadOS 26.4 / visionOS 26.4 or later
- A Nostr keypair (generate one in-app, or import an existing `nsec`)

### Installation

TestFlight and App Store availability will be announced on the [Releases](../../releases) page.

### First Launch

1. **Create or import a key** — generate a fresh keypair or paste your `nsec`
2. **Onboarding fans out** — Wisp queries indexer relays for your kind-3 follows and their kind-10002 relay lists, then builds a relay scoreboard
3. **Pick interests / follow suggestions** — seed your first follows if you're new
4. **Start reading** — your home feed is built from the top-scored relays where the people you follow actually publish

---

## Building from Source

### Prerequisites

- macOS with Xcode 26 or later
- An Apple Developer account if you want to run on a physical device
- (Optional) Breez Spark API key for Lightning wallet features
- (Optional) Giphy SDK API key for the GIF picker

### Build

```bash
# Clone the repository
git clone https://github.com/barrydeen/wisp-ios.git
cd wisp-ios

# Open in Xcode
open wisp.xcodeproj
```

Or build from the command line:

```bash
xcodebuild -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

xcodebuild -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

### API Keys

Wisp reads optional API keys from gitignored bundled resources. Copy the example files and fill in your own keys:

```bash
cp wisp/Resources/breez-api-key.txt.example wisp/Resources/breez-api-key.txt
cp wisp/Resources/giphy-api-key.txt.example wisp/Resources/giphy-api-key.txt
```

Wisp will build and run without these — you'll just lose Spark wallet support and the Giphy GIF picker, respectively.

### Adding New Files

The project mixes two file-management styles. Files dropped into `wisp/`, `wispTests/`, or `wispUITests/` are auto-included via Xcode's synchronized folders. **Files at the repo root must be added to `wisp.xcodeproj/project.pbxproj` explicitly** — otherwise they won't compile into the target.

---

## Contributing

Contributions are welcome. Wisp is open source and community help makes it better.

### How to Contribute

1. **Fork** the repository
2. **Create a branch** for your feature or fix (`feat/…`, `fix/…`, `refactor/…`, `docs/…`, `chore/…`, `perf/…`)
3. **Make your changes** — follow the existing code patterns and conventions
4. **Test** on a simulator or real device
5. **Commit** with a clear, descriptive message (`<type>: <summary>`)
6. **Open a pull request** against `main` — one concern per PR, small and focused

### Code Conventions

- **Swift + SwiftUI** with the Observation framework — no UIKit screens, no Combine
- **NIP implementations** go in `NipXX.swift` as static helper functions on a `Nip*` namespace
- **Events** are signed via `NostrEvent.sign(...)`, which calls `Schnorr.sign` under the hood
- **Hex** uses the `Hex` helpers; bech32 lives in `Bech32.swift`
- **Concurrency** — view models are `@MainActor`; storage is `actor`-isolated; CPU-bound work runs on detached tasks
- **State** — `@Observable` for view models, plain `let` constants where possible. No `ObservableObject`/`@Published`
- **Keep functions small and focused.** Prefer clarity over cleverness.

### Areas Where Help is Needed

- UI/UX polish and accessibility improvements (VoiceOver, Dynamic Type)
- Additional NIP implementations (NIP-23 long-form, NIP-11, NIP-56 reporting…)
- Incoming-event signature verification in the relay pipeline
- iPad and visionOS layout refinements
- Unit and integration tests
- Performance profiling
- Translations and localization
- Documentation improvements

### Reporting Issues

[Open an issue](../../issues) with:

- Steps to reproduce (for bugs)
- Expected vs actual behavior
- Device, iOS version, and Xcode version
- Relevant logs (Console.app filtered to the app)

---

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Language | Swift 5 |
| UI Framework | SwiftUI + Observation framework |
| Platforms | iOS 26.4+, iPadOS 26.4+, visionOS 26.4+ |
| Networking | `URLSessionWebSocketTask` (Foundation) |
| Persistence | ObjectBox (selective event store + dedicated group store), iOS Keychain (keys), UserDefaults (per-account prefs), per-account SQLite (social graph) |
| Cryptography | [`swift-secp256k1`](https://github.com/21-DOT-DEV/swift-secp256k1) (Schnorr / ECDH), in-tree NIP-44 v2 (ChaCha20 + HMAC-SHA256), in-tree BIP-39 |
| ML | LightGBM (on-device nspam classifier) with MurmurHash3 feature hashing |
| Lightning | [Breez SDK Spark](https://github.com/breez/breez-sdk-spark) + NWC (NIP-47) |
| Media | AVFoundation, [Giphy iOS SDK](https://github.com/Giphy/giphy-ios-sdk), Blossom upload |
| Build | Xcode 26 / SwiftPM (no `Package.swift` — resolved via the Xcode project) |

---

## License

Wisp is released under the [MIT License](LICENSE).

Payment-target coin marks (`Pt*.imageset` in `wisp/Assets.xcassets`) are derived from [spothq/cryptocurrency-icons](https://github.com/spothq/cryptocurrency-icons), released under CC0-1.0.

```
MIT License

Copyright (c) 2025 Barry Deen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

Built with care for the Nostr ecosystem.
