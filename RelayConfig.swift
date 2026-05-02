import Foundation

nonisolated struct GeneralRelay: Codable, Equatable {
    var url: String
    var read: Bool
    var write: Bool
    var auth: Bool

    init(url: String, read: Bool = true, write: Bool = true, auth: Bool = false) {
        self.url = url
        self.read = read
        self.write = write
        self.auth = auth
    }
}
