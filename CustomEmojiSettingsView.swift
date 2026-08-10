import SwiftUI

/// Settings screen for managing the user's reaction emojis and NIP-30 custom emoji state.
///
/// Two tabs:
///
/// **Mine** — three sections:
///   1. **Quick reactions** — the user-curated unicode/`:shortcode:` list shown in the
///      reaction picker. Tap to remove; "+" opens `EmojiLibrarySheet(.pickForQuickList)`.
///   2. **My custom emojis** — inline `["emoji", shortcode, url]` tags from the user's
///      kind-10030 event. Add via a small form (shortcode + URL); remove via swipe.
///      Each mutation publishes a new kind-10030.
///   3. **Emoji packs** — `a` references to external kind-30030 packs the user has
///      added, each rendered as an `EmojiPackCardView` whose "Added" toggle
///      unsubscribes. A secondary "Add by link" action still accepts a pasted
///      `naddr1…` or raw `30030:<pubkey>:<d>` coordinate.
///
/// **Explore** — `EmojiPackExploreView`, a live feed of kind-30030 packs pulled off
/// the user's relays plus the indexers. This is the primary way to add a pack: you
/// scroll packs you can actually see and tap Add, instead of having to know a
/// coordinate up front.
struct CustomEmojiSettingsView: View {
    let keypair: Keypair

    private enum Tab: String, CaseIterable {
        case mine = "Mine"
        case explore = "Explore"
    }

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var emojiRepo = EmojiRepository.shared
    @ObservedObject private var emojiCache = EmojiImageCache.shared

