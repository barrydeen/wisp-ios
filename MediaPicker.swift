import Foundation
import SwiftUI
import UIKit
import PhotosUI
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

struct PickedMedia: Identifiable {
    let id = UUID()
    /// For images, the original bytes. For videos, a poster/thumbnail JPEG (so the
    /// composer thumbnail has something to render without loading the whole video into
    /// memory). Empty if no thumbnail could be generated.
    let data: Data
    /// For videos this is the on-disk URL of the source clip — kept on disk so we don't
    /// have to read multi-hundred-MB videos into memory before compression. Nil for images.
    let sourceURL: URL?
    let mime: String
    let dim: CGSize
    let durationSec: Int?
    /// True if the underlying asset was a video. Used by the composer to drive kind selection.
    var isVideo: Bool { mime.hasPrefix("video/") }
}

enum MediaPickerError: Error {
    case unsupported
    case loadFailed
}

/// Loads bytes + dimensions for a `PhotosPickerItem`. Reads images via `Data` transferable
/// (preserves original bytes), and videos via a temp `MovieTransferable` to grab a URL we
/// can introspect with AVFoundation.
enum MediaPicker {

    static func loadAll(_ items: [PhotosPickerItem]) async -> [PickedMedia] {
        var out: [PickedMedia] = []
        for item in items {
            if let media = try? await load(item) {
                out.append(media)
            }
        }
        return out
    }

    static func load(_ item: PhotosPickerItem) async throws -> PickedMedia {
        let supportedTypes = item.supportedContentTypes
        let isVideo = supportedTypes.contains(where: { $0.conforms(to: .movie) })
        if isVideo {
            return try await loadVideo(item)
        }
        return try await loadImage(item)
    }

    private static func loadImage(_ item: PhotosPickerItem) async throws -> PickedMedia {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw MediaPickerError.loadFailed
        }
        let mime = inferImageMime(data: data, supportedTypes: item.supportedContentTypes)
        let dim = MediaCompressor.imageDimensions(data) ?? .zero
        return PickedMedia(data: data, sourceURL: nil, mime: mime, dim: dim, durationSec: nil)
    }

    private static func loadVideo(_ item: PhotosPickerItem) async throws -> PickedMedia {
        guard let movie = try await item.loadTransferable(type: MovieTransferable.self) else {
            throw MediaPickerError.loadFailed
        }
        let url = movie.url
        let mime = movie.mime
        let asset = AVURLAsset(url: url)
        var dim: CGSize = .zero
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            if let transform = try? await track.load(.preferredTransform) {
                let t = size.applying(transform)
                dim = CGSize(width: abs(t.width), height: abs(t.height))
            } else {
                dim = size
            }
        }
        var durationSec: Int? = nil
        if let cm = try? await asset.load(.duration) {
            let s = Int(CMTimeGetSeconds(cm))
            if s > 0 { durationSec = s }
        }
        // Generate a small poster JPEG for the composer thumbnail — way cheaper than
        // reading the whole video into memory just so the picker tile has something
        // to draw.
        let thumbData = await generateThumbnail(asset: asset)
        return PickedMedia(
            data: thumbData ?? Data(),
            sourceURL: url,
            mime: mime,
            dim: dim,
            durationSec: durationSec
        )
    }

    private static func generateThumbnail(asset: AVURLAsset) async -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        do {
            let cgImage: CGImage
            if #available(iOS 16.0, *) {
                let result = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600))
                cgImage = result.image
            } else {
                cgImage = try generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
            }
            return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.7)
        } catch {
            return nil
        }
    }

    private static func inferImageMime(data: Data, supportedTypes: [UTType]) -> String {
        if let utType = supportedTypes.first(where: { $0.conforms(to: .image) }),
           let pref = utType.preferredMIMEType {
            return pref
        }
        // Magic-byte fallback.
        let prefix = [UInt8](data.prefix(4))
        if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if prefix.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if prefix.count >= 4, prefix.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        return "image/jpeg"
    }
}

extension MediaPicker {
    /// Equivalent of `loadAll(_ items: [PhotosPickerItem])` but for `NSItemProvider`
    /// inputs delivered by `PHPickerViewController`. Used by `PhotosPickerPresenter`
    /// so the picker can be presented as a real UIKit modal without going through
    /// SwiftUI's `.photosPicker` modifier (which dismisses its parent sheet on
    /// some iOS versions when used from a sheet-hosted view).
    static func loadAll(providers: [NSItemProvider]) async -> [PickedMedia] {
        var out: [PickedMedia] = []
        for provider in providers {
            if let media = await load(provider: provider) {
                out.append(media)
            }
        }
        return out
    }

