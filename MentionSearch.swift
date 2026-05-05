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

        var candidates: [(MentionCandidate, Int)] = []
        for pk in follows {
            let p = profiles[pk]
            let name = p?.displayName?.nilIfEmpty
                ?? p?.name?.nilIfEmpty
                ?? Nip19.shortNpub(hex: pk)
            let score = matchScore(query: q, name: name, secondary: p?.name)
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
        let out = candidates.prefix(maxResults).map(\.0)
        _ = followSet
        return Array(out)
    }

    /// Higher score = better match. Empty query returns 0 (caller treats as "default suggestion").
    private static func matchScore(query: String, name: String, secondary: String?) -> Int {
        if query.isEmpty { return 0 }
        let n = name.lowercased()
        if n == query { return 100 }
        if n.hasPrefix(query) { return 80 }
        if n.contains(query) { return 50 }
        if let s = secondary?.lowercased() {
            if s == query { return 40 }
            if s.hasPrefix(query) { return 30 }
            if s.contains(query) { return 20 }
        }
        return 0
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
