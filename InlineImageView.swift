import SwiftUI

struct InlineImageView: View {
    let meta: MediaMeta
    @Environment(AppSettings.self) private var settings
    @State private var showFullScreen = false
    @State private var manualLoad = false

    var body: some View {
        let aspect = ContentParser.parseAspectRatio(meta.dimension)
        let height = aspect.map { width(for: $0) } ?? 200
        let isAnimated = AnimatedImageHint.isLikelyAnimated(url: meta.url, mime: meta.mime)

        Group {
            if settings.autoLoadMedia || manualLoad {
                if isAnimated {
                    AnimatedImageView(
                        url: URL(string: meta.url),
                        aspect: aspect,
                        placeholder: {
                            placeholder(systemName: nil, height: height)
                                .overlay { ProgressView() }
                        },
                        failure: {
                            placeholder(systemName: "photo", height: 200)
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                    .onTapGesture { showFullScreen = true }
                } else {
                    RetryingAsyncImage(
                        url: URL(string: meta.url),
                        content: { image in
                            image.resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .onTapGesture { showFullScreen = true }
                        },
                        loading: {
                            placeholder(systemName: nil, height: height)
                                .overlay { ProgressView() }
                        },
                        failure: {
                            placeholder(systemName: "photo", height: 200)
                                .overlay {
                                    VStack(spacing: 4) {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.title3)
                                        Text("Tap to retry")
                                            .font(.caption2)
                                    }
                                    .foregroundStyle(.secondary)
                                }
                        }
                    )
                }
            } else {
                Button {
                    manualLoad = true
                } label: {
                    placeholder(systemName: "photo", height: height)
                        .overlay {
                            VStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.title2)
                                Text("Tap to load image")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenImageView(url: meta.url, mime: meta.mime)
        }
    }

    private func placeholder(systemName: String?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.wispSurfaceVariant)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                if let systemName {
                    Image(systemName: systemName)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
    }

    private func width(for aspect: CGFloat) -> CGFloat {
        if aspect >= 1 { return 220 }
        return 320
    }
}

struct FullScreenImageView: View {
    let url: String
    let mime: String?
    let showsCloseButton: Bool
    /// Forwarded drag value when the image is unzoomed and embedded in
    /// `FullScreenMediaPager`. Fires on every onChanged and once on onEnded;
    /// `isEnded` distinguishes the two so the carousel can commit on release.
    /// Nil for the standalone viewer — it handles its own drag entirely.
    var onCarouselDrag: ((DragGesture.Value, Bool) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var dismissY: CGFloat = 0
    @State private var imageSize: CGSize = .zero

    init(
        url: String,
        mime: String? = nil,
        showsCloseButton: Bool = true,
        onCarouselDrag: ((DragGesture.Value, Bool) -> Void)? = nil
    ) {
        self.url = url
        self.mime = mime
        self.showsCloseButton = showsCloseButton
        self.onCarouselDrag = onCarouselDrag
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                    .ignoresSafeArea()
                    .opacity(dismissY > 0 ? max(0.3, 1.0 - Double(dismissY) / 250.0) : 1.0)

                gesturedImageContent(in: geo)

                // Transparent gesture-capturing overlay sitting above the
                // image and below the close button. Attaches every drag /
                // pinch / double-tap gesture to a plain SwiftUI Rectangle —
                // independent of whether the visible image is a SwiftUI
                // `Image` or a UIViewRepresentable-hosted `UIImageView`,
                // which used to swallow gestures on animated content.
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(pinchGesture(in: geo))
                    .simultaneousGesture(unifiedDrag(in: geo))
                    .onTapGesture(count: 2) { toggleZoom() }

                if showsCloseButton {
                    VStack {
                        HStack {
                            Spacer()
                            Button { dismiss() } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(12)
                                    .background(Color.black.opacity(0.6), in: Circle())
                            }
                            .padding()
                        }
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Applies gestures conditionally based on context.
    ///
    /// Standalone (`showsCloseButton == true`):
    ///   single drag gesture handles both pan-when-zoomed and dismiss-when-not.
    ///
    /// Carousel (`showsCloseButton == false`):
    ///   - **Not zoomed** — attach a *simultaneous* dismiss gesture that only
    ///     tracks dominantly-vertical drags. The TabView page-swipe recognizer
    ///     coexists and wins horizontal swipes, so L/R paging stays responsive.
    ///   - **Zoomed** — attach the pan gesture as `.gesture(...)` so it has
    ///     priority over TabView. A horizontal pan inside a zoomed image stays
    ///     in the image instead of accidentally paging to the next photo.
    /// Single drag gesture attached unconditionally to the image. Internally
    /// branches on `scale` (and on `showsCloseButton`) to either pan inside a
    /// zoomed image, dismiss the standalone preview on vertical drag, or
    /// forward the drag to the carousel parent for paging / dismiss when
    /// embedded in `FullScreenMediaPager`.
    ///
    /// Centralising every drag in one always-attached gesture eliminates the
    /// parent / child gesture-priority duel that used to leave gestures stuck
    /// after a zoom-in / zoom-out cycle. Gestures are never re-attached when
    /// scale crosses 1; only the branch logic inside the gesture changes.
    /// Renders the image with the live scale/offset transforms applied.
    /// All input gestures live on the transparent Color.clear overlay in
    /// `body`, so this view doesn't need any gesture modifiers — its only
    /// job is to draw the image.
    @ViewBuilder
    private func gesturedImageContent(in geo: GeometryProxy) -> some View {
        imageContent
            .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
                if newSize.width > 0 && newSize.height > 0 { imageSize = newSize }
            }
            .scaleEffect(scale)
            .offset(x: panOffset.width, y: panOffset.height + dismissY)
            .allowsHitTesting(false)
    }

    private func unifiedDrag(in geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if scale > 1.01 {
                    let proposed = CGSize(
                        width: lastPanOffset.width + value.translation.width,
                        height: lastPanOffset.height + value.translation.height
                    )
                    panOffset = clampedOffset(proposed, scale: scale, in: geo.size)
                } else if showsCloseButton {
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    dismissY = max(0, value.translation.height)
                } else {
                    onCarouselDrag?(value, false)
                }
            }
            .onEnded { value in
                if scale > 1.01 {
                    lastPanOffset = panOffset
                } else if showsCloseButton {
                    if value.translation.height > 120,
                       abs(value.translation.height) > abs(value.translation.width) {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3)) { dismissY = 0 }
                    }
                } else {
                    onCarouselDrag?(value, true)
                }
            }
    }

    @ViewBuilder
    private var imageContent: some View {
        if AnimatedImageHint.isLikelyAnimated(url: url, mime: mime) {
            AnimatedImageView(
                url: URL(string: url),
                aspect: nil,
                placeholder: { ProgressView().tint(.white) },
                failure: {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                }
            )
        } else {
            RetryingAsyncImage(
                url: URL(string: url),
                content: { image in
                    image.resizable().scaledToFit()
                },
                loading: { ProgressView().tint(.white) },
                failure: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise").font(.largeTitle)
                        Text("Tap to retry").font(.caption)
                    }
                    .foregroundStyle(.white)
                }
            )
        }
    }

