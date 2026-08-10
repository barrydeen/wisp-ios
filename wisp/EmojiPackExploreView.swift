import SwiftUI

/// Streams kind-30030 emoji sets off the indexer relays so packs can be found
/// by scrolling rather than by knowing a coordinate ahead of time.
///
/// Dedupes to one entry per `30030:<pubkey>:<d>` address (keeping the newest
/// revision), drops packs with no usable emoji tags, and applies the same
/// safety filter the feeds use. Pagination walks backwards with `until`.
@Observable
@MainActor
final class EmojiPackExploreModel {
    private(set) var packs: [ResolvedEmojiPack] = []
    private(set) var loading = false
    private(set) var reachedEnd = false
    private(set) var failed = false

    /// Newest-first, so `until` on the next page is the oldest we've seen.
    private var oldestSeen: Int?
    private var seenAddresses = Set<String>()
    private var relays: [String] = []

    private static let pageSize = 60
    /// Cap on consecutive all-duplicate/all-filtered pages before we give up
    /// walking backwards, so a pathological relay can't spin the loop forever.
    private static let maxEmptyRounds = 3

    func start(pubkey: String) async {
        guard packs.isEmpty, !loading else { return }
        relays = Self.discoveryRelays(for: pubkey)
        await loadPage()
    }

    func loadMore() async {
        guard !loading, !reachedEnd, !packs.isEmpty else { return }
        await loadPage()
    }

    func retry(pubkey: String) async {
        guard !loading else { return }
        failed = false
        reachedEnd = false
        if relays.isEmpty { relays = Self.discoveryRelays(for: pubkey) }
        await loadPage()
    }

    private func loadPage() async {
        loading = true
        defer { loading = false }

        // Keep pulling pages until at least one new pack lands. Without this a
        // page that is entirely duplicates (packs are replaceable — relays
        // happily return several revisions of the same `d` tag) or entirely
        // filtered would append nothing, so no new row would appear, so the
        // tail `onAppear` that drives pagination would never fire again and
        // the feed would dead-end mid-scroll.
        var emptyRounds = 0
        while emptyRounds < Self.maxEmptyRounds && !reachedEnd {
            var filter = NostrFilter(kinds: [30030], limit: Self.pageSize)
            if let oldestSeen { filter.until = oldestSeen - 1 }

            let events = await RelayPool.query(relays: relays, filter: filter, timeout: 8)
            if Task.isCancelled { return }

            guard !events.isEmpty else {
                // Nothing at all on the very first page means we couldn't
                // reach anyone (or there is genuinely nothing) — surface a
                // retry rather than an empty state that looks like a working
                // feed.
                if packs.isEmpty { failed = true } else { reachedEnd = true }
                return
            }

            var added: [ResolvedEmojiPack] = []
            for ev in events.sorted(by: { $0.createdAt > $1.createdAt }) {
                oldestSeen = min(oldestSeen ?? ev.createdAt, ev.createdAt)
                guard !SafetyFilter.shared.shouldDrop(event: ev, context: .feed) else { continue }
                guard let pack = EmojiRepository.parsePack(ev), !pack.emojis.isEmpty else { continue }
                guard seenAddresses.insert(pack.address).inserted else { continue }
                added.append(pack)
            }

            // A short page means the relays have nothing older to give.
            if events.count < Self.pageSize { reachedEnd = true }

            if added.isEmpty {
                emptyRounds += 1
                continue
            }
            packs.append(contentsOf: added)
            return
        }
    }

    /// The user's own best-scoring relays first — packs their circle publishes
    /// are more relevant than whatever the indexers surface — then the built-in
    /// indexers as breadth.
    private static func discoveryRelays(for pubkey: String) -> [String] {
        var out: [String] = []
        if let board = RelayScoreBoard.load(pubkey: pubkey) {
            out.append(contentsOf: board.scoredRelays.prefix(4).map { $0.url })
        }
        for r in RelayDefaults.indexers where !out.contains(r) {
            out.append(r)
        }
        return out
    }
}

/// The "Explore" tab of Custom Emoji settings: a scrollable list of
/// `EmojiPackCardView`s, each with its own Add / Added toggle.
struct EmojiPackExploreView: View {
    let pubkey: String

    @Environment(\.theme) private var theme
    @State private var model = EmojiPackExploreModel()

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if model.failed && model.packs.isEmpty {
                errorState
            } else if model.packs.isEmpty && !model.loading {
                Text("No emoji packs found on your relays yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.onSurfaceVariant)
                    .padding(.vertical, 24)
            } else {
                ForEach(model.packs, id: \.address) { pack in
                    EmojiPackCardView(pack: pack)
                        .onAppear {
                            // Prefetch the next page as the tail comes into view.
                            if pack.address == model.packs.last?.address {
                                Task { await model.loadMore() }
                            }
                        }
                }
            }
            if model.loading {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding(.vertical, 16)
                    Spacer()
                }
            } else if model.reachedEnd && !model.packs.isEmpty {
                HStack {
                    Spacer()
                    Text("That's every pack we could find.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.onSurfaceVariant)
                        .padding(.vertical, 16)
                    Spacer()
                }
            }
        }
        .task { await model.start(pubkey: pubkey) }
    }

    private var errorState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Couldn't reach your relays.")
                .font(.system(size: 14, weight: .semibold))
            Button("Try again") {
                Task { await model.retry(pubkey: pubkey) }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.primary)
            .buttonStyle(.plain)
        }
        .padding(.vertical, 24)
    }
}
