import Foundation
import Observation

/// Drives `ArticleView`: loads the kind-30023 article by its addressable
/// coordinate, extracts header metadata from tags, and maintains the threaded
/// comment list. Port of Android's `ArticleViewModel`, with the engagement
/// plumbing swapped for the iOS-idiomatic `EngagementRepository.markVisible`
/// (which batches + routes engagement queries internally).
@Observable
@MainActor
final class ArticleViewModel {
    private(set) var article: NostrEvent?
    private(set) var isLoading = true
    private(set) var title: String?
    /// NIP-23's optional `summary` tag. Already shown on the article cards in
    /// feeds; the reader itself never read it.
    private(set) var summary: String?
    private(set) var coverImage: String?
    private(set) var publishedAt: Int?
    private(set) var hashtags: [String] = []
    /// Markdown blocks parsed once per article — Android's `remember(article)`.
    private(set) var blocks: [MdBlock] = []
    /// Flattened NIP-10 reply tree: depth-first order with nesting depth,
    /// mirroring Android's `(event, depth)` pairs.
    private(set) var comments: [(event: NostrEvent, depth: Int)] = []
    private(set) var isCommentsLoading = false
    /// Profiles for the article author + comment authors, hydrated lazily.
    private(set) var profiles: [String: ProfileData] = [:]

    @ObservationIgnored private var commentEvents: [String: NostrEvent] = [:]
    @ObservationIgnored private var commentsStarted = false
    @ObservationIgnored private var subs: [RelaySubscription] = []
    @ObservationIgnored private var consumeTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    // MARK: - Article

    func loadArticle(author: String, dTag: String, relayHints: [String]) async {
        if let cached = ArticleCache.shared.cached(author: author, dTag: dTag) {
            parseAndEmit(cached)
        } else if let fetched = await ArticleCache.shared.fetch(
            author: author, dTag: dTag, relayHints: relayHints
        ) {
            parseAndEmit(fetched)
        } else {
            // One silent broader retry before giving up — mirrors the card's
            // auto-retry and Android's 8s polling window.
            if let retried = await ArticleCache.shared.refetch(
                author: author, dTag: dTag, relayHints: relayHints, attempt: 1
            ) {
                parseAndEmit(retried)
            } else {
                isLoading = false
            }
        }
        guard let loaded = article else { return }
        if profiles[author] == nil {
            let got = await ProfileRepository.shared.ensure([author])
            profiles.merge(got) { _, new in new }
        }
        // Mentions in the body are raw bech32 inside markdown, so nothing
        // else asks for these profiles — the renderer would fall back to a
        // short npub for every one of them.
        hydrateProfiles(for: MarkdownBlocks.profileMentions(in: loaded.content))
    }

    private func parseAndEmit(_ event: NostrEvent) {
        article = event
        title = firstTag(event, "title")
        summary = firstTag(event, "summary")
        coverImage = firstTag(event, "image")
        publishedAt = firstTag(event, "published_at").flatMap { Int($0) }
        hashtags = event.tags.filter { $0.count >= 2 && $0[0] == "t" }.map { $0[1] }
        blocks = MarkdownBlocks.parse(event.content)
        isLoading = false
        // Seed the action bar's like / repost / zap counts.
        EngagementRepository.shared.markVisible(eventId: event.id, author: event.pubkey)
    }

    private func firstTag(_ event: NostrEvent, _ name: String) -> String? {
        event.tags.first(where: { $0.count >= 2 && $0[0] == name })?[1]
    }

    // MARK: - Comments

