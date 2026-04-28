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
                    AsyncImage(url: URL(string: meta.url)) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .onTapGesture { showFullScreen = true }
                        case .failure:
                            placeholder(systemName: "photo", height: 200)
                        default:
                            placeholder(systemName: nil, height: height)
                                .overlay { ProgressView() }
                        }
                    }
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

    init(url: String, mime: String? = nil, showsCloseButton: Bool = true) {
        self.url = url
        self.mime = mime
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
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
                .scaleEffect(scale)
                .gesture(zoomGesture)
                .onTapGesture(count: 2) { toggleZoom() }
            } else {
                AsyncImage(url: URL(string: url)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .gesture(zoomGesture)
                            .onTapGesture(count: 2) { toggleZoom() }
                    default:
                        ProgressView().tint(.white)
                    }
                }
            }

            if showsCloseButton {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
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
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in scale = lastScale * value }
            .onEnded { _ in lastScale = scale }
    }

    private func toggleZoom() {
        withAnimation {
            scale = scale > 1 ? 1 : 2
            lastScale = scale
        }
    }
}