    @State private var tab: Tab = .mine
    @State private var showLibrary = false
    @State private var showAddDirect = false
    @State private var showAddPack = false
    @State private var addingDirect = false
    @State private var addingPack = false
    @State private var directShortcode = ""
    @State private var directUrl = ""
    @State private var packAddress = ""
    @State private var errorMessage: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if keypair.isWatchOnly {
                    watchOnlyBanner
                }
                if !keypair.isWatchOnly {
                    tabPicker
                }
                switch tab {
                case .mine:
                    Group {
                        quickReactionsSection
                        directEmojisSection
                        emojiPacksSection
                    }
                    .disabled(keypair.isWatchOnly)
                    .opacity(keypair.isWatchOnly ? 0.4 : 1)
                case .explore:
                    EmojiPackExploreView(pubkey: keypair.pubkey)
                }
                Spacer(minLength: 32)
            }
            .padding(20)
        }
        .background(theme.palette.background.ignoresSafeArea())
        .navigationTitle("Custom Emojis")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showLibrary) {
            EmojiLibrarySheet(mode: .pickForQuickList)
        }
        .sheet(isPresented: $showAddDirect) {
            addDirectSheet
        }
        .sheet(isPresented: $showAddPack) {
            addPackSheet
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            await emojiRepo.refresh(for: keypair.pubkey)
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases, id: \.self) { t in
                Text(t.rawValue).tag(t)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Section 1: Quick reactions

    private var quickReactionsSection: some View {
        section(
            title: "Quick reactions",
            footer: "Shown when you tap the heart on a post. Tap an emoji to remove it. Sort order follows your usage."
        ) {
            let entries = emojiRepo.sortedQuickReactions
            VStack(alignment: .leading, spacing: 12) {
                if entries.isEmpty {
                    Text("No quick reactions yet")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                } else {
                    let cell: CGFloat = 40
                    let cols = Array(repeating: GridItem(.fixed(cell), spacing: 8), count: 7)
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                        ForEach(entries, id: \.self) { key in
                            quickCell(key, size: cell)
                        }
                    }
                }
                Button {
                    showLibrary = true
                } label: {
                    Label("Add emoji", systemImage: "plus.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func quickCell(_ key: String, size: CGFloat) -> some View {
        Button {
            emojiRepo.removeFromQuickList(key)
        } label: {
            ZStack {
                if key.hasPrefix(":") && key.hasSuffix(":") {
                    let sc = String(key.dropFirst().dropLast())
                    if let url = emojiRepo.resolvedCustomMap[sc],
                       let img = emojiCache.image(for: url) {
                        Image(uiImage: img)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: size - 6, height: size - 6)
                    } else {
                        Text(":\(sc):")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 2)
                            .onAppear {
                                if let url = emojiRepo.resolvedCustomMap[sc] {
                                    emojiCache.ensureLoaded(url)
                                }
                            }
                    }
                } else {
                    Text(key)
                        .font(.system(size: 26))
                }
            }
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.palette.surfaceVariant.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section 2: Direct custom emojis

    private var directEmojisSection: some View {
        section(
            title: "My custom emojis",
            footer: "Inline NIP-30 emojis on your kind 10030 list. Editing publishes a replacement event."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if emojiRepo.directEmojis.isEmpty {
                    Text("No custom emojis yet")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                } else {
                    ForEach(emojiRepo.directEmojis) { ce in
                        directRow(ce)
                    }
                }
                Button {
                    directShortcode = ""
                    directUrl = ""
                    showAddDirect = true
                } label: {
                    Label("Add custom emoji", systemImage: "plus.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.primary)
                }
                .buttonStyle(.plain)
                .disabled(addingDirect)
            }
        }
    }

    private func directRow(_ ce: CustomEmoji) -> some View {
        HStack(spacing: 12) {
            ZStack {
                if let img = emojiCache.image(for: ce.url) {
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.clear
                        .onAppear { emojiCache.ensureLoaded(ce.url) }
                }
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(":\(ce.shortcode):")
                    .font(.system(size: 14, weight: .semibold))
                Text(ce.url)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                Task {
                    do {
                        try await emojiRepo.removeDirectEmoji(shortcode: ce.shortcode, keypair: keypair)
                    } catch {
                        errorMessage = "Failed to publish updated emoji list."
                    }
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private var addDirectSheet: some View {
        NavigationStack {
            Form {
                Section("Shortcode") {
                    TextField("pepe", text: $directShortcode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Image URL") {
                    TextField("https://...", text: $directUrl)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Add custom emoji")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showAddDirect = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let sanitized = directShortcode.trimmingCharacters(in: .whitespacesAndNewlines)
                        let url = directUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard isValidShortcode(sanitized) else {
                            errorMessage = "Shortcode must contain only letters, numbers, hyphens, or underscores."
                            return
                        }
                        guard !url.isEmpty else { return }
                        addingDirect = true
                        showAddDirect = false
                        Task {
                            defer { Task { @MainActor in addingDirect = false } }
                            do {
                                try await emojiRepo.addDirectEmoji(
                                    shortcode: sanitized,
                                    url: url,
                                    keypair: keypair
                                )
                            } catch {
                                errorMessage = "Failed to publish to relays."
                            }
                        }
                    }
                    .disabled(directShortcode.isEmpty || directUrl.isEmpty)
                }
            }
        }
    }

    // MARK: - Section 3: Emoji packs

    private var emojiPacksSection: some View {
        section(
            title: "Emoji packs",
            footer: "Emoji sets you've subscribed to. Find more under Explore, or paste a pack link someone sent you."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if emojiRepo.referencedPackAddrs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No packs yet")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.palette.onSurfaceVariant)
                        Button {
                            tab = .explore
                        } label: {
                            Label("Browse emoji packs", systemImage: "sparkle.magnifyingglass")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.primary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ForEach(emojiRepo.referencedPackAddrs, id: \.self) { addr in
                        packRow(addr)
                    }
                }
                Button {
                    packAddress = ""
                    showAddPack = true
                } label: {
                    Label("Add by link", systemImage: "link")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.primary)
                }
                .buttonStyle(.plain)
                .disabled(addingPack)
            }
        }
    }

    /// A subscribed pack. Once resolved it renders as the same card used in
    /// Explore and in note content, so "Added" means the same thing and taps
    /// the same way everywhere. Until the kind-30030 arrives we can only show
    /// the coordinate, with a direct remove so a dead reference isn't stuck.
    @ViewBuilder
    private func packRow(_ addr: String) -> some View {
        if let pack = emojiRepo.resolvedPacks[addr] {
            EmojiPackCardView(pack: pack, style: .inline)
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortAddress(addr))
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Couldn't load this pack")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        do {
                            try await emojiRepo.removePackReference(addr, keypair: keypair)
                        } catch {
                            errorMessage = "Failed to publish updated emoji list."
                        }
                    }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 6)
        }
    }

    private var addPackSheet: some View {
        NavigationStack {
            Form {
                Section("Pack link") {
                    TextField("naddr1…", text: $packAddress, axis: .vertical)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Text("Paste an naddr link to an emoji pack. A raw `30030:<pubkey-hex>:<d-tag>` address works too.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add by link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showAddPack = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        guard let addr = normalizedPackAddress(packAddress) else {
                            errorMessage = "That doesn't look like an emoji pack link. Paste an `naddr1…` or a `30030:<pubkey>:<d>` address."
                            return
                        }
                        addingPack = true
                        showAddPack = false
                        Task {
                            defer { Task { @MainActor in addingPack = false } }
                            do {
                                try await emojiRepo.addPackReference(addr, keypair: keypair)
                            } catch {
                                errorMessage = "Failed to publish to relays."
                            }
                        }
                    }
                    .disabled(packAddress.isEmpty)
                }
            }
        }
    }

    /// Accept either form users actually have on hand: an `naddr1…` (optionally
    /// `nostr:`-prefixed) shared from another client, or the raw coordinate.
    /// Returns the canonical `30030:<pubkey>:<d>` address, or nil if the input
    /// isn't an emoji pack.
    private func normalizedPackAddress(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if emojiRepo.isValidPackAddress(trimmed) { return trimmed }
        guard case .addressRef(let dTag, _, let author, let kind)? = Nip19.decodeNostrUri(trimmed),
              kind == 30030,
              let author else { return nil }
        let addr = "30030:\(author):\(dTag)"
        return emojiRepo.isValidPackAddress(addr) ? addr : nil
    }

    // MARK: - Helpers

    private func shortAddress(_ addr: String) -> String {
        let parts = addr.split(separator: ":")
        guard parts.count == 3 else { return addr }
        let pk = String(parts[1])
        return "\(parts[0]):\(Nip19.shortNpub(hex: pk)):\(parts[2])"
    }

    private func isValidShortcode(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private var watchOnlyBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye")
                .foregroundStyle(Color.wispPrimary)
                .font(.subheadline)
                .padding(.top, 2)
            Text("Watch-only mode")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.onSurfaceVariant)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            }
        }
    }
}
