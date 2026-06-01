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
        // When the URL changes on a reused view instance (same identity, new
        // pubkey), the previously-loaded `uiImage` keeps showing because the
        // `.task(id: url)` modifier above is only attached on the placeholder
        // branch — a fully-loaded view never re-enters it. Reset the image
        // caches here so a URL swap falls back through the placeholder branch
        // and re-fetches.
        .onChange(of: url) { _, _ in
            uiImage = nil
            animatedPayload = nil
            loadFailed = false
        }
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

        // Decode off the main thread — `UIImage(data:)` and the multi-frame
        // animated decoder are real CPU work that previously ran on MainActor
        // during scroll. The cheap `isLikelyAnimated` string check and the
        // setting are read on main; only the decode hops off.
        let tryAnimated = settings.animateAvatars
            && AnimatedImageHint.isLikelyAnimated(url: url, mime: nil)
        let decoded: DecodedAvatar = await Task.detached(priority: .utility) {
            if tryAnimated,
               let payload = AnimatedImageDecoder.decode(data: data),
               payload.frames.count > 1 {
                return .animated(payload)
            }
            if let img = UIImage(data: data) {
                return .still(img)
            }
            return .failed
        }.value

        if Task.isCancelled { return }
        switch decoded {
        case .animated(let payload): animatedPayload = payload
        case .still(let img): uiImage = img
        case .failed: loadFailed = true
        }
    }

    /// Result of an off-main avatar decode. `@unchecked Sendable` to cross the
    /// `Task.detached` boundary — mirrors `AnimatedImagePayload`; the payloads
    /// are immutable once decoded.
    private enum DecodedAvatar: @unchecked Sendable {
        case animated(AnimatedImagePayload)
        case still(UIImage)
        case failed
    }
}
