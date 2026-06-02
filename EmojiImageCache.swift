import Foundation
import UIKit
import Combine

@MainActor
final class EmojiImageCache: ObservableObject {
    static let shared = EmojiImageCache()

    @Published private(set) var version: Int = 0
    private var memory: [String: UIImage] = [:]
    private var inflight: Set<String> = []
    private var failed: Set<String> = []

    private let diskDir: URL = {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = cacheRoot.appendingPathComponent("wisp_emojis")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func image(for url: String) -> UIImage? {
        memory[url]
    }

    /// Triggers async load if not cached and not failed. Posts version updates as images arrive.
    /// Network fetches are skipped when the user has disabled `autoLoadMedia`; on-disk hits
    /// still surface because they're effectively free.
    func ensureLoaded(_ url: String) {
        if memory[url] != nil { return }
        if inflight.contains(url) || failed.contains(url) { return }

        // disk hit
        let diskFile = diskDir.appendingPathComponent(diskKey(url))
        #if DEBUG
        PerfTrace.mark("emoji.diskRead", url: url)
        #endif
        if let data = try? Data(contentsOf: diskFile), let img = UIImage(data: data) {
            memory[url] = img
            version &+= 1
            return
        }

        guard AppSettings.shared.autoLoadMedia else { return }

        inflight.insert(url)
        Task { [weak self] in
            guard let self else { return }
            await self.fetch(url)
        }
    }

    func ensureLoadedAll(_ urls: [String]) {
        for url in urls { ensureLoaded(url) }
    }

    private func fetch(_ urlString: String) async {
        guard let url = URL(string: urlString) else {
            failed.insert(urlString)
            inflight.remove(urlString)
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let img = UIImage(data: data) {
                memory[urlString] = img
                let file = diskDir.appendingPathComponent(diskKey(urlString))
                try? data.write(to: file, options: .atomic)
                inflight.remove(urlString)
                version &+= 1
                return
            }
        } catch {
            // fall through
        }
        failed.insert(urlString)
        inflight.remove(urlString)
    }

    private nonisolated func diskKey(_ urlString: String) -> String {
        var hash: UInt64 = 5381
        for byte in urlString.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}
