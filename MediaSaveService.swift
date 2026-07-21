import Photos
import UIKit

enum MediaSaveService {
    enum SaveError: Error {
        case denied
        case badURL
        case fetchFailed
    }

    /// Saves an image at `url` to the Photos library. Checks `ImageCache`
    /// first to avoid a redundant network fetch when the image is already
    /// resident from the feed.
    static func saveImageToPhotos(url: String) async throws {
        let data: Data
        if let cached = ImageCache.shared.get(url) {
            data = cached
        } else if let imageURL = URL(string: url) {
            let (fetched, _) = try await URLSession.shared.data(from: imageURL)
            data = fetched
        } else {
            throw SaveError.badURL
        }
        guard let image = UIImage(data: data) else { throw SaveError.fetchFailed }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    /// Downloads a video from `url` to a temporary file then saves to Photos.
    static func saveVideoToPhotos(url: String) async throws {
        guard let videoURL = URL(string: url) else { throw SaveError.badURL }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        let (downloadedURL, _) = try await URLSession.shared.download(from: videoURL)
        try FileManager.default.moveItem(at: downloadedURL, to: tempFile)

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: tempFile)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempFile)
            throw error
        }
        try? FileManager.default.removeItem(at: tempFile)
    }
}
