import Foundation

/// Sidecar-style kind label for the details drawer: "KIND 1111 · COMMENT".
/// The number is always shown; known kinds get a human word after the
/// separator, unknown kinds degrade to just the number.
nonisolated enum EventKindLabel {
    static func label(for kind: Int) -> String {
        let name: String?
        switch kind {
        case 0: name = "PROFILE"
        case 1: name = "NOTE"
        case 3: name = "FOLLOWS"
        case 4: name = "DM"
        case 5: name = "DELETION"
        case 6: name = "REPOST"
        case 7: name = "REACTION"
        case 20: name = "PICTURE"
        case 21, 22: name = "VIDEO"
        case 1059: name = "GIFT WRAP"
        case 1068: name = "POLL"
        case 1111: name = "COMMENT"
        case 6969: name = "ZAP POLL"
        case 30023: name = "ARTICLE"
        case 30078: name = "APP DATA"
        default: name = nil
        }
        if let name {
            return "KIND \(kind) · \(name)"
        }
        return "KIND \(kind)"
    }
}
