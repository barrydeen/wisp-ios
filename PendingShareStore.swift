import Foundation

/// File hand-off between the Share Extension and the main app, via an App
/// Group container. The extension stages shared media here and hands off
/// with a `wisp://share` open-URL call; the main app claims the files into
/// its own tmp directory as soon as it receives that URL. Compiled into both
/// the `wisp` and `ShareExtension` targets.
enum PendingShareStore {
    static let appGroupIdentifier = "group.barrydeen.wisp"
    private static let subdirectoryName = "PendingShare"

    private static var containerDirectory: URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }
        let dir = base.appendingPathComponent(subdirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies a shared item's bytes into the App Group container. Preserves
    /// the source's file extension (falling back to `preferredExtension`
    /// when the system-provided temp URL doesn't have one) so the receiving
    /// side can infer a UTType from `NSItemProvider(contentsOf:)`.
    @discardableResult
    static func stage(fileAt sourceURL: URL, preferredExtension: String? = nil) -> Bool {
        guard let dir = containerDirectory else { return false }
        let ext = !sourceURL.pathExtension.isEmpty ? sourceURL.pathExtension : (preferredExtension ?? "")
        let name = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        let dest = dir.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
            return true
        } catch {
            return false
        }
    }

    /// Marker extension for a staged plain-text/URL share, as opposed to a
    /// staged media file — lets `consumePendingFiles`'s caller tell the two
    /// apart without a second directory or notification payload.
    static let textFileExtension = "sharetext"

    /// Writes shared text (or a shared URL's absolute string) into the App
    /// Group container as a `.sharetext` file, using the same staging
    /// directory as `stage(fileAt:)`.
    @discardableResult
    static func stageText(_ text: String) -> Bool {
        guard let dir = containerDirectory else { return false }
        let dest = dir.appendingPathComponent(UUID().uuidString + ".\(textFileExtension)")
        do {
            try text.write(to: dest, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Copies every staged file into the app's own tmp directory and clears
    /// the App Group container, so a later share can't re-deliver stale
    /// files. Done synchronously and eagerly (rather than deleting lazily
    /// after the caller finishes reading) because `NSItemProvider(contentsOf:)`
    /// reads its URL on demand — the App Group copy has to already be
    /// claimed before the extension (or a retry) could touch it again.
    static func consumePendingFiles() -> [URL] {
        guard let dir = containerDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        var claimed: [URL] = []
        for name in names {
            let source = dir.appendingPathComponent(name)
            let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: source, to: dest)) != nil {
                claimed.append(dest)
            }
            try? FileManager.default.removeItem(at: source)
        }
        return claimed
    }
}
