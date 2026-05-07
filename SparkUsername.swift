import Foundation
import Security

/// Generates random `{color}{animal}{number}` Lightning-address handles for
/// auto-provisioned Spark wallets during signup. Mirrors the Android
/// `OnboardingViewModel` companion lists so the handle space is identical
/// across platforms.
enum SparkUsername {
    static let colors = [
        "blue", "red", "green", "gold", "silver", "amber", "coral",
        "violet", "jade", "ruby", "teal", "cyan", "crimson", "ivory",
        "bronze", "copper", "indigo", "scarlet", "azure", "pearl",
        "onyx", "sage", "rose", "slate", "plum", "lime", "rust", "mint"
    ]

    static let animals = [
        "panda", "wolf", "fox", "falcon", "otter", "raven", "tiger",
        "eagle", "dolphin", "hawk", "lynx", "bear", "owl", "cobra",
        "bison", "crane", "gecko", "heron", "koala", "lemur",
        "moose", "newt", "ocelot", "puma", "quail", "robin",
        "shark", "swift", "viper", "wren", "yak", "zebra",
        "badger", "cougar", "drake", "finch", "gopher", "hound"
    ]

    static func generate() -> String {
        "\(pick(colors))\(pick(animals))\(secureNumberInRange(10, 100))"
    }

    private static func pick<T>(_ array: [T]) -> T {
        array[secureNumberInRange(0, array.count)]
    }

    /// Uniform random in `[lower, upper)` via `SecRandomCopyBytes`. Rejection
    /// sampling avoids the modulo bias you'd get from `raw % range` alone.
    private static func secureNumberInRange(_ lower: Int, _ upper: Int) -> Int {
        precondition(upper > lower)
        let range = UInt32(upper - lower)
        let limit = UInt32.max - (UInt32.max % range)
        var raw: UInt32 = 0
        repeat {
            var buf = [UInt8](repeating: 0, count: 4)
            _ = SecRandomCopyBytes(kSecRandomDefault, 4, &buf)
            raw = (UInt32(buf[0]) << 24) | (UInt32(buf[1]) << 16) | (UInt32(buf[2]) << 8) | UInt32(buf[3])
        } while raw >= limit
        return lower + Int(raw % range)
    }
}
