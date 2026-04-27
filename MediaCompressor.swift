import Foundation
import UIKit
import ImageIO
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

enum VideoCompressionError: Error {
    case writeFailed
    case exportFailed(String)
}

struct VideoCompressionResult {
    let data: Data
    let mime: String
    let dim: CGSize
    let durationSec: Int?
}

enum MediaCompressor {
    /// Skip compression for files smaller than this. Below ~256KB we already pay
    /// more in re-encode artifacts than we save in bandwidth.
    static let skipBelowBytes = 256 * 1024
    /// Cap on the long edge after resize. Mirrors the Android pipeline.
    static let maxLongEdge: CGFloat = 2048
    static let jpegQuality: CGFloat = 0.85

    struct Result {
        let data: Data
        let mime: String
        let dim: CGSize
    }

    /// Compress an image. Resizes to `maxLongEdge`, re-encodes JPEG (q=0.85), or PNG
    /// for images with alpha (which we infer from PNG/HEIC source). HEIC is always
    /// transcoded to JPEG so non-Apple clients can decode. Videos are not handled
    /// here — pass them through unchanged.
    static func compressImage(data: Data, mime: String) -> Result {
        if data.count < skipBelowBytes, let dim = imageDimensions(data) {
            return Result(data: data, mime: mime, dim: dim)
        }
        guard let image = UIImage(data: data) else {
            let fallback = imageDimensions(data) ?? .zero
            return Result(data: data, mime: mime, dim: fallback)
        }
        let resized = resize(image: image, maxLongEdge: maxLongEdge)
        let isHeic = mime.contains("heic") || mime.contains("heif")
        let isPng = mime == "image/png"
        let preserveAlpha = isPng && hasAlpha(resized)
        let outMime = (preserveAlpha ? "image/png" : "image/jpeg")
        let outData: Data
        if preserveAlpha {
            outData = resized.pngData() ?? data
        } else {
            outData = resized.jpegData(compressionQuality: jpegQuality) ?? data
        }
        let outDim = CGSize(width: resized.size.width * resized.scale,
                            height: resized.size.height * resized.scale)
        if isHeic {
            return Result(data: outData, mime: outMime, dim: outDim)
        }
        // If our compressed output is somehow larger than the source, keep the source.
        if outData.count >= data.count, let srcDim = imageDimensions(data) {
            return Result(data: data, mime: mime, dim: srcDim)
        }
        return Result(data: outData, mime: outMime, dim: outDim)
    }

    /// Read pixel dimensions of an image without decoding the full bitmap.
    static func imageDimensions(_ data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: w, height: h)
    }

    private static func resize(image: UIImage, maxLongEdge: CGFloat) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longEdge = max(pixelWidth, pixelHeight)
        guard longEdge > maxLongEdge else { return image }
        let scale = maxLongEdge / longEdge
        let target = CGSize(width: floor(pixelWidth * scale), height: floor(pixelHeight * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !hasAlpha(image)
        // Preserve wide-gamut colours (Display P3 from iPhone cameras) through the
        // resize. Default `.standard` flattens to sRGB, which strips the saturation
        // visible on color-managed viewers and produces washed-out uploads.
        // `UIImage.jpegData` then embeds the matching ICC profile in the output.
        format.preferredRange = .extended
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    // MARK: - Video

    /// Transcode the video at `sourceURL` to H.264/AAC `.mp4` (capped at 1920×1080 long
    /// edge) and return the encoded bytes ready for upload. We always return mp4 — even
    /// when the encoder happens to produce a slightly larger file than the source —
    /// because format compatibility (universal mp4) is worth more than a few percent of
    /// bandwidth. `.mov` from iPhone is the primary case the user cares about here.
    static func compressVideo(sourceURL: URL) async throws -> VideoCompressionResult {
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wisp-out-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let asset = AVURLAsset(url: sourceURL)
        let preset = AVAssetExportPreset1920x1080

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw VideoCompressionError.exportFailed("AVAssetExportSession init failed")
        }
        session.shouldOptimizeForNetworkUse = true

        // Use the iOS 18+ explicit throwing API so failures surface instead of silently
        // leaving an empty output file behind.
        if #available(iOS 18.0, *) {
            try await session.export(to: outputURL, as: .mp4)
        } else {
            session.outputURL = outputURL
            session.outputFileType = .mp4
            await session.export()
            guard session.status == .completed else {
                let msg = session.error?.localizedDescription ?? "status=\(session.status.rawValue)"
                throw VideoCompressionError.exportFailed(msg)
            }
        }

        let outputData: Data
        do {
            outputData = try Data(contentsOf: outputURL)
        } catch {
            throw VideoCompressionError.exportFailed("read output failed: \(error)")
        }

        // Pull final dim and duration from the encoded file.
        let outAsset = AVURLAsset(url: outputURL)
        var dim = CGSize.zero
        if let track = try? await outAsset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            if let transform = try? await track.load(.preferredTransform) {
                let t = size.applying(transform)
                dim = CGSize(width: abs(t.width), height: abs(t.height))
            } else {
                dim = size
            }
        }
        var durationSec: Int?
        if let cmDuration = try? await outAsset.load(.duration) {
            let s = Int(CMTimeGetSeconds(cmDuration))
            if s > 0 { durationSec = s }
        }

        return VideoCompressionResult(data: outputData, mime: "video/mp4", dim: dim, durationSec: durationSec)
    }

    private static func hasAlpha(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        switch cg.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        default:
            return false
        }
    }
}
