import SwiftUI

/// Full emoji browser presented as a sheet. Two-tier nav: a horizontal tab strip
/// of category icons, and a scrollable grid below. The "Custom" tab (if there are
/// any resolved custom emojis) is shown first, followed by the static unicode
/// categories from `EmojiData.categories`.
///
/// Three operating modes via `Mode`:
/// - `.pickForReaction` — selecting an emoji fires `onPick` (used by the post-card heart "+").
/// - `.pickForQuickList` — adds the emoji to the user's quick-reactions list and dismisses.
/// - `.pickForDirectEmojiList` — fires `onPickCustom` only for custom emojis (used for "add
///    to my emojis" flows that need shortcode + URL).
struct EmojiLibrarySheet: View {
    enum Mode {
        case pickForReaction((PickedEmoji) -> Void)
        case pickForQuickList
        case pickForDirectEmojiList((String, String) -> Void)
    }

    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var emojiRepo = EmojiRepository.shared
    @ObservedObject private var emojiCache = EmojiImageCache.shared
    @State private var selectedTab: String = ""
    @State private var searchQuery: String = ""

    private var hasCustom: Bool { !emojiRepo.resolvedCustomMap.isEmpty }

    private var tabs: [(id: String, label: String)] {
        var out: [(String, String)] = []
        if hasCustom { out.append(("custom", "✨")) }
        for c in EmojiData.categories { out.append((c.name, c.icon)) }
        return out
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    tabStrip
                    Divider()
                    categorizedView
                } else {
                    Divider()
                    filteredView
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if selectedTab.isEmpty { selectedTab = tabs.first?.id ?? "" }
                for url in emojiRepo.resolvedCustomMap.values {
                    emojiCache.ensureLoaded(url)
                }
            }
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search emoji", text: $searchQuery)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.10))
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var categorizedView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if hasCustom {
                        customSection.id("custom")
                    }
                    ForEach(EmojiData.categories, id: \.name) { cat in
                        categorySection(cat).id(cat.name)
                    }
                }
                .padding(16)
            }
            .onChange(of: selectedTab) { _, new in
                guard !new.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(new, anchor: .top)
                }
            }
        }
    }

    private var filteredView: some View {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let unicodeMatches = EmojiData.searchEmojis(q)
        let customMatches = filteredCustom(q)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !customMatches.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom").font(.headline)
                        customGrid(customMatches)
                    }
                }
                if !unicodeMatches.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Emoji").font(.headline)
                        unicodeGrid(unicodeMatches)
                    }
                }
                if customMatches.isEmpty && unicodeMatches.isEmpty {
                    HStack {
                        Spacer()
                        Text("No matches for \u{201C}\(searchQuery)\u{201D}")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 32)
                        Spacer()
                    }
                }
            }
            .padding(16)
        }
    }

    /// Filter the user's custom emoji set (direct + referenced packs) by
    /// shortcode substring match.
    private func filteredCustom(_ q: String) -> [(shortcode: String, url: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        for entry in emojiRepo.directEmojis where entry.shortcode.lowercased().contains(q) {
            if seen.insert(entry.shortcode).inserted {
                out.append((entry.shortcode, entry.url))
            }
        }
        for addr in emojiRepo.referencedPackAddrs {
            guard let pack = emojiRepo.resolvedPacks[addr] else { continue }
            for entry in pack.emojis where entry.shortcode.lowercased().contains(q) {
                if seen.insert(entry.shortcode).inserted {
                    out.append((entry.shortcode, entry.url))
                }
            }
        }
        return out
    }

    /// Flat unicode grid used by the filtered view — same column treatment as
    /// `categorySection` but without a per-category title.
    private func unicodeGrid(_ items: [String]) -> some View {
        let cols = [GridItem(.adaptive(minimum: 42, maximum: 56), spacing: 4)]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { e in
                Button {
                    handleUnicodePick(e)
                } label: {
                    Text(e)
                        .font(.system(size: 30))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var navTitle: String {
        switch mode {
        case .pickForReaction: return "Add reaction"
        case .pickForQuickList: return "Add to quick reactions"
        case .pickForDirectEmojiList: return "Pick custom emoji"
        }
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs, id: \.id) { tab in
                    Button {
                        selectedTab = tab.id
                    } label: {
                        Text(tab.label)
                            .font(.system(size: 22))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(selectedTab == tab.id
                                          ? Color.primary.opacity(0.10)
                                          : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Custom section

    private var customSection: some View {
        let groupedByPack = packGrouping()
        return VStack(alignment: .leading, spacing: 16) {
            Text("Custom")
                .font(.headline)
            ForEach(groupedByPack, id: \.title) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    customGrid(group.emojis)
                }
            }
        }
    }

    private struct CustomGroup {
        let title: String
        let emojis: [(shortcode: String, url: String)]
    }

    private func packGrouping() -> [CustomGroup] {
        var out: [CustomGroup] = []
        if !emojiRepo.directEmojis.isEmpty {
            out.append(CustomGroup(
                title: "My emojis",
                emojis: emojiRepo.directEmojis.map { ($0.shortcode, $0.url) }
            ))
        }
        for addr in emojiRepo.referencedPackAddrs {
            guard let pack = emojiRepo.resolvedPacks[addr], !pack.emojis.isEmpty else { continue }
            out.append(CustomGroup(
                title: pack.title ?? pack.dTag,
                emojis: pack.emojis.map { ($0.shortcode, $0.url) }
            ))
        }
        return out
    }

    private func customGrid(_ items: [(shortcode: String, url: String)]) -> some View {
        // Adaptive columns fill the sheet's available width — no right-side
        // dead zone like the previous fixed 6-col grid had on phone widths.
        let cols = [GridItem(.adaptive(minimum: 50, maximum: 64), spacing: 8)]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.shortcode) { item in
                Button {
                    handleCustomPick(shortcode: item.shortcode, url: item.url)
                } label: {
                    customImageCell(url: item.url, shortcode: item.shortcode)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func customImageCell(url: String, shortcode: String) -> some View {
        ZStack {
            if let img = emojiCache.image(for: url) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(2)
            } else {
                Color.clear
                    .overlay(
                        Text(":\(shortcode):")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 2)
                    )
                    .onAppear { emojiCache.ensureLoaded(url) }
            }
        }
        .frame(height: 50)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Category section

    private func categorySection(_ cat: EmojiCategory) -> some View {
        // Same adaptive treatment for unicode emojis. Slightly tighter min so
        // we get 7–8 columns at iPhone widths and ~12 on iPad.
        let cols = [GridItem(.adaptive(minimum: 42, maximum: 56), spacing: 4)]
        return VStack(alignment: .leading, spacing: 8) {
            Text(cat.name)
                .font(.headline)
            LazyVGrid(columns: cols, alignment: .leading, spacing: 4) {
                ForEach(cat.emojis, id: \.self) { e in
                    Button {
                        handleUnicodePick(e)
                    } label: {
                        Text(e)
                            .font(.system(size: 30))
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Pick handlers

    private func handleUnicodePick(_ emoji: String) {
        switch mode {
        case .pickForReaction(let cb):
            cb(.unicode(emoji))
        case .pickForQuickList:
            emojiRepo.addToQuickList(emoji)
            dismiss()
        case .pickForDirectEmojiList:
            // Direct-emoji list only accepts custom shortcodes.
            break
        }
    }

    private func handleCustomPick(shortcode: String, url: String) {
        switch mode {
        case .pickForReaction(let cb):
            cb(.custom(shortcode: shortcode, url: url))
        case .pickForQuickList:
            emojiRepo.addToQuickList(":\(shortcode):")
            dismiss()
        case .pickForDirectEmojiList(let cb):
            cb(shortcode, url)
            dismiss()
        }
    }
}
