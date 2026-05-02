import Foundation
import ObjectBox

nonisolated enum ObjectBoxSetup {
    private(set) static var store: Store!

    static func setUp() throws {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = appSupport.appendingPathComponent("wisp")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try Store(directoryPath: dir.appendingPathComponent("objectbox").path)
    }
}
