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

    /// Placeholder rendered while the image is loading or on failure. When the
    /// imeta tag carries dimension metadata the slot uses `aspectRatio(.fit)` so
    /// it occupies exactly the same height as the loaded image — no layout shift.
    /// Falls back to a fixed height when no dimension is available.
    @ViewBuilder
    private func placeholder(systemName: String?, height: CGFloat) -> some View {
        let blurImage = BlurHash.decode(meta.blurhash, width: 32, height: 32)
        let inferredAspect = ContentParser.parseAspectRatio(meta.dimension)
        Group {
            if let a = inferredAspect {
                Color.wispSurfaceVariant
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .aspectRatio(a, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.wispSurfaceVariant)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            }
        }
        .overlay {
            if let blurImage {
                Image(uiImage: blurImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .allowsHitTesting(false)
            }
        }
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
    /// Forwarded centroid translation when the image is unzoomed and embedded
    /// in `FullScreenMediaPager`. Fires on every recogniser update and once on
    /// end; `isEnded` distinguishes the two so the carousel can commit on
    /// release. Nil for the standalone viewer — it handles its own drag
    /// entirely (swipe-down dismisses, no on-screen close button).
    var onCarouselDrag: ((CGSize, Bool) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var dismissY: CGFloat = 0
    @State private var imageSize: CGSize = .zero
    /// True while a pinch is in flight. Set by the pinch gesture's
    /// `onChanged`, cleared on `onEnded`. The drag gesture reads it so a
    /// simultaneous two-finger drift translates the image in lock-step with
    /// the pinch, instead of being gated off because `scale` was still at
    /// 1.0 in the first frames.
    @State private var pinching = false

    /// True when this view runs standalone (handles its own dismiss) vs
    /// embedded inside `FullScreenMediaPager` (forwards drags to the pager).
    private var isStandalone: Bool { onCarouselDrag == nil }

    init(
        url: String,
        mime: String? = nil,
        onCarouselDrag: ((CGSize, Bool) -> Void)? = nil
    ) {
        self.url = url
        self.mime = mime
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
                // image. Attaches every drag / pinch / double-tap gesture
                // to a plain SwiftUI Rectangle — independent of whether
                // the visible image is a SwiftUI `Image` or a
                // UIViewRepresentable-hosted `UIImageView`, which used to
                // swallow gestures on animated content.
                // SwiftUI's gesture system can't deliver pinch + centroid pan
                // simultaneously on real hardware — neither two stacked
                // `.simultaneousGesture` modifiers nor a single composed
                // `SimultaneousGesture(magnification, drag)` reliably
                // surfaces drag translation while the pinch is active. So
                // every gesture for the fullscreen image — single-finger
                // pan, two-finger pinch with centroid pan, double-tap zoom
                // — runs through a single UIKit recognizer view here, whose
                // recognisers cooperate via their delegate's
                // `shouldRecognizeSimultaneouslyWith` returning true.
                ImageGesturesView(
                    onPanChanged: { translation in
                        handlePanChange(translation, in: geo.size)
                    },
                    onPanEnded: { translation in
                        handlePanEnd(translation, in: geo.size)
                    },
                    onPinchChanged: { pinchScale, centroidTranslation in
                        handlePinchChange(
                            magValue: pinchScale,
                            centroidTranslation: centroidTranslation,
                            in: geo.size
                        )
                    },
                    onPinchEnded: { pinchScale in
                        handlePinchEnd(magValue: pinchScale, in: geo.size)
                    },
                    onDoubleTap: { toggleZoom() }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Single drag gesture attached unconditionally to the image. Internally
    /// branches on `scale` and `isStandalone` to either pan inside a zoomed
    /// image, dismiss the standalone preview on vertical drag, or forward
    /// the drag to the carousel parent for paging / dismiss when embedded
    /// in `FullScreenMediaPager`.
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

    /// Single-finger pan handler. Driven by `UIPanGestureRecognizer` in
    /// `ImageGesturesView` (max 1 touch). Branches on whether the image is
    /// zoomed, standalone, or embedded in the pager.
    private func handlePanChange(_ translation: CGSize, in screenSize: CGSize) {
        if scale > 1.01 || pinching {
            let proposed = CGSize(
                width: lastPanOffset.width + translation.width,
                height: lastPanOffset.height + translation.height
            )
            panOffset = rubberBandedOffset(proposed, scale: scale, in: screenSize)
        } else if isStandalone {
            guard abs(translation.height) > abs(translation.width) else { return }
            dismissY = max(0, translation.height)
        } else {
            onCarouselDrag?(translation, false)
        }
    }

    private func handlePanEnd(_ translation: CGSize, in screenSize: CGSize) {
        if scale > 1.01 || pinching {
            let settled = clampedOffset(panOffset, scale: scale, in: screenSize)
            withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.78)) {
                panOffset = settled
            }
            lastPanOffset = settled
        } else if isStandalone {
            if translation.height > 120,
               abs(translation.height) > abs(translation.width) {
                dismiss()
            } else {
                withAnimation(.spring(response: 0.3)) { dismissY = 0 }
            }
        } else {
            onCarouselDrag?(translation, true)
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

    private func handlePinchChange(
        magValue: CGFloat,
        centroidTranslation: CGSize,
        in screenSize: CGSize
    ) {
        pinching = true
        let newScale = min(Self.maxScale, max(1.0, lastScale * magValue))
        scale = newScale
        // Apply scale + centroid translation in one go so the image follows
        // the two-finger pivot as the user pinches. Rubber-band lets the
        // offset overshoot bounds smoothly; spring-back on end settles it.
        let proposed = CGSize(
            width: lastPanOffset.width + centroidTranslation.width,
            height: lastPanOffset.height + centroidTranslation.height
        )
        panOffset = rubberBandedOffset(proposed, scale: newScale, in: screenSize)
    }

    private func handlePinchEnd(magValue: CGFloat, in screenSize: CGSize) {
        pinching = false
        let newScale = min(Self.maxScale, max(1.0, lastScale * magValue))
        scale = newScale
        lastScale = newScale
        if newScale <= 1.0 {
            withAnimation(.spring(response: 0.3)) {
                scale = 1.0
                lastScale = 1.0
                panOffset = .zero
                lastPanOffset = .zero
            }
        } else {
            let clamped = clampedOffset(panOffset, scale: newScale, in: screenSize)
            withAnimation(.spring(response: 0.3)) {
                panOffset = clamped
            }
            lastPanOffset = clamped
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

    /// Like `clampedOffset` but lets the offset overshoot past the bounds
    /// with progressive resistance (Apple's UIScrollView rubber-band).
    /// Inside the bounds it's the identity; past them it asymptotes to
    /// `dimension * c` so a flick can't tear the image off-screen.
    /// Caller is expected to spring back to the hard clamp on gesture end.
    private func rubberBandedOffset(_ offset: CGSize, scale: CGFloat, in screenSize: CGSize) -> CGSize {
        let img = imageSize == .zero ? screenSize : imageSize
        let maxX = max(0, (scale * img.width - screenSize.width) / 2.0)
        let maxY = max(0, (scale * img.height - screenSize.height) / 2.0)

        func band(_ value: CGFloat, limit: CGFloat, dimension: CGFloat) -> CGFloat {
            let mag = abs(value)
            if mag <= limit { return value }
            let direction: CGFloat = value >= 0 ? 1 : -1
            let overshoot = mag - limit
            // d = (1 - 1/(x*c/L + 1)) * L, c ≈ 0.55
            let c: CGFloat = 0.55
            let d = (1.0 - 1.0 / (overshoot * c / max(dimension, 1) + 1.0)) * dimension
            return direction * (limit + d)
        }

        return CGSize(
            width: band(offset.width, limit: maxX, dimension: screenSize.width),
            height: band(offset.height, limit: maxY, dimension: screenSize.height)
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

/// Hosts the UIKit recognisers (`UIPanGestureRecognizer` with max 1 touch,
/// `UIPinchGestureRecognizer`, double-tap `UITapGestureRecognizer`) for the
/// fullscreen image. All three recognise simultaneously via their shared
/// delegate, so a two-finger pinch can scale and pan in lock-step (via the
/// pinch recogniser's `location(in:)` centroid). Each recogniser feeds back
/// into SwiftUI through callbacks.
struct ImageGesturesView: UIViewRepresentable {
    let onPanChanged: (CGSize) -> Void
    let onPanEnded: (CGSize) -> Void
    let onPinchChanged: (CGFloat, CGSize) -> Void
    let onPinchEnded: (CGFloat) -> Void
    let onDoubleTap: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = true
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator
        view.addGestureRecognizer(doubleTap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPanChanged = onPanChanged
        context.coordinator.onPanEnded = onPanEnded
        context.coordinator.onPinchChanged = onPinchChanged
        context.coordinator.onPinchEnded = onPinchEnded
        context.coordinator.onDoubleTap = onDoubleTap
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPanChanged: onPanChanged,
            onPanEnded: onPanEnded,
            onPinchChanged: onPinchChanged,
            onPinchEnded: onPinchEnded,
            onDoubleTap: onDoubleTap
        )
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPanChanged: (CGSize) -> Void
        var onPanEnded: (CGSize) -> Void
        var onPinchChanged: (CGFloat, CGSize) -> Void
        var onPinchEnded: (CGFloat) -> Void
        var onDoubleTap: () -> Void

        private var pinchStartCentroid: CGPoint = .zero

        init(
            onPanChanged: @escaping (CGSize) -> Void,
            onPanEnded: @escaping (CGSize) -> Void,
            onPinchChanged: @escaping (CGFloat, CGSize) -> Void,
            onPinchEnded: @escaping (CGFloat) -> Void,
            onDoubleTap: @escaping () -> Void
        ) {
            self.onPanChanged = onPanChanged
            self.onPanEnded = onPanEnded
            self.onPinchChanged = onPinchChanged
            self.onPinchEnded = onPinchEnded
            self.onDoubleTap = onDoubleTap
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            let translation = CGSize(width: t.x, height: t.y)
            switch g.state {
            case .changed:
                onPanChanged(translation)
            case .ended, .cancelled, .failed:
                onPanEnded(translation)
            default:
                break
            }
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let view = g.view else { return }
            let centroid = g.location(in: view)
            switch g.state {
            case .began:
                pinchStartCentroid = centroid
                let translation = CGSize.zero
                onPinchChanged(g.scale, translation)
            case .changed:
                let translation = CGSize(
                    width: centroid.x - pinchStartCentroid.x,
                    height: centroid.y - pinchStartCentroid.y
                )
                onPinchChanged(g.scale, translation)
            case .ended, .cancelled, .failed:
                onPinchEnded(g.scale)
            default:
                break
            }
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            if g.state == .ended {
                onDoubleTap()
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
