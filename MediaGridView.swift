import SwiftUI

/// Horizontally-scrolling media gallery for posts with 2+ images or videos.
/// Single-item posts render through `RichContentView`'s existing
/// `InlineImageView` / `InlineVideoView` block path; this view kicks in only
/// when there are 2+ items and the user's `mediaLayoutStyle` is `.grid`.
///
/// Behaviour
///  - Each tile preserves its source aspect ratio and shares a uniform height,
///    so vertical photos stay vertical and horizontal stay horizontal.
///  - First tile renders flush left; the next tile peeks in from the right
///    edge so it's visually obvious there's more.
///  - Tap any tile → `FullScreenMediaPager` opens at that index, swipe to
///    navigate every item in the post.
struct MediaGridView: View {
    let items: [MediaItem]
    /// When true, the gallery is rendered inside another card (typically
    /// a `QuotedNoteView` embedded in a `PostCardView` body) and must
    /// size itself against the parent's available width via
    /// `GeometryReader` rather than the screen's full width. Without
    /// this opt-in, the feed's edge-bleed math (`screenWidth - 16`,
    /// negative trailing padding) overshoots the nested container by
    /// the parent's own padding (~28pt) and bleeds past the screen edge.
    var nested: Bool = false
    @State private var openIndex: Int?
    @State private var currentItemId: String?

    struct MediaItem: Hashable, Identifiable {
        let url: String
        let mime: String?
        let dimension: String?
        let isVideo: Bool
        /// Optional poster image URL for video items — typically the NIP-92
        /// imeta `image` field. When nil and `isVideo` is true, the tile falls
        /// back to a frame decoded by `VideoPosterCache`.
        let posterUrl: String?

        var id: String { url }

        /// Source aspect ratio (width / height) parsed from the imeta `dim` tag,
        /// or a sensible default. Videos default to 16:9, images default to 1:1.
        var aspect: CGFloat {
            ContentParser.parseAspectRatio(dimension) ?? (isVideo ? 16.0 / 9.0 : 1.0)
        }
    }

    /// Aspect ratio every tile snaps to (width / height). 4:5 reads as a
    /// gallery-style "tall card" — taller than square, which gives portrait
    /// photos room without cropping much, while horizontal photos crop to a
    /// pleasing centred slice. Common gallery aspect across modern social apps.
    private let tileAspect: CGFloat = 4.0 / 5.0
    /// Fraction of the gallery viewport one tile occupies. The remaining
    /// ~30% is the peek of the next tile bleeding in from the right edge.
    private let tileWidthFraction: CGFloat = 0.7
    private let tileSpacing: CGFloat = 6
    private let cornerRadius: CGFloat = 14

    /// PostCardView's body content sits at full card width with this much
    /// horizontal padding. The gallery uses a frame that's wider than the
    /// content column and bleeds past the right padding to the screen edge.
    private let cardLeadingPadding: CGFloat = 16

    private var currentIndex: Int {
        guard let id = currentItemId,
              let idx = items.firstIndex(where: { $0.id == id }) else { return 0 }
        return idx
    }

    var body: some View {
        if nested {
            nestedBody
        } else {
            feedBody
        }
    }