    /// Subscribe for comments via the `a`-tag coordinate AND the
    /// article's event id — many clients reply with plain e-tags pointing at
    /// the article event rather than the NIP-23 coordinate. Mirrors Android's
    /// two-phase `loadComments`.
    func loadComments(author: String, dTag: String) {
        guard let articleEvent = article else { return }
        // Synchronous in-flight flag: `subs` is only populated after an await
        // inside the Task below, so guarding on `subs.isEmpty` alone leaves a
        // window where a second call would double-subscribe.
        guard !commentsStarted else { return }
        commentsStarted = true
        let coordinate = "30023:\(author):\(dTag)"
        isCommentsLoading = true

        Task { [weak self] in
            guard let self else { return }
            let relays = await self.commentRelays(author: author)
            guard !relays.isEmpty else {
                self.isCommentsLoading = false
                return
            }

            // NIP-22 requires replies to a long-form article to be kind
            // 1111, which is what other clients publish — and what Wisp
            // publishes itself. Subscribing to kind 1 alone showed an article
            // as having almost no comments while the web showed a full
            // thread.
            let commentKinds = [1, Nip22.kindComment]
            // Uppercase tags name the root scope, lowercase the immediate
            // parent, so `#A` returns the whole thread and `#a` only the
            // comments attached directly to the article. Both are asked for:
            // a reply to a comment carries the article in `A` but another
            // comment in `a`, so a lowercase-only filter loses every nested
            // reply.
            var aFilter = NostrFilter()
            aFilter.kinds = commentKinds
            aFilter.aTags = [coordinate]
            var rootAFilter = NostrFilter()
            rootAFilter.kinds = commentKinds
            rootAFilter.capitalATags = [coordinate]
            var eFilter = NostrFilter()
            eFilter.kinds = commentKinds
            eFilter.eTags = [articleEvent.id]
            var rootEFilter = NostrFilter()
            rootEFilter.kinds = commentKinds
            rootEFilter.capitalETags = [articleEvent.id]

            let suffix = String(articleEvent.id.prefix(8))
            let aSub = RelayPool.subscribe(relays: relays, filter: aFilter, id: "article-cmt-a-\(suffix)")
            let rootASub = RelayPool.subscribe(relays: relays, filter: rootAFilter, id: "article-cmt-ra-\(suffix)")
            let eSub = RelayPool.subscribe(relays: relays, filter: eFilter, id: "article-cmt-e-\(suffix)")
            let rootESub = RelayPool.subscribe(relays: relays, filter: rootEFilter, id: "article-cmt-re-\(suffix)")
            self.subs = [aSub, rootASub, eSub, rootESub]
            self.consume(aSub)
            self.consume(rootASub)
            self.consume(eSub)
            self.consume(rootESub)

            // No per-sub EOSE plumbing on the persistent pool — a fixed
            // settle window stands in for Android's awaitEoseWithTimeout(5s).
            self.settleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.isCommentsLoading = false
            }
        }
    }

    /// Author's NIP-65 read relays + the user's top scored relays, with the
    /// global fallbacks when both come back empty. Capped at 12.
    private func commentRelays(author: String) async -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func append(_ url: String) {
            guard let canon = RelayUrlValidator.canonicalize(url) else { return }
            if seen.insert(canon).inserted { out.append(canon) }
        }
        for url in await RelayListRepository.shared.getReadRelays(author) { append(url) }
        if let me = NostrKey.load()?.pubkey, let board = RelayScoreBoard.load(pubkey: me) {
            for entry in board.scoredRelays.prefix(6) { append(entry.url) }
        }
        if out.isEmpty {
            for url in RelayDefaults.fallbacks { append(url) }
        }
        return Array(out.prefix(12))
    }

    private func consume(_ sub: RelaySubscription) {
        let task = Task { [weak self] in
            for await (event, _) in sub.events {
                guard let self, !Task.isCancelled else { return }
                self.ingest(event)
            }
        }
        consumeTasks.append(task)
    }

    private func ingest(_ event: NostrEvent) {
        guard event.kind == 1 || event.kind == Nip22.kindComment else { return }
        guard commentEvents[event.id] == nil else { return }
        // The e-tag sub also matches the article author's own quote-posts and
        // unrelated references; both are still "comments" in the Android port.
        // Safety filters do apply — blocked / WoT-hidden authors never render.
        guard !SafetyFilter.shared.shouldDrop(event: event, context: .feed) else { return }
        commentEvents[event.id] = event
        Task { await EventStore.shared.persist([event]) }
        // Engagement counts for the comment row's action bar.
        EngagementRepository.shared.markVisible(eventId: event.id, author: event.pubkey)
        scheduleRebuild()
    }

    /// Debounced tree rebuild — comments arrive in bursts after REQ.
    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.rebuildTree()
        }
    }

    /// Port of Android's `rebuildTree` + `dfs`: NIP-10 reply targets that
    /// point at another comment nest under it; everything else (including
    /// replies directly to the article) sits at the root level. Children are
    /// ordered oldest-first, the flattened result is depth-first.
    private func rebuildTree() {
        let articleId = article?.id
        var parentToChildren: [String: [NostrEvent]] = [:]

        for event in commentEvents.values {
            let replyTarget = Nip10.replyTarget(of: event)
            let parentId: String
            if let replyTarget, commentEvents[replyTarget] != nil, replyTarget != articleId {
                parentId = replyTarget
            } else {
                parentId = "root"
            }
            parentToChildren[parentId, default: []].append(event)
        }

        for key in parentToChildren.keys {
            parentToChildren[key]?.sort { $0.createdAt < $1.createdAt }
        }

        var result: [(event: NostrEvent, depth: Int)] = []
        var visited = Set<String>()

        func dfs(_ parentId: String, _ depth: Int) {
            for child in parentToChildren[parentId] ?? [] {
                guard visited.insert(child.id).inserted else { continue }
                result.append((event: child, depth: depth))
                dfs(child.id, depth + 1)
            }
        }
        dfs("root", 0)

        // Cycle recovery: mutually-referencing reply targets (possible with
        // forged ids — inbound events aren't verified) put every node of the
        // cycle under another comment and none under "root", so the DFS above
        // never reaches them. Surface them at root level instead of silently
        // dropping them.
        if visited.count < commentEvents.count {
            let orphans = commentEvents.values
                .filter { !visited.contains($0.id) }
                .sorted { $0.createdAt < $1.createdAt }
            for orphan in orphans where visited.insert(orphan.id).inserted {
                result.append((event: orphan, depth: 0))
                dfs(orphan.id, 1)
            }
        }

        comments = result
        hydrateProfiles(for: result.map(\.event.pubkey))
    }

    private func hydrateProfiles(for pubkeys: [String]) {
        let missing = Array(Set(pubkeys.filter { profiles[$0] == nil }))
        guard !missing.isEmpty else { return }
        Task { [weak self] in
            let got = await ProfileRepository.shared.ensure(missing)
            guard let self, !got.isEmpty else { return }
            self.profiles.merge(got) { _, new in new }
        }
    }

    // MARK: - Teardown

    /// Close relay subscriptions and cancel in-flight work. Called from
    /// `ArticleView.onDisappear` — the Android `onCleared` equivalent.
    func cancel() {
        for sub in subs { sub.cancel() }
        subs.removeAll()
        for task in consumeTasks { task.cancel() }
        consumeTasks.removeAll()
        rebuildTask?.cancel()
        settleTask?.cancel()
        // Allow a fresh subscription if the view re-appears (push/pop).
        commentsStarted = false
    }
}
