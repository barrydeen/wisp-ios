import SwiftUI

/// A NIP-51 emoji set (kind 30030) rendered as self-describing content: title,
/// the pack's actual emoji art, a single Add / Added toggle wired to the user's
/// kind-10030 list, and a share menu that emits the pack's `nostr:naddr1…`.
///
/// This is the piece that removes the "paste `30030:<pubkey>:<d>`" step. The
/// same card is used in three places, so wherever a user *encounters* a pack
/// they can subscribe to it in one tap:
///   • `EmojiPackExploreView` — the discovery feed in Custom Emoji settings.
///   • `RichContentView` — a `nostr:naddr1…` pointing at a kind-30030 event,
///     i.e. a pack someone shared in a note.
///   • `CustomEmojiSettingsView` — the user's own subscribed packs, where the
///     toggle reads "Added" and unsubscribes.
struct EmojiPackCardView: View {
    /// How the card paints itself. `.card` draws its own surface + padding for
    /// standalone placement (discovery feed, note content). `.inline` drops
    /// both — inside the settings screen the enclosing `section(…)` container
    /// already paints `palette.surface`, and a surface-on-surface card would
    /// read as a flat, borderless block.
    enum Style {
        case card
        case inline
    }

    let pack: ResolvedEmojiPack
    var style: Style = .card
    /// Cap on how many emoji thumbnails render before the "+N" overflow chip.
    /// Discovery cards stay compact; the settings list shows the same cap.
    var previewLimit: Int = 21

    @Environment(\.theme) private var theme
    @State private var emojiRepo = EmojiRepository.shared
    @ObservedObject private var emojiCache = EmojiImageCache.shared

    @State private var updating = false
    @State private var errorMessage: String?
    /// Pack creator's profile. Resolved by the card itself rather than injected,
    /// for the same reason as `keypair`: two of the three hosts (note content,
    /// the Explore feed) have no profile dict to hand down.
    @State private var creator: ProfileData?

    /// Resolved lazily rather than injected: the card renders inside note
    /// content (`RichContentView`), which has no keypair to hand down.
    private var keypair: Keypair? { NostrKey.load() }

    private var isAdded: Bool { emojiRepo.isPackAdded(pack.address) }

