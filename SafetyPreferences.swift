import Foundation
import Observation

/// How a muted / blocked author's post renders in places where dropping it
/// outright would break the surrounding structure — a thread's reply chain, or
/// a quoted note embedded in someone else's post.
///
/// The feed is unaffected: blocked authors never reach it at all, so there is
/// nothing there to place-hold.
enum MutedContentDisplay: String, CaseIterable, Sendable {
    /// Render nothing. The thread closes over the gap, so a reply to a muted
    /// author loses its visible context — the deliberate trade for never
    /// laying eyes on muted content. Replies still caption who they answer
    /// as "a muted user", so the conversation doesn't read as a non sequitur.
    case hidden
    /// A "Post from a muted user" row, with no way to see through it.
    case placeholder
    /// The same row plus a quiet reveal link, for reading or replying to one
    /// muted post without unmuting its author. The reveal is reversible and
    /// lasts only the visit — see `MutedRevealStore`.
    case placeholderWithReveal

    var label: String {
        switch self {
        case .hidden: return "Hide completely"
        case .placeholder: return "Show placeholder"
        case .placeholderWithReveal: return "Placeholder with reveal"
        }
    }

    var detail: String {
        switch self {
        case .hidden:
            return "Muted posts leave no trace. Replies to them are captioned \"Replying to a muted user\" so a thread still reads coherently."
        case .placeholder:
            return "A grey row marks where a muted post sits, keeping the reply chain intact. The content stays out of reach."
        case .placeholderWithReveal:
            return "Adds a Show link to the placeholder that reveals that one post, and a Hide link to put it back. Nothing is unmuted, and leaving the thread re-hides it."
        }
    }

    /// Whether a placeholder row renders at all.
    var showsPlaceholder: Bool { self != .hidden }
    /// Whether the placeholder offers a per-post reveal.
    var allowsReveal: Bool { self == .placeholderWithReveal }
}

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

    /// Defaults to `.placeholder` — the behavior that shipped before this was
    /// configurable, so an upgrade changes nothing until the user asks it to.
    var mutedContentDisplay: MutedContentDisplay = .placeholder {
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
        mutedContentDisplay = (defaults.string(forKey: mutedDisplayKey(pk))
            .flatMap(MutedContentDisplay.init(rawValue:))) ?? .placeholder
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
        mutedContentDisplay = .placeholder
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
    static func mutedDisplayKey(_ pubkey: String) -> String { "muted_content_display_\(pubkey)" }

    private func spamKey(_ pubkey: String) -> String { Self.spamKey(pubkey) }
    private func wotKey(_ pubkey: String) -> String { Self.wotKey(pubkey) }
    private func hellthreadKey(_ pubkey: String) -> String { Self.hellthreadKey(pubkey) }
    private func hellthreadThresholdKey(_ pubkey: String) -> String { Self.hellthreadThresholdKey(pubkey) }
    private func safelistKey(_ pubkey: String) -> String { Self.safelistKey(pubkey) }
    private func mutedDisplayKey(_ pubkey: String) -> String { Self.mutedDisplayKey(pubkey) }

    private func persist() {
        if binding { return }
        guard let pk = activePubkey else { return }
        let d = UserDefaults.standard
        d.set(spamFilterEnabled, forKey: spamKey(pk))
        d.set(wotFilterEnabled, forKey: wotKey(pk))
        d.set(hellthreadFilterEnabled, forKey: hellthreadKey(pk))
        d.set(hellthreadThreshold, forKey: hellthreadThresholdKey(pk))
        d.set(Array(spamSafelist), forKey: safelistKey(pk))
        d.set(mutedContentDisplay.rawValue, forKey: mutedDisplayKey(pk))
        Task { await SafetyFilter.shared.rebuildSnapshot() }
    }
}
