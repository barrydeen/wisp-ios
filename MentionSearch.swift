import Foundation

struct MentionCandidate: Identifiable, Hashable {
    let pubkey: String
    let name: String
    let nip05: String?
    let picture: String?
    let isFollowing: Bool

    var id: String { pubkey }
}

@MainActor
enum MentionSearch {
    static let maxResults = 5

    /// Search the user's follows (and any cached profiles, as a fallback) for mention candidates.
    /// `query` should be the substring after `@`. Empty query returns the first 5 follows
    /// in their stored order, mirroring the Android composer's "default top contacts" suggestion.
    static func search(query: String, currentUserPubkey: String) -> [MentionCandidate] {
        let q = query.lowercased()
        let follows = FollowsCache.shared.follows(for: currentUserPubkey)
        let followSet = Set(follows)
        let repo = ProfileRepository.shared
        let profiles = repo.getAll(follows)

        // Always include self so the user can tag their own account.
        // Use name-match score when the profile is cached; fall back to a
        // floor of 1 so self still appears at the end of the list even
        // before the kind-0 has loaded (shortNpub would score 0 otherwise).
        let selfProfile = repo.get(currentUserPubkey)
        let selfName = selfProfile?.displayName?.nilIfEmpty
            ?? selfProfile?.name?.nilIfEmpty
            ?? Nip19.shortNpub(hex: currentUserPubkey)
        let selfRawScore = matchScore(query: q, name: selfName, secondary: selfProfile?.name, nip05: selfProfile?.nip05)
        let selfScore = q.isEmpty ? 0 : max(1, selfRawScore)
        var candidates: [(MentionCandidate, Int)] = [(
            MentionCandidate(
                pubkey: currentUserPubkey,
                name: selfName,
                nip05: selfProfile?.nip05,
                picture: selfProfile?.picture,
                isFollowing: false
            ),
            selfScore
        )]

        for pk in follows where pk != currentUserPubkey {
            let p = profiles[pk]
            let name = p?.displayName?.nilIfEmpty
                ?? p?.name?.nilIfEmpty
                ?? Nip19.shortNpub(hex: pk)
            let score = matchScore(query: q, name: name, secondary: p?.name, nip05: p?.nip05)
            if q.isEmpty || score > 0 {
                let cand = MentionCandidate(
                    pubkey: pk,
                    name: name,
                    nip05: p?.nip05,
                    picture: p?.picture,
                    isFollowing: true
                )
                candidates.append((cand, score))
            }
            if candidates.count >= maxResults * 4 { break }
        }
        candidates.sort { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }
        // Always guarantee self appears. Take the normal prefix first; if self
        // was outscored by maxResults follows, append self so the signed-in
        // user is always reachable without scrolling through all their contacts.
        var out = Array(candidates.prefix(maxResults).map(\.0))
        if !out.contains(where: { $0.pubkey == currentUserPubkey }),
           let selfEntry = candidates.first(where: { $0.0.pubkey == currentUserPubkey })?.0 {
            out.append(selfEntry)
        }
        _ = followSet
        return out
    }

