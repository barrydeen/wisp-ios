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
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var dismissY: CGFloat = 0
    @State private var imageSize: CGSize = .zero

    init(url: String, mime: String? = nil, showsCloseButton: Bool = true) {
        self.url = url
        self.mime = mime
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                    .ignoresSafeArea()
                    .opacity(dismissY > 0 ? max(0.3, 1.0 - Double(dismissY) / 250.0) : 1.0)

                imageContent
                    .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
                        if newSize.width > 0 && newSize.height > 0 { imageSize = newSize }
                    }
                    .scaleEffect(scale)
                    .offset(x: panOffset.width, y: panOffset.height + dismissY)
                    .gesture(pinchGesture(in: geo))
                    .simultaneousGesture(dragGesture(in: geo))
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

    private func pinchGesture(in geo: GeometryProxy) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = max(1.0, lastScale * value)
            }
            .onEnded { value in
                let newScale = max(1.0, lastScale * value)
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

    private func dragGesture(in geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if scale <= 1.01 {
                    dismissY = max(0, value.translation.height)
                } else {
                    let proposed = CGSize(
                        width: lastPanOffset.width + value.translation.width,
                        height: lastPanOffset.height + value.translation.height
                    )
                    panOffset = clampedOffset(proposed, scale: scale, in: geo.size)
                }
            }
            .onEnded { value in
                if scale <= 1.01 {
                    if value.translation.height > 120 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3)) { dismissY = 0 }
                    }
                } else {
                    lastPanOffset = panOffset
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
