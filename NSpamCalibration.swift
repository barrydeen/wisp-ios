import Foundation
import Compression

/// Calibration table produced alongside the LightGBM model. `calibration.npz` is a zip of
/// two `.npy` blobs (`calib_x.npy`, `calib_y.npy`), each storing four little-endian
/// Float32s. Used to convert `sigmoid(rawMargin)` into a calibrated probability via
/// piecewise-linear interpolation. Mirrors NSpamClassifier.calibrate in the Android port.
nonisolated final class NSpamCalibration: @unchecked Sendable {
    let calibX: [Float]
    let calibY: [Float]

    init(calibX: [Float], calibY: [Float]) {
        self.calibX = calibX
        self.calibY = calibY
    }

    enum LoadError: Error {
        case zipParseFailed
        case npyParseFailed
        case missingField(String)
        case unsupportedCompression(UInt16)
    }

    static func load(data: Data) throws -> NSpamCalibration {
        let bytes = [UInt8](data)
        let arrays = try parseNpz(bytes)
        guard let x = arrays["calib_x"] else { throw LoadError.missingField("calib_x") }
        guard let y = arrays["calib_y"] else { throw LoadError.missingField("calib_y") }
        return NSpamCalibration(calibX: x, calibY: y)
    }

    /// Piecewise-linear interpolation: clamp to ends, lerp between bracketing pairs.
    /// Input is the post-sigmoid raw score in [0, 1] for our trained model; output is the
    /// calibrated probability also in [0, 1].
    func score(rawScore: Float) -> Float {
        let cx = calibX
        let cy = calibY
        if cx.isEmpty { return rawScore }
        if rawScore <= cx[0] { return cy[0] }
        if rawScore >= cx[cx.count - 1] { return cy[cy.count - 1] }
        for i in 0..<cx.count - 1 {
            if rawScore >= cx[i] && rawScore < cx[i + 1] {
                let span = cx[i + 1] - cx[i]
                if span <= 0 { return cy[i + 1] }
                let t = (rawScore - cx[i]) / span
                return cy[i] + t * (cy[i + 1] - cy[i])
            }
        }
        return cy[cy.count - 1]
    }

    // MARK: - ZIP / NPY

    /// Walk ZIP local file headers and extract every `.npy` entry. Supports stored (method 0)
    /// and DEFLATE (method 8). numpy.savez_compressed defaults to DEFLATE; numpy.savez to
    /// stored. Our `calibration.npz` is DEFLATE.
    private static func parseNpz(_ b: [UInt8]) throws -> [String: [Float]] {
        var arrays: [String: [Float]] = [:]
        var off = 0
        while off + 30 <= b.count {
            let sig = read32LE(b, at: off)
            if sig != 0x04034b50 { break }

            let compressionMethod = read16LE(b, at: off + 8)
            let compressedSize = Int(read32LE(b, at: off + 18))
            let uncompressedSize = Int(read32LE(b, at: off + 22))
            let filenameLen = Int(read16LE(b, at: off + 26))
            let extraLen = Int(read16LE(b, at: off + 28))

            let filenameStart = off + 30
            let filenameEnd = filenameStart + filenameLen
            guard filenameEnd <= b.count else { throw LoadError.zipParseFailed }
            let filename = String(bytes: b[filenameStart..<filenameEnd], encoding: .ascii) ?? ""

            let dataStart = filenameEnd + extraLen
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= b.count else { throw LoadError.zipParseFailed }

            let entry: [UInt8]
            switch compressionMethod {
            case 0:
                entry = Array(b[dataStart..<dataEnd])
            case 8:
                let compressed = Array(b[dataStart..<dataEnd])
                guard let inflated = inflate(compressed, expectedSize: uncompressedSize) else {
                    throw LoadError.zipParseFailed
                }
                entry = inflated
            default:
                throw LoadError.unsupportedCompression(compressionMethod)
            }

            if filename.hasSuffix(".npy") {
                let key = String(filename.dropLast(4))
                if let arr = parseNpy(entry) {
                    arrays[key] = arr
                }
            }
            off = dataEnd
        }
        return arrays
    }

    /// Raw-DEFLATE decompression via `compression_decode_buffer` with COMPRESSION_ZLIB.
    /// (Apple's COMPRESSION_ZLIB takes raw deflate, no zlib header — matches what's in a ZIP.)
    private static func inflate(_ src: [UInt8], expectedSize: Int) -> [UInt8]? {
        guard expectedSize > 0 else { return [] }
        // Allow some slack in case the size hint is wrong.
        let cap = max(expectedSize * 2, 1024)
        var dst = [UInt8](repeating: 0, count: cap)
        let result = src.withUnsafeBufferPointer { (sBuf: UnsafeBufferPointer<UInt8>) -> Int in
            dst.withUnsafeMutableBufferPointer { (dBuf: inout UnsafeMutableBufferPointer<UInt8>) -> Int in
                guard let sPtr = sBuf.baseAddress, let dPtr = dBuf.baseAddress else { return -1 }
                return compression_decode_buffer(dPtr, cap, sPtr, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard result > 0 else { return nil }
        return Array(dst.prefix(result))
    }

    /// Parse a single `.npy` blob containing a 1-D `<f4` array.
    private static func parseNpy(_ b: [UInt8]) -> [Float]? {
        guard b.count > 10 else { return nil }
        // Magic: 0x93 'N' 'U' 'M' 'P' 'Y'
        guard b[0] == 0x93,
              b[1] == 0x4E, b[2] == 0x55, b[3] == 0x4D,
              b[4] == 0x50, b[5] == 0x59 else { return nil }

        let major = Int(b[6])
        let headerLen: Int
        let headerStart: Int
        if major <= 1 {
            headerLen = Int(read16LE(b, at: 8))
            headerStart = 10
        } else {
            headerLen = Int(read32LE(b, at: 8))
            headerStart = 12
        }
        let headerEnd = headerStart + headerLen
        guard headerEnd <= b.count else { return nil }

        let headerBytes = Array(b[headerStart..<headerEnd])
        guard let header = String(bytes: headerBytes, encoding: .ascii) else { return nil }

        guard header.contains("'descr': '<f4'") || header.contains("\"descr\": \"<f4\"") else {
            return nil
        }

        // Extract shape contents from `'shape': (n,)` or `'shape': (n, m)`.
        guard let shapeOpen = header.range(of: "'shape'")?.upperBound ?? header.range(of: "\"shape\"")?.upperBound,
              let lparen = header.range(of: "(", range: shapeOpen..<header.endIndex)?.lowerBound,
              let rparen = header.range(of: ")", range: lparen..<header.endIndex)?.lowerBound else {
            return nil
        }
        let inside = header[header.index(after: lparen)..<rparen]
        let dims = inside.split(separator: ",").compactMap { piece -> Int? in
            let t = piece.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : Int(t)
        }
        let count = dims.isEmpty ? 1 : dims.reduce(1, *)
        guard count > 0 else { return nil }

        let dataStart = headerEnd
        let dataEnd = dataStart + count * 4
        guard dataEnd <= b.count else { return nil }

        var result: [Float] = []
        result.reserveCapacity(count)
        var p = dataStart
        for _ in 0..<count {
            let bits = read32LE(b, at: p)
            result.append(Float(bitPattern: bits))
            p += 4
        }
        return result
    }

    @inline(__always)
    private static func read16LE(_ b: [UInt8], at off: Int) -> UInt16 {
        UInt16(b[off]) | (UInt16(b[off + 1]) << 8)
    }

    @inline(__always)
    private static func read32LE(_ b: [UInt8], at off: Int) -> UInt32 {
        UInt32(b[off]) |
            (UInt32(b[off + 1]) << 8) |
            (UInt32(b[off + 2]) << 16) |
            (UInt32(b[off + 3]) << 24)
    }
}
