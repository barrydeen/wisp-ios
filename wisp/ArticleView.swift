import SwiftUI
import UIKit

/// Full-screen reader for a NIP-23 long-form article (kind 30023). 1:1 port
/// of Android's `ArticleScreen`: header (cover image, title, author row,
/// hashtags), custom markdown block rendering, engagement action bar, and a
/// threaded comments section rendered with `PostCardView` rows.
struct ArticleView: View {
    let route: ArticleRoute
    let keypair: Keypair
    @Binding var path: NavigationPath

    @State private var viewModel = ArticleViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    private var activeUserIsWatchOnly: Bool {
        NostrKey.isWatchOnly(pubkey: keypair.pubkey)
    }

    /// Article-declared NIP-30 emojis merged under the user's resolved packs —
    /// resolved packs win on collision, matching Android's
    /// `articleEmojiMap + resolvedEmojis`.
    private var emojiMap: [String: String] {
        guard let article = viewModel.article else { return [:] }
        return ContentParser.parseEmojiTags(article.tags)
            .merging(EmojiRepository.shared.resolvedCustomMap) { _, resolved in resolved }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
        }
        .background(Color.wispBackground)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: route) {
            await viewModel.loadArticle(
                author: route.author,
                dTag: route.dTag,
                relayHints: route.relayHints
            )
            viewModel.loadComments(author: route.author, dTag: route.dTag)
        }
        .onDisappear { viewModel.cancel() }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            BackChevronButton { dismiss() }
            Text(viewModel.title ?? "Article")
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispOnSurface)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.wispBackground)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            VStack {
                Spacer()
                ProgressView().tint(Color.wispPrimary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if viewModel.article == nil {
            VStack {
                Spacer()
                Text("Article not found")
                    .font(AppFont.bodyLarge)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let article = viewModel.article {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header(article)
                    ForEach(Array(viewModel.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block, article: article)
                    }
                    if !activeUserIsWatchOnly {
                        Divider()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        ArticleActionBar(
                            article: article,
                            keypair: keypair,
                            replyCount: viewModel.comments.count,
                            authorProfile: viewModel.profiles[article.pubkey]
                        )
                        .padding(.horizontal, 8)
                    }
                    commentsSection
                    Spacer().frame(height: 32)
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ article: NostrEvent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let cover = viewModel.coverImage, let coverUrl = URL(string: cover) {
                RetryingAsyncImage(
                    url: coverUrl,
                    content: { image in
                        image
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    },
                    loading: {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.wispSurfaceVariant.opacity(0.4))
                            .frame(height: 180)
                            .overlay(ProgressView().controlSize(.small))
                    },
                    failure: { EmptyView() }
                )
                .padding(.top, 8)
                Spacer().frame(height: 16)
            }

            ArticleInlineText(
                text: viewModel.title ?? "Untitled",
                emojiMap: emojiMap,
                font: scaledUIFont(28, .semibold),
                color: UIColor(Color.wispOnSurface)
            )

            Spacer().frame(height: 12)

            Button {
                path.append(ProfileRoute(pubkey: article.pubkey))
            } label: {
                HStack(spacing: 8) {
                    CachedAvatarView(url: viewModel.profiles[article.pubkey]?.picture, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        EmojiText(
                            viewModel.profiles[article.pubkey]?.displayString
                                ?? Nip19.shortNpub(hex: article.pubkey),
                            emojiMap: viewModel.profiles[article.pubkey]?.emojiMap ?? [:],
                            textStyle: .subheadline,
                            weight: .semibold,
                            color: UIColor(Color.wispOnSurface)
                        )
                        if let publishedAt = viewModel.publishedAt {
                            Text(Self.formatArticleDate(publishedAt))
                                .font(AppFont.bodySmall)
                                .foregroundStyle(Color.wispOnSurfaceVariant)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            if !viewModel.hashtags.isEmpty {
                Spacer().frame(height: 12)
                FlowLayout(spacing: 6) {
                    ForEach(viewModel.hashtags, id: \.self) { tag in
                        Button {
                            path.append(HashtagFeedRoute(tag: tag))
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "number")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(tag)
                                    .font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.wispSurfaceVariant.opacity(0.6),
                                        in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(Color.wispPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer().frame(height: 16)
        }
        .padding(.horizontal, 16)
    }

    /// "MMM d, yyyy" — matches Android's `formatArticleDate`.
    static func formatArticleDate(_ epoch: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    // MARK: - Markdown blocks

    @ViewBuilder
    private func blockView(_ block: MdBlock, article: NostrEvent) -> some View {
        switch block {
        case .heading(let level, let text):
            ArticleInlineText(
                text: text,
                emojiMap: emojiMap,
                font: headingUIFont(level),
                color: UIColor(Color.wispOnSurface)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

        case .paragraph(let text):
            ArticleInlineText(
                text: text,
                emojiMap: emojiMap,
                font: scaledUIFont(15, .regular),
                color: UIColor(Color.wispOnSurface)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

        case .image(let url, let alt):
            VStack(alignment: .leading, spacing: 0) {
                if let imageUrl = URL(string: url) {
                    RetryingAsyncImage(
                        url: imageUrl,
                        content: { image in
                            image
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        },
                        loading: {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.wispSurfaceVariant.opacity(0.4))
                                .frame(height: 160)
                                .overlay(ProgressView().controlSize(.small))
                        },
                        failure: {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.wispSurfaceVariant.opacity(0.4))
                                .frame(height: 80)
                                .overlay(
                                    Image(systemName: "photo")
                                        .foregroundStyle(.secondary)
                                )
                        }
                    )
                }
                if let alt, !alt.isEmpty, alt != url {
                    Text(alt)
                        .font(AppFont.bodySmall)
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

        case .codeBlock(let code, _):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: settings.largeText ? 16 : 14, design: .monospaced))
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .padding(12)
            }
            .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

        case .blockQuote(let text):
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.wispPrimary.opacity(0.5))
                    .frame(width: 3, height: 24)
                ArticleInlineText(
                    text: text,
                    emojiMap: emojiMap,
                    font: scaledUIFont(15, .regular),
                    color: UIColor(Color.wispOnSurfaceVariant),
                    italic: true
                )
                .padding(.leading, 12)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

        case .horizontalRule:
            Divider()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

        case .nostrEmbed(let content):
            RichContentView(
                content: content,
                tags: article.tags,
                profiles: viewModel.profiles,
                authorPubkey: article.pubkey,
                onProfileTap: { pk in path.append(ProfileRoute(pubkey: pk)) },
                onNoteTap: { eid in path.append(ThreadRoute(eventId: eid, authorPubkey: nil)) },
                onHashtagTap: { tag in path.append(HashtagFeedRoute(tag: tag)) },
                linksEnabled: true
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private func headingUIFont(_ level: Int) -> UIFont {
        switch level {
        case 1: return scaledUIFont(32, .bold)        // headlineLarge
        case 2: return scaledUIFont(28, .semibold)    // headlineMedium
        case 3: return scaledUIFont(24, .semibold)    // headlineSmall
        case 4: return scaledUIFont(20, .bold)        // titleLarge
        case 5: return scaledUIFont(16, .semibold)    // titleMedium
        default: return scaledUIFont(14, .semibold)   // titleSmall
        }
    }

    private func scaledUIFont(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: settings.largeText ? size + 2 : size, weight: weight)
    }

    // MARK: - Comments

    @ViewBuilder
    private var commentsSection: some View {
        Divider()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        HStack(spacing: 8) {
            Text("Comments")
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispOnSurface)
            if !viewModel.comments.isEmpty {
                Text("(\(viewModel.comments.count))")
                    .font(AppFont.titleMedium)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)

        if viewModel.isCommentsLoading && viewModel.comments.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                    .tint(Color.wispPrimary)
                    .padding(8)
                Spacer()
            }
            .padding(.vertical, 16)
        }

        ForEach(viewModel.comments, id: \.event.id) { comment in
            PostCardView(
                event: comment.event,
                profile: viewModel.profiles[comment.event.pubkey],
                profiles: viewModel.profiles,
                onProfileTap: { pk in path.append(ProfileRoute(pubkey: pk)) },
                onNoteTap: { eid in
                    path.append(ThreadRoute(eventId: eid, authorPubkey: comment.event.pubkey))
                },
                onHashtagTap: { tag in path.append(HashtagFeedRoute(tag: tag)) }
            )
            .padding(.leading, CGFloat(min(comment.depth, 4)) * 24)
        }
    }
}

// MARK: - Action bar

/// Slim engagement bar for the article event: reply / react / repost / zap /
/// bookmark with counts. Mirrors `PostCardView.actionBar`'s wiring through
/// the shared services (`EngagementRepository`, `ReactionSender`,
/// `RepostSender`, `ComposePresenter`, `ZapSheet`) without extracting the
/// card's deeply-coupled private bar.
private struct ArticleActionBar: View {
    let article: NostrEvent
    let keypair: Keypair
    let replyCount: Int
    let authorProfile: ProfileData?

    @Environment(ComposePresenter.self) private var composePresenter: ComposePresenter?
    @Environment(WalletStore.self) private var walletStore: WalletStore?
    @State private var engagementRepo = EngagementRepository.shared
    @State private var noteListRepo = NoteListRepository.shared
    @State private var showReactionPicker = false
    @State private var showRepostDialog = false
    @State private var showZapSheet = false
    @State private var showBookmarkSheet = false

    private var box: EngagementBox { engagementRepo.box(for: article.id) }
    private var myPubkey: String { keypair.pubkey }

    private var myReactedKeys: Set<String> {
        Set(box.counts.reactors.filter { $0.pubkey == myPubkey }.map(\.emoji))
    }
    private var iReposted: Bool { box.counts.reposters.contains(myPubkey) }
    private var iZapped: Bool { box.counts.zappers.contains { $0.pubkey == myPubkey } }
    private var isBookmarked: Bool {
        !noteListRepo.listsContaining(noteId: article.id).isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            // Reply
            Button {
                composePresenter?.openReply(parent: article, root: nil)
            } label: {
                actionItem(icon: "bubble.right", count: replyCount)
            }
            .buttonStyle(.plain)
            Spacer()

            // React
            Button {
                showReactionPicker = true
            } label: {
                let reacted = !myReactedKeys.isEmpty
                actionItem(
                    icon: reacted ? "heart.fill" : "heart",
                    count: max(box.counts.reactions, box.counts.reactors.count),
                    tint: reacted ? Color.wispPrimary : nil
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showReactionPicker) {
                EmojiReactionPicker(
                    reactedKeys: myReactedKeys,
                    onSelect: { picked in
                        showReactionPicker = false
                        sendReaction(picked)
                    },
                    onPlus: {
                        showReactionPicker = false
                        composePresenter?.openEmojiReaction { picked in
                            sendReaction(picked)
                        }
                    }
                )
                .presentationCompactAdaptation(.popover)
            }
            Spacer()

            // Repost / quote
            Button {
                showRepostDialog = true
            } label: {
                actionItem(
                    icon: "arrow.2.squarepath",
                    count: box.counts.reposts,
                    tint: iReposted ? Color.wispRepostColor : nil
                )
            }
            .buttonStyle(.plain)
            .confirmationDialog("", isPresented: $showRepostDialog) {
                Button("Repost") { sendRepost() }
                Button("Quote") { composePresenter?.openQuote(article) }
            }
            Spacer()

            // Zap
            Button {
                showZapSheet = true
            } label: {
                let sats = box.counts.zapSats
                actionItem(
                    icon: "bolt",
                    label: sats > 0 ? CurrencyFormatter.short(sats: sats) : "0",
                    tint: iZapped ? Color.wispZapColor : nil
                )
            }
            .buttonStyle(.plain)
            Spacer()

            // Bookmark
            Button {
                showBookmarkSheet = true
            } label: {
                actionItem(
                    icon: isBookmarked ? "bookmark.fill" : "bookmark",
                    count: nil,
                    tint: isBookmarked ? Color.wispPrimary : nil
                )
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.secondary)
        .sheet(isPresented: $showZapSheet) {
            if let store = walletStore {
                ZapSheet(
                    store: store,
                    recipientPubkey: article.pubkey,
                    recipientLud16: authorProfile?.lud16,
                    recipientName: authorProfile?.displayString,
                    eventId: article.id,
                    extraTags: [],
                    forcePrivate: false,
                    onSuccess: { _ in },
                    dismiss: { showZapSheet = false }
                )
            }
        }
        .sheet(isPresented: $showBookmarkSheet) {
            NavigationStack {
                AddToNoteListSheet(keypair: keypair, event: article)
            }
        }
    }

    private func actionItem(icon: String, count: Int? = nil, label: String? = nil, tint: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(tint ?? .secondary)
            if let label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(tint ?? .secondary)
            } else if let count, count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(tint ?? .secondary)
            }
        }
        .frame(height: 28)
        .contentShape(Rectangle())
    }

    private func sendReaction(_ picked: PickedEmoji) {
        Task {
            try? await ReactionSender.shared.react(to: article, keypair: keypair, picked: picked)
        }
    }

    private func sendRepost() {
        Task {
            try? await RepostSender.shared.repost(article, keypair: keypair)
        }
    }
}

// MARK: - Inline text (markdown inline formatting + custom emoji)

/// Renders one markdown text block (heading / paragraph / blockquote) with
/// Android-parity inline formatting: links, bold / italic / bold-italic,
/// inline code, shortened nostr entities, and NIP-30 custom emoji rendered as
/// inline `NSTextAttachment` images (same approach as `EmojiText` /
/// `RichInlineTextView`).
private struct ArticleInlineText: View {
    let text: String
    let emojiMap: [String: String]
    let font: UIFont
    let color: UIColor
    var italic: Bool = false

    @ObservedObject private var emojiCache = EmojiImageCache.shared

    var body: some View {
        ArticleInlineTextRepresentable(
            text: text,
            emojiMap: emojiMap,
            font: italic ? font.withTraits(.traitItalic) : font,
            color: color,
            linkColor: UIColor(Color.wispPrimary),
            codeBackground: UIColor(Color.wispSurfaceVariant),
            emojiVersion: emojiCache.version
        )
    }
}

private struct ArticleInlineTextRepresentable: UIViewRepresentable {
    let text: String
    let emojiMap: [String: String]
    let font: UIFont
    let color: UIColor
    let linkColor: UIColor
    let codeBackground: UIColor
    /// Forces SwiftUI to re-evaluate when the emoji cache picks up a new image.
    let emojiVersion: Int

    func makeUIView(context: Context) -> UITextView {
        // Explicit TextKit 1 stack (NSLayoutManager-backed container). iOS 16+
        // would otherwise default a `UITextView(textContainer: nil)` to TextKit
        // 2, whose `sizeThatFits` lays out the whole document synchronously and
        // is pathologically slow on long article bodies. `widthTracksTextView`
        // lets the container wrap to the width SwiftUI proposes. Same approach
        // as `ContentSizingTextView` in RichInlineTextView.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let tv = UITextView(frame: .zero, textContainer: container)
        tv.backgroundColor = .clear
        tv.isEditable = false
        // Selectable so `.link` runs respond to taps; editing stays off.
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.dataDetectorTypes = []
        // Keep the attributed string's own link styling (wispPrimary +
        // underline) instead of the tint-colored UIKit default.
        tv.linkTextAttributes = [:]
        return tv
    }

    /// Owns sizing via SwiftUI's proposed width instead of `intrinsicContentSize`
    /// — the latter measures an unconstrained container as one infinite line,
    /// which truncated every block to a single line. Mirrors
    /// `RichInlineTextView.sizeThatFits`.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let proposedWidth = proposal.width
        let resolvedWidth: CGFloat
        if let w = proposedWidth, w.isFinite, w > 0 {
            resolvedWidth = w
        } else {
            resolvedWidth = max(1, UIScreen.main.bounds.width - 32)
        }
        uiView.textContainer.size = CGSize(width: resolvedWidth, height: CGFloat.greatestFiniteMagnitude)
        let size = uiView.sizeThatFits(CGSize(width: resolvedWidth, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: resolvedWidth, height: ceil(size.height))
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Trigger any not-yet-loaded emoji fetches that this block references.
        if !emojiMap.isEmpty {
            let ns = text as NSString
            let matches = MarkdownBlocks.emojiShortcodeRegex.matches(
                in: text, range: NSRange(location: 0, length: ns.length)
            )
            for m in matches where m.numberOfRanges >= 2 {
                let shortcode = ns.substring(with: m.range(at: 1))
                if let url = emojiMap[shortcode] {
                    EmojiImageCache.shared.ensureLoaded(url)
                }
            }
        }
        uiView.attributedText = ArticleInlineFormatter.build(
            text: text,
            emojiMap: emojiMap,
            font: font,
            color: color,
            linkColor: linkColor,
            codeBackground: codeBackground
        )
        uiView.invalidateIntrinsicContentSize()
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        var combined = fontDescriptor.symbolicTraits
        combined.insert(traits)
        guard let descriptor = fontDescriptor.withSymbolicTraits(combined) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

/// Port of Android's `formatInlineWithEmoji` (`ArticleScreen.kt`): a
/// character scan that styles `[text](url)` links, `***`/`**`/`*` (and `_`)
/// emphasis, backtick code spans, and nostr entities, with `:shortcode:`
/// custom emojis split out first and rendered as text attachments.
@MainActor
private enum ArticleInlineFormatter {

    static func build(
        text: String,
        emojiMap: [String: String],
        font: UIFont,
        color: UIColor,
        linkColor: UIColor,
        codeBackground: UIColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in splitForEmojis(text, emojiMap: emojiMap) {
            switch segment {
            case .text(let t):
                appendFormatted(
                    t, to: result,
                    font: font, color: color,
                    linkColor: linkColor, codeBackground: codeBackground
                )
            case .emoji(let shortcode, let url):
                let baseAttrs: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: color
                ]
                if let image = EmojiImageCache.shared.image(for: url) {
                    // Same sizing as `EmojiText`: ~1 line-height, baseline-aligned.
                    let attachment = NSTextAttachment()
                    let target = font.lineHeight * 1.05
                    let aspect = image.size.width > 0 && image.size.height > 0
                        ? image.size.width / image.size.height
                        : 1.0
                    attachment.image = image
                    attachment.bounds = CGRect(
                        x: 0, y: font.descender,
                        width: target * aspect, height: target
                    )
                    let attach = NSMutableAttributedString(attachment: attachment)
                    attach.addAttributes(baseAttrs, range: NSRange(location: 0, length: attach.length))
                    result.append(attach)
                } else {
                    result.append(NSAttributedString(string: ":\(shortcode):", attributes: baseAttrs))
                }
            }
        }
        return result
    }

    // MARK: Emoji segmentation (port of `splitTextForEmojis`)

    private enum Segment {
        case text(String)
        case emoji(shortcode: String, url: String)
    }

    private static func splitForEmojis(_ text: String, emojiMap: [String: String]) -> [Segment] {
        guard !emojiMap.isEmpty, text.contains(":") else { return [.text(text)] }
        let ns = text as NSString
        let matches = MarkdownBlocks.emojiShortcodeRegex.matches(
            in: text, range: NSRange(location: 0, length: ns.length)
        )
        var result: [Segment] = []
        var lastEnd = 0
        for m in matches where m.numberOfRanges >= 2 {
            let shortcode = ns.substring(with: m.range(at: 1))
            guard let url = emojiMap[shortcode] else { continue }
            if m.range.location > lastEnd {
                result.append(.text(ns.substring(
                    with: NSRange(location: lastEnd, length: m.range.location - lastEnd)
                )))
            }
            result.append(.emoji(shortcode: shortcode, url: url))
            lastEnd = m.range.location + m.range.length
        }
        if lastEnd < ns.length {
            result.append(.text(ns.substring(from: lastEnd)))
        } else if lastEnd == 0 && result.isEmpty {
            result.append(.text(text))
        }
        return result
    }

    // MARK: Inline scan (port of the Android char-by-char formatter)

    private static let nostrPrefixes = ["nostr:", "nevent1", "nprofile1", "naddr1", "npub1", "note1"]

    private static func appendFormatted(
        _ text: String,
        to out: NSMutableAttributedString,
        font: UIFont,
        color: UIColor,
        linkColor: UIColor,
        codeBackground: UIColor
    ) {
        let ns = text as NSString
        let len = ns.length
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var i = 0
        var plain = ""

        func flushPlain() {
            guard !plain.isEmpty else { return }
            out.append(NSAttributedString(string: plain, attributes: baseAttrs))
            plain = ""
        }
        func substr(_ from: Int, _ to: Int) -> String {
            ns.substring(with: NSRange(location: from, length: to - from))
        }
        func startsWith(_ s: String, _ at: Int) -> Bool {
            let sl = (s as NSString).length
            guard at + sl <= len else { return false }
            return ns.substring(with: NSRange(location: at, length: sl)) == s
        }
        func indexOf(_ s: String, _ from: Int) -> Int {
            guard from < len else { return NSNotFound }
            let r = ns.range(of: s, range: NSRange(location: from, length: len - from))
            return r.location
        }
        func appendChar() {
            // Advance by whole surrogate pairs: a non-BMP char (emoji, math
            // alphanumerics, …) spans two UTF-16 units, and slicing a lone
            // half turns it into U+FFFD when the NSString becomes a Swift
            // String. (Kotlin's StringBuilder reassembles halves; Swift can't.)
            let c = ns.character(at: i)
            if c >= 0xD800, c <= 0xDBFF, i + 1 < len {
                plain += substr(i, i + 2)
                i += 2
            } else {
                plain += substr(i, i + 1)
                i += 1
            }
        }
        func hasNostrPrefix(at idx: Int) -> Bool {
            for prefix in nostrPrefixes {
                let plen = prefix.count  // all-ASCII prefixes
                if idx + plen <= len,
                   ns.substring(with: NSRange(location: idx, length: plen)).lowercased() == prefix {
                    return true
                }
            }
            return false
        }

        while i < len {
            let c = ns.character(at: i)
            if startsWith("![", i) {
                // Image markup is rendered as its own block — skip it inline.
                let closeBracket = indexOf("]", i + 2)
                let closeParen = closeBracket != NSNotFound ? indexOf(")", closeBracket) : NSNotFound
                if closeBracket != NSNotFound, closeParen != NSNotFound,
                   closeBracket + 1 < len, ns.character(at: closeBracket + 1) == 0x28 /* ( */ {
                    i = closeParen + 1
                } else {
                    appendChar()
                }
            } else if c == 0x5B /* [ */ {
                let closeBracket = indexOf("]", i + 1)
                let openParen = closeBracket != NSNotFound ? closeBracket + 1 : NSNotFound
                if closeBracket != NSNotFound, closeBracket > i,
                   openParen < len, ns.character(at: openParen) == 0x28 /* ( */ {
                    let closeParen = indexOf(")", openParen)
                    if closeParen != NSNotFound, closeParen > openParen {
                        let linkText = substr(i + 1, closeBracket)
                        let urlText = substr(openParen + 1, closeParen)
                        flushPlain()
                        var attrs = baseAttrs
                        attrs[.foregroundColor] = linkColor
                        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                        // Deviation from Android (display-only): the URL is
                        // kept, so links inside articles are tappable.
                        if let url = URL(string: urlText) { attrs[.link] = url }
                        out.append(NSAttributedString(string: linkText, attributes: attrs))
                        i = closeParen + 1
                    } else {
                        appendChar()
                    }
                } else {
                    appendChar()
                }
            } else if startsWith("***", i) || startsWith("___", i) {
                let delim = substr(i, i + 3)
                let end = indexOf(delim, i + 3)
                if end != NSNotFound, end > i {
                    flushPlain()
                    var attrs = baseAttrs
                    attrs[.font] = font.withTraits([.traitBold, .traitItalic])
                    out.append(NSAttributedString(string: substr(i + 3, end), attributes: attrs))
                    i = end + 3
                } else {
                    appendChar()
                }
            } else if startsWith("**", i) || startsWith("__", i) {
                let delim = substr(i, i + 2)
                let end = indexOf(delim, i + 2)
                if end != NSNotFound, end > i {
                    flushPlain()
                    var attrs = baseAttrs
                    attrs[.font] = font.withTraits(.traitBold)
                    out.append(NSAttributedString(string: substr(i + 2, end), attributes: attrs))
                    i = end + 2
                } else {
                    appendChar()
                }
            } else if (c == 0x2A /* * */ || c == 0x5F /* _ */),
                      i + 1 < len, ns.character(at: i + 1) != 0x20 /* space */ {
                let delim = substr(i, i + 1)
                let end = indexOf(delim, i + 1)
                if end != NSNotFound, end > i + 1 {
                    flushPlain()
                    var attrs = baseAttrs
                    attrs[.font] = font.withTraits(.traitItalic)
                    out.append(NSAttributedString(string: substr(i + 1, end), attributes: attrs))
                    i = end + 1
                } else {
                    appendChar()
                }
            } else if c == 0x60 /* ` */ {
                let end = indexOf("`", i + 1)
                if end != NSNotFound, end > i {
                    flushPlain()
                    var attrs = baseAttrs
                    attrs[.font] = UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
                    attrs[.backgroundColor] = codeBackground
                    out.append(NSAttributedString(string: substr(i + 1, end), attributes: attrs))
                    i = end + 1
                } else {
                    appendChar()
                }
            } else if hasNostrPrefix(at: i) {
                let searchRange = NSRange(location: i, length: len - i)
                if let m = MarkdownBlocks.nostrInlineRegex.firstMatch(in: text, range: searchRange),
                   m.range.location == i {
                    flushPlain()
                    var attrs = baseAttrs
                    attrs[.foregroundColor] = linkColor
                    let entity = ns.substring(with: m.range)
                    out.append(NSAttributedString(
                        string: MarkdownBlocks.shortenNostrEntity(entity),
                        attributes: attrs
                    ))
                    i = m.range.location + m.range.length
                } else {
                    appendChar()
                }
            } else {
                appendChar()
            }
        }
        flushPlain()
    }
}
