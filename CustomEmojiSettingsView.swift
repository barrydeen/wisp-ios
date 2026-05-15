import SwiftUI

/// Settings screen for managing the user's reaction emojis and NIP-30 custom emoji state.
///
/// Three sections:
///   1. **Quick reactions** — the user-curated unicode/`:shortcode:` list shown in the
///      reaction picker. Tap to remove; "+" opens `EmojiLibrarySheet(.pickForQuickList)`.
///   2. **My custom emojis** — inline `["emoji", shortcode, url]` tags from the user's
///      kind-10030 event. Add via a small form (shortcode + URL); remove via swipe.
///      Each mutation publishes a new kind-10030.
///   3. **Emoji packs** — `a` references to external kind-30030 packs the user has
///      added (`30030:<pubkey>:<d>`). Add via paste-address; remove via swipe.
struct CustomEmojiSettingsView: View {
    let keypair: Keypair

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var emojiRepo = EmojiRepository.shared
    @ObservedObject private var emojiCache = EmojiImageCache.shared

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
                Group {
                    quickReactionsSection
                    directEmojisSection
                    emojiPacksSection
                }
                .disabled(keypair.isWatchOnly)
                .opacity(keypair.isWatchOnly ? 0.4 : 1)
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
            footer: "External NIP-51 emoji sets you've subscribed to. Paste the pack address to add — `30030:<pubkey>:<d>`."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if emojiRepo.referencedPackAddrs.isEmpty {
                    Text("No packs yet")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                } else {
                    ForEach(emojiRepo.referencedPackAddrs, id: \.self) { addr in
                        packRow(addr)
                    }
                }
                Button {
                    packAddress = ""
                    showAddPack = true
                } label: {
                    Label("Add emoji pack", systemImage: "plus.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.primary)
                }
                .buttonStyle(.plain)
                .disabled(addingPack)
            }
        }
    }

    private func packRow(_ addr: String) -> some View {
        let pack = emojiRepo.resolvedPacks[addr]
        let title = pack?.title ?? pack?.dTag ?? shortAddress(addr)
        let count = pack?.emojis.count ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(count) emoji" + (count == 1 ? "" : "s"))
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
            if let pack, !pack.emojis.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pack.emojis.prefix(20)) { e in
                            packEmojiThumb(e)
                        }
                        if pack.emojis.count > 20 {
                            Text("+\(pack.emojis.count - 20)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func packEmojiThumb(_ ce: CustomEmoji) -> some View {
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
        .frame(width: 28, height: 28)
    }

    private var addPackSheet: some View {
        NavigationStack {
            Form {
                Section("Pack address") {
                    TextField("30030:pubkey:d", text: $packAddress, axis: .vertical)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Text("Format: `30030:<pubkey-hex>:<d-tag>`")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add emoji pack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showAddPack = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let addr = packAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard emojiRepo.isValidPackAddress(addr) else {
                            errorMessage = "Pack address must look like `30030:<64-char-hex>:<d>`."
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
