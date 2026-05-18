import Foundation

/// A recoverable contact list pulled from relay history (an overwritten or
/// tombstoned kind-3) that has substantially more follows than the version the
/// user just arrived with.
struct FollowRestoreCandidate: Equatable, Sendable, Identifiable {
    /// De-duplicated, order-preserving list of followed pubkeys.
    let pubkeys: [String]
    /// `created_at` of the kind-3 this came from — surfaced so the UI can say
    /// roughly how old the recovered list is.
    let createdAt: Int

    var count: Int { pubkeys.count }
    var id: Int { createdAt }
}

/// Detects the "my follow list got clobbered" failure mode that plagues Nostr:
/// a buggy or malicious client republishes a tiny (or empty) kind-3 that
/// overwrites the user's real contact list on most relays. When the user next
/// arrives in Wisp they'd otherwise silently inherit the wreckage.
///
/// The guard compares the freshly-fetched contact list against (a) the largest
/// count Wisp has ever seen for this account locally and (b) older / overwritten
/// / tombstoned kind-3 versions still served by other relays. If the current
/// list is a substantial drop from a recoverable one, the onboarding flow
/// offers to restore it.
///
/// Pure decision helpers are kept free of relay/IO so they can be unit-tested.
enum FollowHistoryGuard {

    // MARK: - Tunables

    /// Below this previous count we don't bother — for a user who follows a
    /// handful of people, normal churn looks like a "big" proportional drop and
    /// nagging them would be noise.
    static let minMeaningfulPreviousCount = 10

    /// The current list has to be under this fraction of the previous best to
    /// count as "substantially lower".
    static let substantialDropRatio = 0.5

    /// …and the absolute loss has to be at least this many follows. Stops a
    /// 12 → 5 wobble from triggering while still catching real wipes.
    static let minAbsoluteDrop = 5

