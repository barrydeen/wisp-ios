import Foundation
import Observation

/// Per-account toggles for the spam and Web-of-Trust filters, plus the safelist of authors
/// the user has explicitly marked "not spam". Mirrors Android's `SafetyPreferences`.
///
/// Defaults: spam ON, WoT OFF (matches Android, so the spam classifier hides obvious junk
/// out of the box but WoT stays cold until the user opts in and a network has been computed).
@Observable
@MainActor
final class SafetyPreferences {
    static let shared = SafetyPreferences()

    private(set) var activePubkey: String?

    var spamFilterEnabled: Bool = true {
        didSet { persist() }
    }

    var wotFilterEnabled: Bool = false {
        didSet { persist() }
    }

    var hellthreadFilterEnabled: Bool = false {
        didSet { persist() }
    }

    var hellthreadThreshold: Int = NostrEvent.hellthreadThreshold {
        didSet { persist() }
    }

    var spamSafelist: Set<String> = [] {
        didSet { persist() }
    }

    @ObservationIgnored private var binding = false

    private init() {}

    func bind(activePubkey pk: String) {
        binding = true
        defer { binding = false }
        self.activePubkey = pk
        let defaults = UserDefaults.standard
        spamFilterEnabled = defaults.object(forKey: spamKey(pk)) as? Bool ?? true
        wotFilterEnabled = defaults.bool(forKey: wotKey(pk))
        hellthreadFilterEnabled = defaults.object(forKey: hellthreadKey(pk)) as? Bool ?? false
        hellthreadThreshold = defaults.object(forKey: hellthreadThresholdKey(pk)) as? Int ?? NostrEvent.hellthreadThreshold
        spamSafelist = Set(defaults.stringArray(forKey: safelistKey(pk)) ?? [])
    }

    func unbind() {
        binding = true
        defer { binding = false }
        activePubkey = nil
        spamFilterEnabled = true
        wotFilterEnabled = false
        hellthreadFilterEnabled = false
        hellthreadThreshold = NostrEvent.hellthreadThreshold
        spamSafelist = []
    }

    func addToSafelist(_ pubkey: String) {
        spamSafelist.insert(pubkey)
    }

    func removeFromSafelist(_ pubkey: String) {
        spamSafelist.remove(pubkey)
    }

    func isSafelisted(_ pubkey: String) -> Bool {
        spamSafelist.contains(pubkey)
    }

    static func spamKey(_ pubkey: String) -> String { "spam_filter_enabled_\(pubkey)" }
    static func wotKey(_ pubkey: String) -> String { "wot_filter_enabled_\(pubkey)" }
    static func hellthreadKey(_ pubkey: String) -> String { "hellthread_filter_enabled_\(pubkey)" }
    static func hellthreadThresholdKey(_ pubkey: String) -> String { "hellthread_threshold_\(pubkey)" }
    static func safelistKey(_ pubkey: String) -> String { "spam_safelist_\(pubkey)" }

    private func spamKey(_ pubkey: String) -> String { Self.spamKey(pubkey) }
    private func wotKey(_ pubkey: String) -> String { Self.wotKey(pubkey) }
    private func hellthreadKey(_ pubkey: String) -> String { Self.hellthreadKey(pubkey) }
    private func hellthreadThresholdKey(_ pubkey: String) -> String { Self.hellthreadThresholdKey(pubkey) }
    private func safelistKey(_ pubkey: String) -> String { Self.safelistKey(pubkey) }

    private func persist() {
        if binding { return }
        guard let pk = activePubkey else { return }
        let d = UserDefaults.standard
        d.set(spamFilterEnabled, forKey: spamKey(pk))
        d.set(wotFilterEnabled, forKey: wotKey(pk))
        d.set(hellthreadFilterEnabled, forKey: hellthreadKey(pk))
        d.set(hellthreadThreshold, forKey: hellthreadThresholdKey(pk))
        d.set(Array(spamSafelist), forKey: safelistKey(pk))
        Task { await SafetyFilter.shared.rebuildSnapshot() }
    }
}
