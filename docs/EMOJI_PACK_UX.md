# Emoji pack UX — discovery, cards, sharing

Branch: `claude/emoji-pack-ux-vkx2rp` · Commits: `eafba05`, `2819bdb`

## TL;DR

Adding an emoji pack used to mean pasting a raw replaceable-event coordinate
(`30030:<pubkey-hex>:<d-tag>`) into a form whose footer explained the wire
format. Packs are now **content rather than configuration**: a kind-30030 event
renders as a card with its own Add / Added toggle wherever it appears, there is
an Explore feed to find packs by scrolling, and a pack can be shared as a
`nostr:naddr1…` that renders as that same card on the receiving end.

> **This branch has never been compiled.** It was written in a Linux container
> with no Swift toolchain, against an Xcode project whose dependencies resolve
> through Xcode. Everything below is verified by inspection only. Build it
> before you trust it — see [Verification status](#verification-status).

## The problem

`CustomEmojiSettingsView`'s "Add emoji pack" action opened a sheet whose only
input was the coordinate. To use it you had to already know a pack existed,
know its author's 64-character hex pubkey, and know its `d` tag. There was no
discovery, no way to author a pack (wisp only published inline `emoji` tags on
kind 10030), and no way to share one. In practice nobody added packs.

## Where the design came from

[Jumble](https://github.com/CodyTseng/jumble) solves this by treating a pack as
a thing you look at rather than a setting you configure. The pieces worth
copying:

| Jumble | What it does |
| --- | --- |
| `src/components/NoteContent/EmojiPack.tsx` | Renders any kind-30030 event as title + emoji art + one `Add`/`Added` button. Same component in feeds, in notes, from a pasted `naddr`. |
| `src/pages/secondary/EmojiPackSettingsPage/index.tsx` | `My Packs` / `Explore` tabs. Explore is literally `<NoteList showKinds={[kinds.Emojisets]} …/>` — trivial *because* packs are already renderable content. |
| `src/lib/emoji.ts` | `normalizeShortcode` strips stray colons; charset + URL validators. |

Nowhere in Jumble does a user type a coordinate. That was the target.

## What was built

### 1. `wisp/EmojiPackCardView.swift` (new)

The keystone. A `ResolvedEmojiPack` rendered as title, emoji count, the actual
emoji art, a share menu, and one Add / Added capsule bound to
`EmojiRepository.referencedPackAddrs`.

Two styles:

- `.card` — draws its own `palette.surface` + padding. Standalone placement
  (Explore feed, note content).
- `.inline` — drops both. Inside `CustomEmojiSettingsView` the enclosing
  `section(…)` container already paints `palette.surface`, and a
  surface-on-surface card reads as a flat borderless block.

`EmojiPackCardLoader` in the same file fetches a pack from a coordinate for
callers that only have one. Resolution order: `EmojiRepository.resolvedPacks`
→ ObjectBox (`EventStore.loadEmojiPacksByAddress`) → relays (author's write
relays + `naddr` hints + `RelayDefaults.indexers`).

### 2. `wisp/EmojiPackExploreView.swift` (new)

The Explore tab. `EmojiPackExploreModel` queries `kinds: [30030]` against the
user's top-scoring relays plus the indexers, dedupes per address, drops empty
and safety-filtered packs, and paginates backwards with `until`.

**Non-obvious bit:** `loadPage()` keeps pulling pages until at least one *new*
pack lands (capped at `maxEmptyRounds = 3`). Emoji sets are replaceable, so
relays return several revisions of the same `d` tag. A page that was entirely
duplicates would append no rows → the tail `onAppear` that drives pagination
would never fire again → the feed dead-ends mid-scroll. Do not "simplify" this
loop back into a single query.

### 3. `RichContentView.swift`

Kind 30030 now renders `EmojiPackCardLoader`, beside the existing 30023
(`ArticleCardView`) and music-track branches. This is what makes a shared pack
link a working install flow.

### 4. `CustomEmojiSettingsView.swift`

Mine / Explore segmented tabs. Subscribed packs render as the same card, so
"Added" means the same thing and unsubscribes the same way everywhere. The
paste field survives as a secondary **Add by link** action and now accepts an
`naddr1…` (with or without the `nostr:` prefix) as well as the raw coordinate,
via `normalizedPackAddress(_:)`.

The tab picker is hidden for watch-only accounts, which stay pinned to Mine.

### 5. `EmojiRepository.swift`

- `static parsePack(_:)` — extracted from `ingestEmojiSet` so display paths can
  read a pack **without** growing the repository's `resolvedPacks` cache.
  Browsing hundreds of packs in Explore must not leak into app-wide state.
- `primeResolvedPack(_:)` — seeds the cache just before `addPackReference`, so
  `publishKind10030` → `fetchReferencedPacks` finds the pack already resolved
  and skips a redundant relay round-trip.
- `isPackAdded(_:)` — backs the card's toggle.

### 6. Sharing — `Nip19.swift`, `wisp/ShareSheetPresenter.swift`

`Nip19` encoded npub/nsec/note/nevent/nprofile but had **no naddr encoder**, so
wisp could consume a pack link and not produce one.

`naddrEncode(kind:pubkey32:dTag:relays:)` mirrors the TLV layout
`parseTlvAddress` already reads (0 = d tag utf8, 1 = relays, 2 = author,
3 = kind big-endian).

> It refuses a `d` tag over 255 bytes. A TLV value is length-prefixed with one
> byte and `appendTlv` **silently drops** an oversized value — without the
> guard you get a well-formed `naddr1…` that decodes to an empty `d` tag. A
> link that looks valid and points at nothing is worse than no link.

The card's share menu offers "Share pack" (system share sheet) and "Copy link",
both emitting `nostr:naddr1…` with the pack author's top two write relays as
hints. `ShareSheetPresenter.present(text:)` was added because the existing
`present(url:)` deliberately wraps its payload in a `URL` for richer link
targets — a `nostr:` URI parses as a URL with a scheme iOS cannot open, so it
would offer link actions that go nowhere.

## Design decisions a reviewer might question

**Share payload is a bare `nostr:naddr1…`, not a web link.** The rest of wisp
shares `https://wisp.talk/profile/<hex>` and `https://wisp.talk/thread/<nevent>`,
but there is no evidence of a wisp.talk route for emoji packs and inventing one
would produce dead links. The naddr is client-agnostic and is exactly what makes
the card render on the receiving end. If wisp.talk gains a pack route, it is a
one-line change in `EmojiPackCardView.shareUri()`.

**New files live under `wisp/` and `wispTests/`.** Those are
`PBXFileSystemSynchronizedRootGroup`s, so no `project.pbxproj` edits were
needed. `Nip19.swift`, `EmojiRepository.swift`, `RichContentView.swift` and
`CustomEmojiSettingsView.swift` are root-level files that were *modified*, not
added, so they need no pbxproj change either.

## Verification status

| | |
| --- | --- |
| Compiled | ❌ never — no Swift toolchain in the authoring environment |
| Unit tests run | ❌ never |
| Run on device/simulator | ❌ never |
| Reviewed by inspection | ✅ |

Tests were written but not executed:

- `wispTests/EmojiPackTests.swift` — 6 tests over `EmojiRepository.parsePack`:
  kind rejection, missing `d` tag, optional title, duplicate and malformed
  emoji tags, empty packs.
- `wispTests/Nip19NaddrTests.swift` — 7 tests over `naddrEncode`, using the
  pre-existing `naddrDecode` as the oracle: coordinate, relay-hint, unicode
  `d`-tag and `nostr:`-prefixed round-trips, plus both rejection paths.

Both use plain `#expect` rather than `try #require` — nothing else in the suite
uses `#require`, and matching the established style seemed safer than
introducing an API that could not be compile-checked.

## Picking this up — suggested order

1. **Build it.** `xcodebuild -project wisp.xcodeproj -scheme wisp -destination
   'platform=iOS Simulator,name=iPhone 16' build`. Concurrency isolation is the
   likeliest source of errors: `EmojiRepository` and `EmojiPackExploreModel` are
   both `@MainActor`, and the views rely on global-actor inference from
   `SwiftUI.View` conformance.
2. **Run the tests.** `-scheme wisp … test`.
3. **Smoke the three surfaces:** Explore tab loads and paginates; a pack added
   from Explore shows Added in Mine and its emojis appear in the reaction
   picker; a `nostr:naddr1…` for a kind-30030 pasted into a note renders as a
   card.
4. **Check the visual nesting** of `.inline` cards inside the settings section —
   that variant exists purely to avoid surface-on-surface and has never been
   seen rendered.
5. **Watch-only accounts:** the card's Add button and the tab picker should both
   be absent.

## Not included

- **Pack authoring.** Publishing your own kind 30030 with per-row Blossom image
  upload — Jumble's `EmojiSetEditorPage` + `EmojiRowsEditor`. wisp already has
  `BlossomClient.upload` and `MediaPicker`, so the pieces exist. This is a
  separate feature from the discovery complaint and was deliberately deferred.
- **Share to a note.** Arguably how packs actually spread on nostr, but
  `ComposePresenter` has no prefilled-text case; adding one means touching
  `ComposeRequest`, `MainView`'s sheet host and `ComposeView`'s init, and the
  settings screen may not have the presenter in scope since it is presented as
  its own sheet.
- **`normalizeShortcode`.** Jumble strips stray colons so pasting `:pepe:` into
  the shortcode field works. wisp's "My custom emojis" form still rejects it.
  Small, self-contained, worth doing.
