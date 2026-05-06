import UIKit

/// Swift port of Wolt's blurhash decoder (BSD-2). The Android counterpart at
/// `~/Dev/wisp/.../util/BlurHashDecoder.kt` is the reference; this file
/// follows the same algorithm verbatim — base-83 component decode, sRGB↔linear
/// conversions, and a cosine-basis evaluation per output pixel.
///
/// We always decode at low resolution (cap 32×32) and let SwiftUI scale the
/// resulting `UIImage` up via `.resizable()`. The blurhash signal is a 4-9
/// component cosine basis — there's no detail past ~32 pixels to recover, so
/// upscaling looks identical to a higher-res decode but costs ~16× less per
/// frame. Decoded images are cached in-process keyed by `"<hash>|<w>x<h>"`.
enum BlurHash {

    /// Decoded `UIImage` for `blurhash`, sized to `width`×`height` pixels.
    /// Returns nil for malformed input. `punch` boosts color saturation.
    static func decode(_ blurhash: String?, width: Int, height: Int, punch: Float = 1) -> UIImage? {
        guard let blurhash, blurhash.count >= 6, width > 0, height > 0 else { return nil }
        let cacheKey = "\(blurhash)|\(width)x\(height)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }

        let chars = Array(blurhash)

        guard let sizeFlag = decode83(chars, start: 0, end: 1) else { return nil }
        let numY = (sizeFlag / 9) + 1
        let numX = (sizeFlag % 9) + 1
        guard chars.count == 4 + 2 * numX * numY else { return nil }

        guard let quantMaxAc = decode83(chars, start: 1, end: 2) else { return nil }
        let maxAc = Float(quantMaxAc + 1) / 166

        var colors = [SIMD3<Float>](repeating: .zero, count: numX * numY)
        guard let dcValue = decode83(chars, start: 2, end: 6) else { return nil }
        colors[0] = decodeDc(dcValue)
        for i in 1..<colors.count {
            let from = 4 + i * 2
            guard let value = decode83(chars, start: from, end: from + 2) else { return nil }
            colors[i] = decodeAc(value, maxAc: maxAc * punch)
        }

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        for y in 0..<height {
            for x in 0..<width {
                var r: Float = 0
                var g: Float = 0
                var b: Float = 0
                for j in 0..<numY {
                    for i in 0..<numX {
                        let basis = cos(.pi * Float(x) * Float(i) / Float(width))
                                    * cos(.pi * Float(y) * Float(j) / Float(height))
                        let color = colors[j * numX + i]
                        r += color.x * basis
                        g += color.y * basis
                        b += color.z * basis
                    }
                }
                let offset = (y * width + x) * bytesPerPixel
                pixels[offset] = linearToSrgb(r)
                pixels[offset + 1] = linearToSrgb(g)
                pixels[offset + 2] = linearToSrgb(b)
                pixels[offset + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 1024
        return c
    }()

    private static func decode83(_ chars: [Character], start: Int, end: Int) -> Int? {
        var value = 0
        for i in start..<end {
            guard let digit = base83Map[chars[i]] else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    private static func decodeDc(_ value: Int) -> SIMD3<Float> {
        let r = Float(value >> 16) / 255
        let g = Float((value >> 8) & 0xff) / 255
        let b = Float(value & 0xff) / 255
        return SIMD3(srgbToLinear(r), srgbToLinear(g), srgbToLinear(b))
    }

    private static func decodeAc(_ value: Int, maxAc: Float) -> SIMD3<Float> {
        let r = value / (19 * 19)
        let g = (value / 19) % 19
        let b = value % 19
        return SIMD3(
            signedPow2((Float(r) - 9) / 9) * maxAc,
            signedPow2((Float(g) - 9) / 9) * maxAc,
            signedPow2((Float(b) - 9) / 9) * maxAc
        )
    }

    private static func srgbToLinear(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func linearToSrgb(_ value: Float) -> UInt8 {
        let v = max(0, min(1, value))
        let s = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, s * 255 + 0.5)))
    }

    private static func signedPow2(_ value: Float) -> Float {
        let magnitude = value * value
        return value < 0 ? -magnitude : magnitude
    }

    private static let base83Chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
    private static let base83Map: [Character: Int] = {
        var m: [Character: Int] = [:]
        for (i, c) in base83Chars.enumerated() { m[c] = i }
        return m
    }()
}
