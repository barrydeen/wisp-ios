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
        /// Pick mode used by the "Default reaction emoji" settings row. The
        /// callback receives the raw emoji string the user picked (unicode
        /// emoji, or `:shortcode:` for a custom emoji) — no quick-list side
        /// effect, no PickedEmoji wrapper. The caller writes it straight to
        /// `AppSettings.defaultReactionEmoji`.
        case pickForDefaultReaction((String) -> Void)
    }

    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var emojiRepo = EmojiRepository.shared
    @ObservedObject private var emojiCache = EmojiImageCache.shared
    @State private var selectedTab: String = ""
    @State private var searchQuery: String = ""
    /// Debounced search input. `searchQuery` updates on every keystroke;
    /// `debouncedQuery` lags behind by ~150ms so we only rebuild the filter
    /// grids once typing settles. Without this, every character triggered
    /// a full `EmojiData.searchEmojis` + `filteredCustom` pass on the main
    /// thread and the sheet stuttered noticeably for users typing quickly.
    @State private var debouncedQuery: String = ""
    @State private var debounceTask: Task<Void, Never>? = nil
    /// Memoized search results keyed by `debouncedQuery`. Recomputed only
    /// when the debounced query changes — previously every body re-eval
    /// (any scroll offset change, any pack image load that flipped
    /// `emojiCache.version`) re-ran the filter passes over the full
    /// catalog + custom pack list.
    @State private var unicodeMatches: [String] = []
    @State private var customMatches: [(shortcode: String, url: String)] = []
    /// When true, ignore scroll-driven tab updates briefly so a tab tap's
    /// `scrollTo` animation doesn't ping-pong with the position observer
    /// (the scroll lands on the target → observer sees it → tries to
    /// re-set the same tab → no-op, but the suppression is what prevents
    /// any intermediate-section transient from flickering the tab).
    @State private var suppressScrollSync = false
    @State private var suppressResetTask: Task<Void, Never>? = nil

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
            .onChange(of: searchQuery) { _, newValue in
                scheduleSearchUpdate(newValue)
            }
            .onDisappear {
                debounceTask?.cancel()
                suppressResetTask?.cancel()
            }
        }
    }

    /// Each section reports its top edge's y position (in the scroll's
    /// named coordinate space) so `onPreferenceChange` can pick the
    /// category that the user has just scrolled into view as the new
    /// `selectedTab`. The reporter is rendered as a 0-size background so
    /// it never contributes layout space — it only carries the geometry.
    @ViewBuilder
    private func sectionPositionReporter(id: String) -> some View {
        GeometryReader { proxy in
            Color.clear
                .preference(
                    key: SectionTopOffsetKey.self,
                    value: [id: proxy.frame(in: .named("emojiScroll")).minY]
                )
        }
    }

    /// Pick the section whose top edge is closest to (and not past) the
    /// scroll view's leading edge — i.e. the one currently sitting at the
    /// top of the visible window. We allow a small positive padding (16pt
    /// matches the outer VStack padding) so a section just barely below
    /// the leading edge still counts as "the current one" rather than
    /// staying on the previous category until the title scrolls all the
    /// way under the tab strip.
    private func nearestSectionToTop(in offsets: [String: CGFloat]) -> String? {
        guard !offsets.isEmpty else { return nil }
        let threshold: CGFloat = 16
        // Sections whose top is at or above the threshold; pick the one
        // with the *largest* (least negative) offset — that's the topmost
        // visible section.
        let aboveOrAt = offsets.filter { $0.value <= threshold }
        if let top = aboveOrAt.max(by: { $0.value < $1.value }) {
            return top.key
        }
        // All sections are below the threshold (e.g. on first appear);
        // pick the one closest to it from below.
        return offsets.min(by: { abs($0.value - threshold) < abs($1.value - threshold) })?.key
    }

    /// Temporarily silence scroll-driven tab updates when the user has
    /// just tapped a tab — the resulting programmatic `scrollTo` would
    /// otherwise emit a stream of intermediate-section offsets that flick
    /// the tab through every category between source and destination
    /// before settling.
    private func suppressScrollSyncBriefly() {
        suppressScrollSync = true
        suppressResetTask?.cancel()
        suppressResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            suppressScrollSync = false
        }
    }

    /// Debounce the search update so a rapid burst of keystrokes only
    /// produces one filter pass (the last one). 150ms keeps the response
    /// feel snappy while collapsing the typical 5–6 character query into
    /// a single rebuild.
    private func scheduleSearchUpdate(_ query: String) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
            guard trimmed != debouncedQuery else { return }
            debouncedQuery = trimmed
            unicodeMatches = trimmed.isEmpty ? [] : EmojiData.searchEmojis(trimmed)
            customMatches = trimmed.isEmpty ? [] : filteredCustom(trimmed)
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
                        customSection
                            .id("custom")
                            .background(sectionPositionReporter(id: "custom"))
                    }
                    ForEach(EmojiData.categories, id: \.name) { cat in
                        categorySection(cat)
                            .id(cat.name)
                            .background(sectionPositionReporter(id: cat.name))
                    }
                }
                .padding(16)
            }
            .coordinateSpace(name: "emojiScroll")
            .onPreferenceChange(SectionTopOffsetKey.self) { offsets in
                guard !suppressScrollSync else { return }
                guard let topmost = nearestSectionToTop(in: offsets) else { return }
                if topmost != selectedTab { selectedTab = topmost }
            }
            .onChange(of: selectedTab) { _, new in
                guard !new.isEmpty else { return }
                // Plain `scrollTo` — the previous `withAnimation` wrapper
                // forced a layout interpolation pass between the source
                // and destination anchors, which on long category lists
                // visibly stuttered on the first tap. Snap-jumps are
                // imperceptibly faster and match the system emoji
                // picker's behavior.
                proxy.scrollTo(new, anchor: .top)
            }
        }
    }

    private var filteredView: some View {
        ScrollView {
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
        case .pickForDefaultReaction: return "Default reaction"
        }
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        ScrollViewReader { stripProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs, id: \.id) { tab in
                        Button {
                            // Suppress the scroll-position observer briefly so
                            // the programmatic `scrollTo` triggered by setting
                            // `selectedTab` doesn't flick the highlight through
                            // every intermediate category before landing.
                            suppressScrollSyncBriefly()
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
                        .id("tab-\(tab.id)")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            // Keep the active tab visible as the user scrolls the grid —
            // without this, the highlighted tab slides off-screen once
            // the user reaches categories past the strip's overflow.
            .onChange(of: selectedTab) { _, new in
                guard !new.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    stripProxy.scrollTo("tab-\(new)", anchor: .center)
                }
            }
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
                // No per-cell `.onAppear { ensureLoaded }` here — the sheet's
                // top-level `.onAppear` already kicks off loads for every URL
                // in `resolvedCustomMap`, so repeating the call per cell only
                // added redundant scheduler hops on first paint.
                Color.clear
                    .overlay(
                        Text(":\(shortcode):")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 2)
                    )
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
            emojiRepo.addToQuickList(emoji)
            cb(.unicode(emoji))
        case .pickForQuickList:
            emojiRepo.addToQuickList(emoji)
            dismiss()
        case .pickForDefaultReaction(let cb):
            cb(emoji)
            dismiss()
        case .pickForDirectEmojiList:
            // Direct-emoji list only accepts custom shortcodes.
            break
        }
    }

    private func handleCustomPick(shortcode: String, url: String) {
        switch mode {
        case .pickForReaction(let cb):
            emojiRepo.addToQuickList(":\(shortcode):")
            cb(.custom(shortcode: shortcode, url: url))
        case .pickForQuickList:
            emojiRepo.addToQuickList(":\(shortcode):")
            dismiss()
        case .pickForDefaultReaction(let cb):
            cb(":\(shortcode):")
            dismiss()
        case .pickForDirectEmojiList(let cb):
            cb(shortcode, url)
            dismiss()
        }
    }
}

/// Per-section top-edge offsets in the scroll's named coordinate space.
/// Sections write their own entry via `.background(GeometryReader …)`; the
/// scroll view reads the merged dictionary and picks the one currently at
/// the top of the visible window to drive the tab strip highlight.
private struct SectionTopOffsetKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