    /// Relay-backed fallback for users the local follow search can't satisfy —
    /// e.g. an account the composer's author doesn't follow yet, or a follow
    /// whose kind-0 hasn't been cached. Runs a NIP-50 kind-0 search and ranks
    /// hits with the same scoring as the local path. Pubkeys already shown by
    /// the local pass are skipped so the popup never lists a person twice.
    static func searchRemote(
        query: String,
        currentUserPubkey: String,
        excluding existing: Set<String>
    ) async -> [MentionCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        // Query the NIP-50 search relay only — matches the global People
        // search. Adding the discovery indexers (damus / primal / coracle)
        // hurts here: they don't honor `search`, so they EOSE almost
        // instantly with zero results, which trips `RelayPool.query`'s
        // first-EOSE fast path and shortens the window before the actual
        // search relay has a chance to reply.
        //
        // `waitForAllRelays: true` skips the post-EOSE-then-stop fast path
        // — some NIP-50 relays send EOSE optimistically and stream the
        // matching kind-0 events afterwards, and we need the full window
        // for those rather than the 1.5 s grace.
        let relays = [SearchViewModel.defaultSearchRelay]
        let filter = NostrFilter(kinds: [0], limit: 20, search: trimmed)
        let events = await RelayPool.query(
            relays: relays,
            filter: filter,
            timeout: 6,
            waitForAllRelays: true
        )
        guard !events.isEmpty else { return [] }

        let q = trimmed.lowercased()
        let repo = ProfileRepository.shared
        let follows = FollowsCache.shared.followsSet(for: currentUserPubkey)
        // Normalize against the same canonical form `SearchViewModel`
        // uses so mixed-case hex / npub variants of the same identity
        // collapse to one row.
        var seen = Set<String>()
        var scored: [(MentionCandidate, Int)] = []
        for event in events where event.kind == 0 {
            let pk = canonicalPubkey(event.pubkey)
            if existing.contains(pk) || !seen.insert(pk).inserted { continue }
            let p = repo.updateFromEvent(event) ?? repo.get(pk)
            let name = p?.displayName?.nilIfEmpty
                ?? p?.name?.nilIfEmpty
                ?? Nip19.shortNpub(hex: pk)
            let score = matchScore(query: q, name: name, secondary: p?.name, nip05: p?.nip05)
            guard score > 0 else { continue }
            scored.append((
                MentionCandidate(
                    pubkey: pk,
                    name: name,
                    nip05: p?.nip05,
                    picture: p?.picture,
                    isFollowing: follows.contains(pk)
                ),
                score
            ))
        }
        scored.sort { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }
        return scored.prefix(maxResults).map(\.0)
    }

    /// Mirrors `SearchViewModel.canonicalPubkey`: collapse the different
    /// string forms the same identity can arrive in from a NIP-50 search
    /// relay — mixed-case or whitespace-padded hex, or an `npub` /
    /// `nprofile` in place of raw hex — down to one canonical
    /// lowercase-hex key so dedupe lands cleanly.
    private static func canonicalPubkey(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("npub1") || lower.hasPrefix("nprofile1"),
           case .profileRef(let hex, _)? = Nip19.decodeNostrUri(lower) {
            return hex
        }
        return lower
    }

    /// Higher score = better match. Empty query returns 0 (caller treats as "default suggestion").
    private static func matchScore(query: String, name: String, secondary: String?, nip05: String? = nil) -> Int {
        if query.isEmpty { return 0 }
        let n = name.lowercased()
        if n == query { return 100 }
        if n.hasPrefix(query) { return 80 }
        // Word-boundary match: query equals or prefixes a word in a multi-word
        // name, so "@daniel" scores "The Daniel" at 75 rather than a plain 50
        // contains, surfacing it above unrelated contains matches.
        let words = n.components(separatedBy: .whitespacesAndNewlines)
            + n.components(separatedBy: "\u{00A0}")
        if words.contains(query) { return 75 }
        if words.contains(where: { $0.hasPrefix(query) }) { return 65 }
        if n.contains(query) { return 50 }
        if let s = secondary?.lowercased() {
            if s == query { return 40 }
            if s.hasPrefix(query) { return 30 }
            if s.contains(query) { return 20 }
        }
        // NIP-05 match: strip the domain part so "daniel@nostrich.cc" matches
        // both "daniel" and "daniel@nostrich.cc" queries.
        if let id = nip05?.lowercased() {
            let local = id.components(separatedBy: "@").first ?? id
            if id == query || local == query { return 38 }
            if id.hasPrefix(query) || local.hasPrefix(query) { return 28 }
            if id.contains(query) || local.contains(query) { return 18 }
        }
        return 0
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