    /// Upper bound on pinch zoom. Matches the system Photos.app default —
    /// enough headroom to read fine detail without letting the user zoom
    /// the image into pixel mush.
    private static let maxScale: CGFloat = 4.0

    private func pinchGesture(in geo: GeometryProxy) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newScale = min(Self.maxScale, max(1.0, lastScale * value))
                scale = newScale
                panOffset = clampedOffset(panOffset, scale: newScale, in: geo.size)
            }
            .onEnded { value in
                let newScale = min(Self.maxScale, max(1.0, lastScale * value))
                scale = newScale
                lastScale = newScale
                if newScale <= 1.0 {
                    withAnimation(.spring(response: 0.3)) {
                        panOffset = .zero
                        lastPanOffset = .zero
                    }
                } else {
                    let clamped = clampedOffset(panOffset, scale: newScale, in: geo.size)
                    withAnimation(.spring(response: 0.3)) {
                        panOffset = clamped
                        lastPanOffset = clamped
                    }
                }
            }
    }

    private func clampedOffset(_ offset: CGSize, scale: CGFloat, in screenSize: CGSize) -> CGSize {
        let img = imageSize == .zero ? screenSize : imageSize
        let maxX = max(0, (scale * img.width - screenSize.width) / 2.0)
        let maxY = max(0, (scale * img.height - screenSize.height) / 2.0)
        return CGSize(
            width: min(maxX, max(-maxX, offset.width)),
            height: min(maxY, max(-maxY, offset.height))
        )
    }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.3)) {
            if scale > 1.0 {
                scale = 1.0
                lastScale = 1.0
                panOffset = .zero
                lastPanOffset = .zero
            } else {
                scale = 2.0
                lastScale = 2.0
            }
        }
    }
}
