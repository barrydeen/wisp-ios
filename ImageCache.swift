import Foundation
import UIKit

nonisolated final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cacheDir: URL
    private let memoryCache = NSCache<NSString, NSData>()

    init() {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = cacheRoot.appendingPathComponent("wisp_avatars")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memoryCache.countLimit = 500
    }

    func get(_ urlString: String) -> Data? {
        let key = cacheKey(urlString)
        if let data = memoryCache.object(forKey: key as NSString) {
            return data as Data
        }
        let file = cacheDir.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: file) else { return nil }
        memoryCache.setObject(data as NSData, forKey: key as NSString)
        return data
    }

    /// True if this URL has bytes available either in memory or on disk. Cheaper
    /// than `get` when the caller only wants to skip a redundant fetch.
    func has(_ urlString: String) -> Bool {
        let key = cacheKey(urlString)
        if memoryCache.object(forKey: key as NSString) != nil { return true }
        let file = cacheDir.appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: file.path)
    }

    func store(_ data: Data, for urlString: String) {
        let key = cacheKey(urlString)
        memoryCache.setObject(data as NSData, forKey: key as NSString)
        let file = cacheDir.appendingPathComponent(key)
        try? data.write(to: file, options: .atomic)
    }

    private func cacheKey(_ urlString: String) -> String {
        var hash: UInt64 = 5381
        for byte in urlString.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}
