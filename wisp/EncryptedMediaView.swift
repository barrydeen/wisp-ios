import SwiftUI
import UIKit

/// In-memory cache for DECRYPTED DM media. Never persisted to disk — the plaintext of a
/// private DM must not leak into the shared on-disk image caches. Evicted under memory
/// pressure by `NSCache`. Keyed by the message's rumor id (stable across relays).
final class DecryptedImageCache {
    static let shared = DecryptedImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private init() { cache.countLimit = 80 }
    func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func set(_ image: UIImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
}

/// Downloads, AES-256-GCM-decrypts, and renders an inline NIP-17 kind-15 encrypted image.
/// Video / other types show a tappable placeholder card (full inline playback is a
/// follow-up). Decrypted bytes live only in `DecryptedImageCache` (memory); the
/// encrypted blob may be URLSession-disk-cached (useless without the key).
struct EncryptedMediaView: View {
    let metadata: EncryptedFileMetadata
    /// Stable cache key — the message's rumor id.
    let cacheKey: String

    @State private var image: UIImage?
    @State private var failed = false

    private let maxWidth: CGFloat = 256

    var body: some View {
        Group {
            if metadata.mimeType.hasPrefix("image/") {
                imageBody
            } else {
                fileCard
            }
        }
    }

    @ViewBuilder
    private var imageBody: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(image.size, contentMode: .fit)
                .frame(maxWidth: maxWidth)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if failed {
            placeholder(system: "exclamationmark.triangle", text: "Couldn't load image")
        } else {
            placeholder(system: "lock.fill", text: "Decrypting…")
                .task(id: cacheKey) { await load() }
        }
    }

    private var fileCard: some View {
        HStack(spacing: 10) {
            Image(systemName: metadata.mimeType.hasPrefix("video/") ? "play.rectangle.fill" : "doc.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.wispPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text(metadata.mimeType.hasPrefix("video/") ? "Video" : "File")
                    .font(.subheadline.weight(.semibold))
                if let size = metadata.size {
                    Text(byteString(size)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 12))
    }

    private func placeholder(system: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: system).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 180, height: 120)
        .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 12))
    }

    private func load() async {
        if let cached = DecryptedImageCache.shared.image(for: cacheKey) {
            image = cached
            return
        }
        guard let url = URL(string: metadata.fileUrl) else { failed = true; return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let plain = try EncryptedMedia.decryptFile(data, keyHex: metadata.keyHex, nonceHex: metadata.nonceHex)
            if let img = UIImage(data: plain) {
                DecryptedImageCache.shared.set(img, for: cacheKey)
                image = img
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