    /// Broad net for recovering overwritten/tombstoned versions. Indexers tend
    /// to keep only the newest replaceable event, so we also sweep the wider
    /// onboarding/fallback pools where a stale-but-intact copy may still live.
    static var recoveryRelays: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for url in RelayDefaults.onboarding + RelayDefaults.fallbacks + RelayDefaults.indexers
        where seen.insert(url).inserted {
            ordered.append(url)
        }
        return ordered
    }

    // MARK: - Persistence keys

    private static func highWaterKey(_ pubkey: String) -> String {
        "follow_count_highwater_\(pubkey)"
    }

    /// The largest candidate count the user has explicitly declined to restore.
    /// Without this we'd re-offer the same recovered list on every single
    /// launch, since the corrupting kind-3 stays the newest one on relays.
    private static func declinedCountKey(_ pubkey: String) -> String {
        "follow_restore_declined_count_\(pubkey)"
    }

    /// UserDefaults keys this guard owns, so `NostrKey.deleteAccount` can purge
    /// them along with the rest of the account's local state.
    static func userDefaultsKeys(for pubkey: String) -> [String] {
        [highWaterKey(pubkey), declinedCountKey(pubkey)]
    }

    // MARK: - High-water mark

    static func recordedHighWater(for pubkey: String) -> Int {
        UserDefaults.standard.integer(forKey: highWaterKey(pubkey))
    }

    /// Monotonic: only ever raises the mark. Called on a healthy arrival so we
    /// remember how many follows the user genuinely had.
    static func recordHighWater(for pubkey: String, count: Int) {
        if count > recordedHighWater(for: pubkey) {
            UserDefaults.standard.set(count, forKey: highWaterKey(pubkey))
        }
    }

    /// Accept `count` as the new baseline even if it's lower. Used when the
    /// user deliberately keeps a smaller list (declines a restore) so that an
    /// intentional cull doesn't keep looking like a wipe.
    static func resetHighWater(for pubkey: String, to count: Int) {
        UserDefaults.standard.set(count, forKey: highWaterKey(pubkey))
    }

    private static func recordedDeclinedCount(for pubkey: String) -> Int {
        UserDefaults.standard.integer(forKey: declinedCountKey(pubkey))
    }

    /// Remember that the user passed on restoring a list of this size so we
    /// don't pester them again unless an even larger version turns up later.
    static func recordDeclined(for pubkey: String, candidateCount: Int) {
        if candidateCount > recordedDeclinedCount(for: pubkey) {
            UserDefaults.standard.set(candidateCount, forKey: declinedCountKey(pubkey))
        }
    }

    private static func clearDeclined(for pubkey: String) {
        UserDefaults.standard.removeObject(forKey: declinedCountKey(pubkey))
    }

    // MARK: - Pure decision helpers

    /// Extract the followed pubkeys from a kind-3, de-duplicated but keeping
    /// first-seen order (so a restored list reads the same as the original).
    static func followedPubkeys(in event: NostrEvent) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for tag in event.tags where tag.count >= 2 && tag[0] == "p" {
            let pk = tag[1]
            if !pk.isEmpty, seen.insert(pk).inserted { ordered.append(pk) }
        }
        return ordered
    }

    /// Is `current` a substantial drop from `previous`? Encodes the
    /// ratio + absolute-floor + minimum-meaningful-previous rules.
    ///
    /// A complete wipe (current = 0) surfaces whenever there's anything at
    /// all to recover. The thresholds in the other branch exist to avoid
    /// nagging on normal churn for small follow lists — but a full clobber
    /// to zero is never normal churn, and recovering even a single follow
    /// beats starting over. The deep relay sweep that produced `previous`
    /// has already filtered out the no-history case.
    static func isSubstantialDrop(current: Int, previous: Int) -> Bool {
        if current == 0 { return previous >= 1 }
        guard previous >= minMeaningfulPreviousCount else { return false }
        guard previous - current >= minAbsoluteDrop else { return false }
        return Double(current) < Double(previous) * substantialDropRatio
    }

    /// Pick the kind-3 with the most follows out of an already-fetched set
    /// (e.g. whatever the indexer query returned), if any beats `currentCount`.
    /// Cheap pre-check before paying for the broad recovery sweep.
    static func bestVersion(in events: [NostrEvent], beating currentCount: Int) -> FollowRestoreCandidate? {
        var best: FollowRestoreCandidate?
        for event in events where event.kind == 3 {
            let pks = followedPubkeys(in: event)
            if pks.count > currentCount, pks.count > (best?.count ?? currentCount) {
                best = FollowRestoreCandidate(pubkeys: pks, createdAt: event.createdAt)
            }
        }
        return best
    }

    // MARK: - Recovery (relay IO)

    /// Decide whether to offer a restore for `currentFollows`.
    ///
    /// `fetched` is whatever the caller already pulled (the onboarding indexer
    /// query) — used both as a cheap suspicion signal and as a candidate
    /// source. We cast the wide net for overwritten/tombstoned copies when the
    /// list looks clobbered *or* on the very first arrival for this account
    /// (no local history yet): that's precisely when the good list may survive
    /// only on a relay the indexers never saw, and it's a one-time cost. The
    /// substantial-drop guard below still keeps a healthy arrival silent.
    static func evaluateRestore(
        pubkey: String,
        currentFollows: [String],
        fetched: [NostrEvent]
    ) async -> FollowRestoreCandidate? {
        let currentCount = currentFollows.count
        let highWater = recordedHighWater(for: pubkey)
        let firstArrival = highWater == 0
        let cheapBest = bestVersion(in: fetched, beating: currentCount)

        // Always cast the wide net when the current list is empty. Indexers
        // typically only retain the newest replaceable event, so a clobber
        // event leaves the cheap fetch with nothing to suggest a drop; the
        // recoverable older versions live on whichever relays haven't yet
        // received the wipe. Without this we'd silently skip the sweep that
        // is the whole point of the feature.
        let emptyArrival = currentCount == 0

        let suspicious =
            firstArrival ||
            emptyArrival ||
            isSubstantialDrop(current: currentCount, previous: highWater) ||
            (cheapBest.map { isSubstantialDrop(current: currentCount, previous: $0.count) } ?? false)
        guard suspicious else { return nil }

        let deep = await findRecoverable(pubkey: pubkey)

        let candidate = [cheapBest, deep]
            .compactMap { $0 }
            .max(by: { $0.count < $1.count })

        guard let candidate,
              isSubstantialDrop(current: currentCount, previous: candidate.count) else {
            return nil
        }

        // Don't re-nag about a list the user already turned down, unless an
        // even bigger one has since surfaced.
        guard candidate.count > recordedDeclinedCount(for: pubkey) else { return nil }

        return candidate
    }

    /// Broad multi-relay sweep for every historical kind-3 the author ever
    /// published. Relays that never received (or didn't honor) the clobbering
    /// replacement still serve the intact list; `RelayPool.query` keeps every
    /// distinct version because it de-dupes by event id, not by replaceable key.
    static func findRecoverable(pubkey: String) async -> FollowRestoreCandidate? {
        let events = await RelayPool.query(
            relays: recoveryRelays,
            filter: NostrFilter(kinds: [3], authors: [pubkey]),
            timeout: 15,
            waitForAllRelays: true
        )
        var best: FollowRestoreCandidate?
        for event in events where event.kind == 3 {
            let pks = followedPubkeys(in: event)
            if pks.count > (best?.count ?? 0) {
                best = FollowRestoreCandidate(pubkeys: pks, createdAt: event.createdAt)
            }
        }
        return best
    }

    // MARK: - Outcome bookkeeping

    /// User accepted: the restored size is now the trusted baseline and any
    /// prior "declined" memory is moot.
    static func didRestore(pubkey: String, to count: Int) {
        resetHighWater(for: pubkey, to: count)
        clearDeclined(for: pubkey)
    }

    /// User kept the smaller list: treat it as intentional so we don't keep
    /// flagging the same drop, and remember the size they passed on.
    static func didDecline(pubkey: String, currentCount: Int, candidateCount: Int) {
        resetHighWater(for: pubkey, to: currentCount)
        recordDeclined(for: pubkey, candidateCount: candidateCount)
    }
}
