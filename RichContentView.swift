import SwiftUI
import UIKit

/// Sum of the rendered heights of a body's inline-text runs. Read by
/// `PostCardView` to decide whether to offer "Show more": the collapse
/// exists to tame long text walls, so media — galleries, single images,
/// videos — must not count toward it (a fixed-height gallery clipped by a
/// few points produced a toggle that revealed nothing). `reduce` *sums*
/// sibling values because text can be split into several runs by
/// interleaved media.
struct RichTextContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

struct RichContentView: View {
    let content: String
    let tags: [[String]]
    let profiles: [String: ProfileData]
    /// Hex pubkey of the note's author. When set, audio attachments inherit
    /// the author's display name + avatar for the floating mini-player so it
    /// reads as "Alice's audio note" rather than a bare filename.
    var authorPubkey: String? = nil
    var onProfileTap: ((String) -> Void)? = nil
    var onNoteTap: ((String) -> Void)? = nil
    var onHashtagTap: ((String) -> Void)? = nil
    /// Fires when the user taps inline plain text (no link / mention /
    /// hashtag at the tap point). The body's UITextView claims touches so
    /// long-press selection can engage; without this fallback the parent
    /// `.onTapGesture` for tap-to-thread fires inconsistently or not at all.
    var onPlainTextTap: (() -> Void)? = nil
    var showLinkPreviews: Bool = true
    /// When true, inline links / mentions / hashtags inside the rendered text
    /// fire on tap. Default false because feed cards wrap the whole content in a
    /// NavigationLink and need the tap to fall through; surfaces with no
    /// enclosing tap target (profile bio, composer preview) opt in.
    var linksEnabled: Bool = false
    /// When true (composer preview only), `@mention` runs render as rounded
    /// pills. Default false leaves feed / bio rendering unchanged.
    var mentionPillStyle: Bool = false
    /// When true, signal that this content is rendered inside a nested
    /// container (e.g. `QuotedNoteView` inside a `PostCardView` body) so
    /// children can size themselves against the actual available width
    /// rather than the full screen. Used by `MediaGridView` to opt out of
    /// its feed-only edge-bleed layout.
    var nested: Bool = false
    /// When true, each inline-text run publishes its rendered height up the
    /// `RichTextContentHeightKey` preference so the host card can base its
    /// "Show more" decision on text length alone. Off by default so nested
    /// bodies (quoted notes embedded in a feed card) don't leak their text
    /// height into the outer card's measurement.
    var reportsTextHeight: Bool = false
    /// Lets the host split a body into two stacked renderings so a "Show
    /// more" toggle can sit between long text and any trailing media:
    /// `.textPortion` renders only the leading inline-text groups,
    /// `.mediaPortion` renders everything from the first block/media group
    /// onward. `.all` (default) renders everything inline as before.
    var renderMode: RenderMode = .all

    enum RenderMode {
        case all
        case textPortion
        case mediaPortion
    }

    @Environment(AppSettings.self) private var settings
    @State private var emojiRepo = EmojiRepository.shared
    /// Index into `allMediaItems` of the currently-presented full-screen
    /// pager page, or nil when the pager is dismissed. Mirrors Android
    /// wisp PR #527 — every inline image/video tap in this post routes
    /// through one post-wide pager so the user can swipe between every
    /// piece of media regardless of layout style.
    @State private var fullScreenStart: Int? = nil

    /// Process-wide segment cache. `ContentParser.parse` runs an expensive
    /// combined regex over the note's content + reads every imeta tag — at
    /// 50–100 visible cards a scroll frame, recomputing on each body call
    /// stalls the main thread.
    ///
    /// Cache key is `"<emojiGeneration>|<content>"`. Without the generation
    /// prefix, a note that first paints before `EmojiRepository` has resolved
    /// its packs would lock in a "shortcode as plain text" parse that no
    /// later refresh could displace — exactly the symptom that caused custom
    /// emoji to render inconsistently. Old keys fall out of NSCache naturally
    /// once new ones evict them. `tags` are immutable for a given event so
    /// they aren't part of the key.
    private final class SegmentBox {
        let segments: [ContentSegment]
        init(_ segments: [ContentSegment]) { self.segments = segments }
    }
    private static let parseCache: NSCache<NSString, SegmentBox> = {
        let cache = NSCache<NSString, SegmentBox>()
        cache.countLimit = 512
        return cache
    }()

    private func memoizedParse() -> [ContentSegment] {
        let generation = emojiRepo.generation
        let key = "\(generation)|\(content)" as NSString
        if let box = Self.parseCache.object(forKey: key) { return box.segments }
        // Merge the user's resolved emoji packs under the note's own
        // `["emoji", shortcode, url]` tags — the inline tags carry the URL
        // the author/reactor signed for, so they win on shortcode collisions.
        var merged = emojiRepo.resolvedCustomMap
        for (shortcode, url) in ContentParser.parseEmojiTags(tags) {
            merged[shortcode] = url
        }
        let segments = ContentParser.parse(
            content: content,
            tags: tags,
            emojiMap: merged
        )
        Self.parseCache.setObject(SegmentBox(segments), forKey: key)
        return segments
    }