    /// Nested-container layout: ask `GeometryReader` for the actual
    /// available width and constrain the gallery to it. No edge bleed —
    /// the parent owns its own padding so we shouldn't paint over it.
    @ViewBuilder
    private var nestedBody: some View {
        GeometryReader { geo in
            let galleryWidth = geo.size.width
            let tileWidth = galleryWidth * tileWidthFraction
            let tileHeight = tileWidth / tileAspect

            ZStack(alignment: .bottom) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: tileSpacing) {
                        ForEach(items) { item in
                            tile(item, width: tileWidth, height: tileHeight)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $currentItemId)
                .frame(width: galleryWidth, height: tileHeight)

                if items.count > 1 {
                    indexBadge
                        .padding(.bottom, 12)
                }
            }
            .frame(width: galleryWidth, height: tileHeight, alignment: .leading)
        }
        .frame(height: tileHeightForNested)
        .fullScreenCover(item: Binding(
            get: { openIndex.map { GallerySelection(index: $0) } },
            set: { openIndex = $0?.index }
        )) { selection in
            FullScreenMediaPager(items: items, initialIndex: selection.index)
        }
        .onAppear {
            if currentItemId == nil { currentItemId = items.first?.id }
        }
    }

    /// Approximate tile height for the nested case. Used as the
    /// `GeometryReader`'s explicit height so the parent VStack reserves
    /// the right vertical space — `GeometryReader` itself is greedy.
    private var tileHeightForNested: CGFloat {
        // Same formula as feedBody, but anchored to a typical nested
        // container width (screen width minus the parent card's 16pt
        // padding minus the QuotedNoteView's 12pt inner padding × 2).
        let approxWidth = max(1, UIScreen.main.bounds.width - 56)
        return approxWidth * tileWidthFraction / tileAspect
    }

    @ViewBuilder
    private var feedBody: some View {
        let screenWidth = UIScreen.main.bounds.width
        // Gallery rect: from card's left padding (`cardLeadingPadding` from screen left)
        // all the way to the screen's right edge.
        let galleryWidth = screenWidth - cardLeadingPadding
        // Every tile renders at the same uniform size so the gallery reads as
        // one consistent strip regardless of source orientations. Width is
        // ~70% of the viewport, height derived from `tileAspect`.
        let tileWidth = galleryWidth * tileWidthFraction
        let tileHeight = tileWidth / tileAspect

        ZStack(alignment: .bottom) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: tileSpacing) {
                    ForEach(items) { item in
                        tile(item, width: tileWidth, height: tileHeight)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $currentItemId)
            .frame(width: galleryWidth, height: tileHeight)

            if items.count > 1 {
                indexBadge
                    .padding(.bottom, 12)
            }
        }
        .frame(width: galleryWidth, height: tileHeight, alignment: .leading)
        // Bleed past the body's trailing padding so tiles extend to the
        // screen's right edge. Leading already sits at the card's standard
        // 16pt padding because PostCardView's body content uses full card width
        // (no avatar indent).
        .padding(.trailing, -cardLeadingPadding)
        .fullScreenCover(item: Binding(
            get: { openIndex.map { GallerySelection(index: $0) } },
            set: { openIndex = $0?.index }
        )) { selection in
            FullScreenMediaPager(items: items, initialIndex: selection.index)
        }
        .onAppear {
            if currentItemId == nil { currentItemId = items.first?.id }
        }
    }

    @ViewBuilder
    private func tile(_ item: MediaItem, width: CGFloat, height: CGFloat) -> some View {
        Button {
            openIndex = items.firstIndex(of: item) ?? 0
        } label: {
            ZStack {
                MediaTileImage(item: item)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                if item.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var indexBadge: some View {
        Text("\(currentIndex + 1) / \(items.count)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.3), in: Capsule())
            .animation(.easeInOut(duration: 0.15), value: currentIndex)
    }

    private struct GallerySelection: Identifiable, Hashable {
        let index: Int
        var id: Int { index }
    }
}

/// Aspect-preserving image render for one gallery tile. GIF / animated WebP go
/// through the project's `AnimatedImageView`; everything else is `AsyncImage`
/// with `.scaledToFill` + `.clipped()` so the source completely covers the
/// tile rect even when the explicit width is rounded.
private struct MediaTileImage: View {
    let item: MediaGridView.MediaItem
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Group {
            if !settings.autoLoadMedia {
                placeholder
            } else if item.isVideo {
                videoPoster
            } else if AnimatedImageHint.isLikelyAnimated(url: item.url, mime: item.mime) {
                AnimatedImageView(
                    url: URL(string: item.url),
                    aspect: item.aspect,
                    placeholder: { placeholder },
                    failure: { placeholder }
                )
            } else {
                RetryingAsyncImage(
                    url: URL(string: item.url),
                    content: { image in image.resizable().scaledToFill() },
                    loading: { placeholder },
                    failure: { placeholder }
                )
            }
        }
        .clipped()
    }

    @ViewBuilder
    private var videoPoster: some View {
        // Prefer the imeta-supplied poster URL — instant and free of any video
        // bandwidth. Fall back to a frame decoded from the video itself so
        // dim-less / poster-less posts still get something visible.
        if let posterUrl = item.posterUrl, let url = URL(string: posterUrl) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    GeneratedVideoPoster(videoUrl: item.url) { placeholder }
                }
            }
        } else {
            GeneratedVideoPoster(videoUrl: item.url) { placeholder }
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.wispSurfaceVariant)
            .overlay {
                Image(systemName: item.isVideo ? "video" : "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
    }
}

/// Renders a frame decoded from the video itself via `VideoPosterCache`, falling
/// back to the supplied `fallback` view while the cache is populating (or if
/// generation fails). Used by the gallery and by `InlineVideoView` for the
/// pre-tap state.
struct GeneratedVideoPoster<Fallback: View>: View {
    let videoUrl: String
    @ViewBuilder let fallback: () -> Fallback
    @State private var cache = VideoPosterCache.shared

    var body: some View {
        Group {
            if let img = cache.images[videoUrl] {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback()
            }
        }
        .onAppear { cache.ensureGenerated(url: videoUrl) }
    }
}

/// Fullscreen pager that opens at `initialIndex` and lets the user swipe
/// horizontally between every media item in the post. Reuses
/// `FullScreenImageView` for image pages and `InlineVideoView` for videos.
struct FullScreenMediaPager: View {
    let items: [MediaGridView.MediaItem]
    let initialIndex: Int
    @Environment(\.dismiss) private var dismiss

    @State private var index: Int
    @State private var dragOffset: CGFloat = 0
    @State private var dismissY: CGFloat = 0
    /// Captured at gesture start so per-frame paging math doesn't have to
    /// re-read `geo.size.width` from inside the inner-driven callback.
    @State private var pageWidth: CGFloat = 0

    init(items: [MediaGridView.MediaItem], initialIndex: Int) {
        self.items = items
        self.initialIndex = initialIndex
        _index = State(initialValue: initialIndex)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                Color.black
                    .ignoresSafeArea()
                    .opacity(dismissY > 0 ? max(0.3, 1.0 - Double(dismissY) / 250.0) : 1.0)

                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        pageContent(for: item)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .offset(
                    x: -CGFloat(index) * geo.size.width + dragOffset,
                    y: dismissY
                )
                .onAppear { pageWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, new in pageWidth = new }

                if items.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(0..<items.count, id: \.self) { i in
                            Circle()
                                .fill(Color.white.opacity(i == index ? 0.9 : 0.35))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color.black.opacity(0.4), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    /// Receives centroid translation forwarded from the active inner
    /// FullScreenImageView (or video page) when it's not zoomed.
    /// Direction-routes between L/R paging and vertical-down dismiss;
    /// commits on `isEnded == true`.
    private func handleCarouselDrag(_ translation: CGSize, isEnded: Bool) {
        let dx = translation.width
        let dy = translation.height
        if !isEnded {
            if abs(dy) > abs(dx) {
                dismissY = max(0, dy)
                dragOffset = 0
            } else {
                var proposed = dx
                if (index == 0 && dx > 0) || (index == items.count - 1 && dx < 0) {
                    proposed = dx * 0.35
                }
                dragOffset = proposed
                dismissY = 0
            }
            return
        }
        if abs(dy) > abs(dx) {
            if dy > 120 {
                dismiss()
            } else {
                withAnimation(.spring(response: 0.3)) { dismissY = 0 }
            }
        } else {
            let threshold = pageWidth * 0.25
            var newIndex = index
            if dx < -threshold && index < items.count - 1 { newIndex += 1 }
            else if dx > threshold && index > 0 { newIndex -= 1 }
            withAnimation(.easeOut(duration: 0.25)) {
                index = newIndex
                dragOffset = 0
            }
        }
    }

    @ViewBuilder
    private func pageContent(for item: MediaGridView.MediaItem) -> some View {
        if item.isVideo {
            // Image pages forward their pan via `onCarouselDrag` from the
            // inner FullScreenImageView. Video pages can't do the same — the
            // AVPlayer surface swallows the drag — so we tell InlineVideoView
            // to passthrough hit tests and attach the matching drag gesture
            // here at the page level. The mute button on the player is a
            // sibling in the ZStack, not on the disabled render surface, so
            // it still receives taps.
            InlineVideoView(meta: MediaMeta(
                url: item.url,
                mime: item.mime,
                dimension: item.dimension
            ), passthroughHitTests: true)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .gesture(
                // Zero minimum distance so the drag engages on the first
                // pixel of movement — matches UIScrollView paging feel and
                // avoids the felt lag of the default 10pt threshold.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleCarouselDrag(value.translation, isEnded: false)
                    }
                    .onEnded { value in
                        handleCarouselDrag(value.translation, isEnded: true)
                    }
            )
        } else {
            FullScreenImageView(
                url: item.url,
                mime: item.mime,
                onCarouselDrag: { translation, ended in handleCarouselDrag(translation, isEnded: ended) }
            )
        }
    }
}
