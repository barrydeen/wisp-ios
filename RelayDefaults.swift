import Foundation

/// Canonical relay lists referenced from many places in the app.
///
/// Before this existed the same 4-indexer literal appeared in 20+ files (every
/// repository, every feed view model, every list-editor view), so adding or
/// rotating an indexer required a sweeping find-replace and routinely missed
/// one or two sites. Keep additions here; let call sites read from the enum.
enum RelayDefaults {
    /// Indexer-grade relays used to discover kind-0 / kind-3 / kind-10002
    /// events when we don't yet know an author's outbox. Treat as a discovery
    /// pool — feed/notification queries should route through the user's
    /// scoreboard, not these.
    nonisolated static let indexers: [String] = [
        "wss://indexer.nostrarchives.com",
        "wss://indexer.coracle.social",
        "wss://relay.damus.io",
        "wss://relay.primal.net"
    ]

    /// Generic fallback relays for paths where we have no scoreboard hint and
    /// the indexer set isn't appropriate (e.g. notifications, mutes, extended
    /// network bootstrap).
    nonisolated static let fallbacks: [String] = [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://relay.nostr.band"
    ]

    /// Bootstrap relay set used at first-launch / sign-up — wider than `indexers`
    /// because new users have no scoreboard yet, so we cast a slightly broader
    /// net to find their kind-0 / kind-3 / kind-10002 events.
    nonisolated static let onboarding: [String] = [
        "wss://indexer.coracle.social",
        "wss://relay.nos.social",
        "wss://nos.lol",
        "wss://indexer.nostrarchives.com",
        "wss://relay.damus.io",
        "wss://relay.primal.net"
    ]
}