    var body: some View {
        let segments = memoizedParse()
        let allGroups = groupSegments(segments, gridLayout: settings.mediaLayoutStyle == .grid)
        let groups = filteredGroups(allGroups)
        // Post-wide list of every image / video / unknown-media segment, in
        // document order. Tile taps + inline image taps both translate the
        // tapped URL to an index in this list, so the pager shows everything
        // and starts on the right page.
        let allMediaItems = segments.compactMap(mediaItem(from:))

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                renderGroup(group, allMediaItems: allMediaItems)
            }
        }
        .fullScreenCover(item: Binding(
            get: { fullScreenStart.map { PagerSelection(index: $0) } },
            set: { fullScreenStart = $0?.index }
        )) { selection in
            FullScreenMediaPager(items: allMediaItems, initialIndex: selection.index)
        }
    }

    /// Split point for `.textPortion` / `.mediaPortion`: the first
    /// non-inline group. Inline = text / hashtag / mention / inlineLink /
    /// customEmoji (so `.textPortion` contains everything that contributes
    /// to the `RichTextContentHeightKey` sum). The first block — image,
    /// video, quoted note, link preview, etc. — starts the media portion.
    private func filteredGroups(_ groups: [SegmentGroup]) -> [SegmentGroup] {
        switch renderMode {
        case .all:
            return groups
        case .textPortion:
            let cut = groups.firstIndex(where: { !Self.isInlineGroup($0) }) ?? groups.count
            return Array(groups.prefix(cut))
        case .mediaPortion:
            let cut = groups.firstIndex(where: { !Self.isInlineGroup($0) }) ?? groups.count
            return Array(groups.dropFirst(cut))
        }
    }

    private static func isInlineGroup(_ g: SegmentGroup) -> Bool {
        if case .inline = g { return true }
        return false
    }

    /// Identifiable wrapper required by `fullScreenCover(item:)`. The pager
    /// itself takes a plain Int, but the cover needs an `Identifiable` to
    /// trigger presentation when the value changes.
    private struct PagerSelection: Identifiable, Hashable {
        let index: Int
        var id: Int { index }
    }

    private func openPager(for url: String, in allMediaItems: [MediaGridView.MediaItem]) {
        if let idx = allMediaItems.firstIndex(where: { $0.url == url }) {
            fullScreenStart = idx
        }
    }

    // MARK: - Grouping

    private enum SegmentGroup {
        case inline([ContentSegment])
        case block(ContentSegment)
        /// Run of 2+ consecutive media segments rendered as a tile grid. Only
        /// produced when the user's `mediaLayoutStyle` is `.grid`; otherwise
        /// each media item stays a separate `.block` and stacks vertically.
        case mediaGroup([ContentSegment])
    }

    private func groupSegments(_ segments: [ContentSegment], gridLayout: Bool) -> [SegmentGroup] {
        var groups: [SegmentGroup] = []
        var i = 0
        while i < segments.count {
            let seg = segments[i]
            if Self.isMedia(seg) {
                // Walk forward collecting consecutive media. Whitespace-only text
                // segments between media items are treated as joiners (e.g. ` `
                // between two URLs on the same line, or `\n\n` between two URLs
                // on separate lines), so an upload that splits its image URLs
                // across whitespace still gets grouped into one grid.
                var run = [seg]
                var j = i + 1
                while j < segments.count {
                    if Self.isMedia(segments[j]) {
                        run.append(segments[j])
                        j += 1
                    } else if case .text(let text) = segments[j],
                              text.allSatisfy(\.isWhitespace),
                              j + 1 < segments.count,
                              Self.isMedia(segments[j + 1]) {
                        j += 1  // skip the whitespace joiner
                    } else {
                        break
                    }
                }
                if gridLayout && run.count >= 2 {
                    groups.append(.mediaGroup(run))
                } else {
                    for m in run { groups.append(.block(m)) }
                }
                i = j
            } else if isInlineForRender(seg) {
                var run = [seg]
                var j = i + 1
                while j < segments.count, isInlineForRender(segments[j]) {
                    run.append(segments[j])
                    j += 1
                }
                groups.append(.inline(run))
                i = j
            } else {
                groups.append(.block(seg))
                i += 1
            }
        }
        return groups
    }

    /// Surfaces like the profile bio set `showLinkPreviews: false` — when
    /// previews are off, `.link` segments shouldn't claim their own block
    /// row (each row picks up the VStack's 8pt spacing, which stacks into
    /// painful gaps in a bio with several lines that end in URLs). Fold
    /// them into the surrounding inline text run so the bio reads as one
    /// continuous block.
    private func isInlineForRender(_ seg: ContentSegment) -> Bool {
        if Self.isInline(seg) { return true }
        if !showLinkPreviews, case .link = seg { return true }
        return false
    }

    private static func isMedia(_ seg: ContentSegment) -> Bool {
        switch seg {
        case .image, .video, .unknownMedia: return true
        default: return false
        }
    }

    private static func isInline(_ seg: ContentSegment) -> Bool {
        switch seg {
        case .text, .hashtag, .nostrProfile, .inlineLink, .customEmoji: return true
        default: return false
        }
    }

    // MARK: - Group Rendering

    @ViewBuilder
    private func renderGroup(_ group: SegmentGroup, allMediaItems: [MediaGridView.MediaItem]) -> some View {
        switch group {
        case .inline(let segs):
            if reportsTextHeight {
                inlineText(segs)
                    .background(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(
                                    key: RichTextContentHeightKey.self,
                                    value: proxy.size.height
                                )
                        }
                    )
            } else {
                inlineText(segs)
            }
        case .block(let seg):
            renderBlock(seg, allMediaItems: allMediaItems)
        case .mediaGroup(let segs):
            let runItems = segs.compactMap(mediaItem(from:))
            MediaGridView(
                items: runItems,
                nested: nested,
                onTileTap: { localIdx in
                    // The carousel's index is local to this run — translate
                    // to the post-wide index before opening the pager.
                    guard localIdx < runItems.count else { return }
                    openPager(for: runItems[localIdx].url, in: allMediaItems)
                }
            )
        }
    }

    private func mediaItem(from segment: ContentSegment) -> MediaGridView.MediaItem? {
        switch segment {
        case .image(let meta), .unknownMedia(let meta):
            return MediaGridView.MediaItem(url: meta.url, mime: meta.mime, dimension: meta.dimension, isVideo: false, posterUrl: meta.posterUrl)
        case .video(let meta):
            return MediaGridView.MediaItem(url: meta.url, mime: meta.mime, dimension: meta.dimension, isVideo: true, posterUrl: meta.posterUrl)
        default:
            return nil
        }
    }

    @ViewBuilder
    private func renderBlock(_ seg: ContentSegment, allMediaItems: [MediaGridView.MediaItem]) -> some View {
        switch seg {
        case .image(let meta), .unknownMedia(let meta):
            InlineImageView(meta: meta, onTap: {
                openPager(for: meta.url, in: allMediaItems)
            })
        case .video(let meta):
            InlineVideoView(meta: meta)
        case .audio(let meta):
            InlineAudioView(
                meta: meta,
                authorPubkey: authorPubkey,
                authorProfile: authorPubkey.flatMap { profiles[$0] }
            )
        case .link(let url):
            if showLinkPreviews {
                LinkPreviewView(url: url)
            } else {
                fallbackLink(url)
            }
        case .nostrNote(let eventId, let relayHints):
            QuotedNoteView(
                eventId: eventId,
                relayHints: relayHints,
                profiles: profiles,
                onProfileTap: onProfileTap,
                onNoteTap: onNoteTap,
                onHashtagTap: onHashtagTap
            )
        case .nostrAddressable(let dTag, _, let author, let kind):
            addressablePlaceholder(dTag: dTag, author: author, kind: kind)
        case .lightningInvoice(let invoice, let amount, let summary):
            LightningInvoiceView(invoice: invoice, amountSats: amount, summary: summary)
        default:
            EmptyView()
        }
    }

    private func fallbackLink(_ url: String) -> some View {
        Button {
            if let u = URL(string: url) { UIApplication.shared.open(u) }
        } label: {
            Text(shortDisplayUrl(url))
                .font(.callout)
                .foregroundStyle(.blue)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
    }

    private func shortDisplayUrl(_ url: String) -> String {
        var clean = url
        if clean.hasPrefix("https://") { clean = String(clean.dropFirst(8)) }
        else if clean.hasPrefix("http://") { clean = String(clean.dropFirst(7)) }
        if clean.hasPrefix("www.") { clean = String(clean.dropFirst(4)) }
        if clean.count > 50 { clean = String(clean.prefix(47)) + "\u{2026}" }
        return clean
    }

    private func addressablePlaceholder(dTag: String, author: String?, kind: Int?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(addressableTitle(kind: kind))
                    .font(.caption.weight(.semibold))
                Text(dTag)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurfaceVariant.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.wispSurfaceVariant, lineWidth: 1)
        )
    }

    private func addressableTitle(kind: Int?) -> String {
        switch kind {
        case 30023: return "Long-form article"
        case 30311: return "Live stream"
        case 30030: return "Emoji pack"
        case 34550: return "Community"
        default: return "Addressable event"
        }
    }

    // MARK: - Inline Text

    private func inlineText(_ segs: [ContentSegment]) -> some View {
        RichInlineTextView(
            segments: segs,
            profiles: profiles,
            linksEnabled: linksEnabled,
            onProfileTap: onProfileTap,
            onNoteTap: onNoteTap,
            onHashtagTap: onHashtagTap,
            onPlainTextTap: onPlainTextTap,
            mentionPillStyle: mentionPillStyle
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