    private static func load(provider: NSItemProvider) async -> PickedMedia? {
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return await loadVideo(provider: provider)
        }
        return await loadImage(provider: provider)
    }

    private static func loadImage(provider: NSItemProvider) async -> PickedMedia? {
        let preferredTypes = [
            UTType.png.identifier,
            UTType.jpeg.identifier,
            UTType.heic.identifier,
            UTType.gif.identifier,
            UTType.webP.identifier,
            UTType.image.identifier
        ]
        var pickedTypeId: String? = nil
        for typeId in preferredTypes where provider.hasItemConformingToTypeIdentifier(typeId) {
            pickedTypeId = typeId
            break
        }
        guard let typeId = pickedTypeId,
              let data = await loadData(provider: provider, typeIdentifier: typeId) else {
            return nil
        }
        let supportedTypes = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let mime = inferImageMime(data: data, supportedTypes: supportedTypes)
        let dim = MediaCompressor.imageDimensions(data) ?? .zero
        return PickedMedia(data: data, sourceURL: nil, mime: mime, dim: dim, durationSec: nil)
    }

    private static func loadVideo(provider: NSItemProvider) async -> PickedMedia? {
        guard let sourceURL = await loadFileCopy(provider: provider, typeIdentifier: UTType.movie.identifier) else {
            return nil
        }
        let mime = UTType(filenameExtension: sourceURL.pathExtension)?.preferredMIMEType ?? "video/mp4"
        let asset = AVURLAsset(url: sourceURL)
        var dim: CGSize = .zero
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            if let transform = try? await track.load(.preferredTransform) {
                let t = size.applying(transform)
                dim = CGSize(width: abs(t.width), height: abs(t.height))
            } else {
                dim = size
            }
        }
        var durationSec: Int? = nil
        if let cm = try? await asset.load(.duration) {
            let s = Int(CMTimeGetSeconds(cm))
            if s > 0 { durationSec = s }
        }
        let thumbData = await generateThumbnail(asset: asset)
        return PickedMedia(
            data: thumbData ?? Data(),
            sourceURL: sourceURL,
            mime: mime,
            dim: dim,
            durationSec: durationSec
        )
    }

    private static func loadData(provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                cont.resume(returning: data)
            }
        }
    }

    /// `loadFileRepresentation` delivers a security-scoped URL that's deleted as
    /// soon as the completion handler returns. Copy the bytes to our own temp
    /// file so AVFoundation / `MediaCompressor` can read them after this method
    /// resolves.
    private static func loadFileCopy(provider: NSItemProvider, typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { source, _ in
                guard let source else {
                    cont.resume(returning: nil)
                    return
                }
                let copy = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
                try? FileManager.default.removeItem(at: copy)
                do {
                    try FileManager.default.copyItem(at: source, to: copy)
                    cont.resume(returning: copy)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

/// SwiftUI bridge to `PHPickerViewController`.
///
/// SwiftUI's `.photosPicker(isPresented:)` modifier and inline `PhotosPicker`
/// view both go through SwiftUI's sheet machinery to host the picker. When the
/// caller is already inside a `.sheet` / `.fullScreenCover` (e.g. compose),
/// iOS sometimes dismisses the host modal mid-scroll or after selection — the
/// gallery-picker-closes-compose bug we kept fighting. Presenting
/// `PHPickerViewController` directly through UIKit (`present(_:animated:)` on
/// a headless host) bypasses SwiftUI modal coordination entirely.
///
/// Caller is expected to attach this view as a `.background` of any visible
/// SwiftUI view in the same window:
///
///     .background(
///         PhotosPickerPresenter(isPresented: $showPicker, maxCount: 8) { providers in … }
///     )
struct PhotosPickerPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var maxCount: Int
    var onPick: ([NSItemProvider]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.backgroundColor = .clear
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        if isPresented {
            guard host.presentedViewController == nil else { return }
            var config = PHPickerConfiguration(photoLibrary: .shared())
            config.selectionLimit = maxCount
            config.filter = .any(of: [.images, .videos])
            config.preferredAssetRepresentationMode = .current
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = context.coordinator
            DispatchQueue.main.async {
                host.present(picker, animated: true)
            }
        } else if let presented = host.presentedViewController {
            presented.dismiss(animated: true)
        }
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var parent: PhotosPickerPresenter

        init(parent: PhotosPickerPresenter) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let providers = results.map(\.itemProvider)
            picker.dismiss(animated: true) {
                self.parent.isPresented = false
                if !providers.isEmpty {
                    self.parent.onPick(providers)
                }
            }
        }
    }
}

/// Movie transferable that copies the picked video to a temp file we can pass to AVFoundation.
struct MovieTransferable: Transferable {
    let url: URL
    let mime: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString + "-" + received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            let mime = UTType(filenameExtension: copy.pathExtension)?.preferredMIMEType ?? "video/mp4"
            return MovieTransferable(url: copy, mime: mime)
        }
    }
}
