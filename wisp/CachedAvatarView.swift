import SwiftUI

struct CachedAvatarView: View {
    let url: String?
    let size: CGFloat
    /// When true, this avatar always loads regardless of the global auto-download
    /// setting. Use for own-user avatars in the drawer/header.
    var alwaysLoad: Bool = false

    @Environment(AppSettings.self) private var settings
    @State private var uiImage: UIImage?
    @State private var animatedPayload: AnimatedImagePayload?
    @State private var loadFailed = false
    @State private var manualLoad = false

    private var shouldLoad: Bool {
        alwaysLoad || settings.autoLoadMedia || manualLoad
    }

    var body: some View {
        Group {
            if let animatedPayload {
                AnimatedImageRenderer(payload: animatedPayload, contentMode: .scaleAspectFill)
                    .allowsHitTesting(false)
            } else if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if loadFailed || url == nil || url?.isEmpty == true {
                placeholder
            } else if shouldLoad {
                placeholder
                    .task(id: url) { await loadImage() }
            } else {
                placeholder
                    .onTapGesture { manualLoad = true }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // Establish an explicit hit shape so enclosing Button / NavigationLink taps
        // (e.g. tap-pfp-to-open-sidebar) keep working when the inner renderer is a
        // UIViewRepresentable with hit-testing disabled.
        .contentShape(Circle())
    }

    private var placeholder: some View {
        Circle()
            .fill(Color.wispSurfaceVariant)
            .overlay {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
            }
    }

    private func loadImage() async {
        guard let url, !url.isEmpty else {
            loadFailed = true
            return
        }

        let data: Data
        if let cached = ImageCache.shared.get(url) {
            data = cached
        } else if let imageUrl = URL(string: url) {
            do {
                let (fetched, _) = try await URLSession.shared.data(from: imageUrl)
                ImageCache.shared.store(fetched, for: url)
                data = fetched
            } catch {
                loadFailed = true
                return
            }
        } else {
            loadFailed = true
            return
        }

        // Animated avatar path: try the multi-frame decoder first when the URL
        // looks animated and the user hasn't disabled it. Falls through to the
        // static UIImage path on single-frame payloads or when the toggle is off.
        if settings.animateAvatars,
           AnimatedImageHint.isLikelyAnimated(url: url, mime: nil),
           let payload = AnimatedImageDecoder.decode(data: data),
           payload.frames.count > 1 {
            animatedPayload = payload
            return
        }

        guard let img = UIImage(data: data) else {
            loadFailed = true
            return
        }
        uiImage = img
    }
}