    private var canMutate: Bool {
        guard let keypair else { return false }
        return !keypair.isWatchOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if pack.emojis.isEmpty {
                Text("This pack has no emojis")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            } else {
                emojiPreview
            }
        }
        .padding(style == .card ? 14 : 0)
        .padding(.vertical, style == .inline ? 6 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if style == .card {
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.palette.surface)
            }
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            for e in pack.emojis.prefix(previewLimit) {
                emojiCache.ensureLoaded(e.url)
            }
        }
        .task(id: pack.pubkey) {
            if let cached = ProfileRepository.shared.get(pack.pubkey) {
                creator = cached
                return
            }
            // `ensure` coalesces per pubkey, so a screen full of Explore cards
            // by the same author shares one indexer query.
            creator = await ProfileRepository.shared.ensure([pack.pubkey])[pack.pubkey]
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pack.title ?? pack.dTag)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                // Who made it. Many packs ship no `title` tag at all, so
                // without this the card is a bare `d` tag with no provenance —
                // and the author is the main signal for whether a pack is worth
                // adding while scrolling Explore.
                HStack(spacing: 5) {
                    CachedAvatarView(url: creator?.picture, size: 14)
                    Text(creator?.displayString ?? Nip19.shortNpub(hex: pack.pubkey))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("·")
                    Text("\(pack.emojis.count) emoji" + (pack.emojis.count == 1 ? "" : "s"))
                        .fixedSize()
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.onSurfaceVariant)
            }
            Spacer(minLength: 0)
            shareButton
            if canMutate {
                addButton
            }
        }
    }

    /// Sharing is the other half of discovery: a pack is only findable by
    /// scrolling Explore until someone can hand you a link. The payload is a
    /// `nostr:naddr1…`, which `RichContentView` now renders as this same card —
    /// so a shared pack arrives as something the recipient can tap Add on,
    /// rather than a coordinate they have to transcribe.
    private var shareButton: some View {
        Menu {
            Button {
                Task { ShareSheetPresenter.present(text: await shareUri()) }
            } label: {
                Label("Share pack", systemImage: "square.and.arrow.up")
            }
            Button {
                Task {
                    UIPasteboard.general.string = await shareUri()
                    QuickFollowToast.shared.show("Copied")
                }
            } label: {
                Label("Copy link", systemImage: "doc.on.doc")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onSurfaceVariant)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `nostr:naddr1…` carrying the pack author's write relays as hints, so a
    /// recipient whose relays don't carry the set can still resolve it. Falls
    /// back to the raw coordinate if the key won't decode — never silently
    /// shares nothing.
    private func shareUri() async -> String {
        let hints = Array(await RelayListRepository.shared.getWriteRelays(pack.pubkey).prefix(2))
        guard let pubkeyBytes = Hex.decode(pack.pubkey),
              let naddr = Nip19.naddrEncode(
                  kind: 30030,
                  pubkey32: Array(pubkeyBytes),
                  dTag: pack.dTag,
                  relays: hints
              )
        else {
            return pack.address
        }
        return "nostr:\(naddr)"
    }

    private var addButton: some View {
        Button {
            toggle()
        } label: {
            HStack(spacing: 4) {
                if updating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: isAdded ? "checkmark" : "plus")
                        .font(.system(size: 12, weight: .bold))
                }
                Text(isAdded ? "Added" : "Add")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isAdded ? theme.palette.onSurfaceVariant : Color.white)
            .background(
                Capsule()
                    .fill(isAdded ? theme.palette.surfaceVariant.opacity(0.6) : theme.primary)
            )
        }
        .buttonStyle(.plain)
        .disabled(updating)
    }

    private func toggle() {
        guard let keypair, !updating else { return }
        let wasAdded = isAdded
        updating = true
        Task {
            defer { updating = false }
            do {
                if wasAdded {
                    try await emojiRepo.removePackReference(pack.address, keypair: keypair)
                } else {
                    // Seed the resolution cache with what we already rendered so
                    // the publish path doesn't re-fetch the pack we're holding.
                    emojiRepo.primeResolvedPack(pack)
                    try await emojiRepo.addPackReference(pack.address, keypair: keypair)
                }
                Haptics.shared.success()
            } catch {
                Haptics.shared.fail()
                errorMessage = wasAdded
                    ? "Failed to remove the pack. Please try again."
                    : "Failed to add the pack. Please try again."
            }
        }
    }

    // MARK: - Emoji preview

    private var emojiPreview: some View {
        let shown = Array(pack.emojis.prefix(previewLimit))
        let overflow = pack.emojis.count - shown.count
        let cols = [GridItem(.adaptive(minimum: 34, maximum: 44), spacing: 6)]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
            ForEach(shown) { e in
                thumb(e)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.onSurfaceVariant)
                    .frame(height: 34)
            }
        }
    }

    private func thumb(_ ce: CustomEmoji) -> some View {
        ZStack {
            if let img = emojiCache.image(for: ce.url) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.palette.surfaceVariant.opacity(0.35))
            }
        }
        .frame(height: 34)
    }
}

/// Fetch-then-render wrapper for a pack referenced by coordinate rather than
/// held in memory — used by `RichContentView` when note content carries a
/// `nostr:naddr1…` for a kind-30030 event.
///
/// Resolution order: the repository's already-resolved packs → the local
/// ObjectBox event cache → relays (the pack author's write relays, plus any
/// hints carried by the `naddr` itself, plus the built-in indexers).
struct EmojiPackCardLoader: View {
    let dTag: String
    let author: String
    let relayHints: [String]

    @Environment(\.theme) private var theme
    @State private var pack: ResolvedEmojiPack?
    @State private var loaded = false

    private var address: String { "30030:\(author):\(dTag)" }

    var body: some View {
        Group {
            if let pack {
                EmojiPackCardView(pack: pack)
            } else if loaded {
                stub(icon: "face.smiling", text: "Emoji pack not found")
            } else {
                stub(icon: nil, text: "Loading emoji pack…")
            }
        }
        .task(id: address) { await load() }
    }

    @ViewBuilder
    private func stub(icon: String?, text: String) -> some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.onSurfaceVariant)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func load() async {
        if let cached = EmojiRepository.shared.resolvedPacks[address] {
            pack = cached
            loaded = true
            return
        }
        if let cachedEvent = await EventStore.shared.loadEmojiPacksByAddress([address]).first,
           let parsed = EmojiRepository.parsePack(cachedEvent) {
            pack = parsed
            loaded = true
            return
        }

        let relays = await EmojiRepository.packResolutionRelays(author: author, hints: relayHints)
        let events = await RelayPool.query(
            relays: relays,
            filter: NostrFilter(kinds: [30030], authors: [author], dTags: [dTag], limit: 1),
            timeout: 6
        )
        if Task.isCancelled { return }
        if let ev = events.max(by: { $0.createdAt < $1.createdAt }) {
            pack = EmojiRepository.parsePack(ev)
            await EventStore.shared.persist([ev])
        }
        loaded = true
    }
}
