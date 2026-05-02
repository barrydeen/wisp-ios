import SwiftUI

/// The Social Graph screen. Drives the 5-phase compute and renders the visualization,
/// the ranked list, progress UI, and error states. Presented as a sheet from the
/// sidebar drawer ("Settings → Social Graph") and from the Extended Network feed's
/// empty-state CTA.
struct SocialGraphView: View {
    let keypair: Keypair
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: SocialGraphViewModel
    @State private var profiles: [String: ProfileData] = [:]
    @State private var selectedNode: GraphNode?
    @State private var selectedNodeFollowers: [String] = []
    @State private var profileFetchTask: Task<Void, Never>?
    @State private var navigateToPubkey: PubkeyRoute?

    init(keypair: Keypair) {
        self.keypair = keypair
        _viewModel = State(initialValue: SocialGraphViewModel(pubkey: keypair.pubkey))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.wispBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Social Graph")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.hasCache && !viewModel.isComputing {
                        Button {
                            viewModel.compute()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedNode) { node in
            SocialGraphNodeDetailSheet(
                node: node,
                activeUserPubkey: keypair.pubkey,
                profile: profiles[node.pubkey],
                profiles: profiles,
                followers: selectedNodeFollowers,
                onProfileTap: { pubkey in
                    selectedNode = nil
                    navigateToPubkey = PubkeyRoute(pubkey: pubkey)
                },
                onDismiss: { selectedNode = nil }
            )
        }
        .navigationDestination(item: $navigateToPubkey) { route in
            ProfileView(pubkey: route.pubkey, activeUserPubkey: keypair.pubkey)
        }
        .onChange(of: viewModel.cache?.computedAt) { _, _ in
            if let cache = viewModel.cache {
                refreshProfiles(for: cache)
            }
        }
        .onAppear {
            if let cache = viewModel.cache {
                refreshProfiles(for: cache)
            }
        }
        .onDisappear {
            profileFetchTask?.cancel()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            if viewModel.hasCache {
                cachedView
            } else {
                emptyHero
            }
        case .complete:
            cachedView
        case .failed(let reason):
            failedView(reason: reason)
        case .fetchingFollowLists(let f, let t):
            progressView(stepIndex: 0, label: "Fetching follow lists\u{2026}", determinate: (f, t))
        case .buildingGraph(let p, let t):
            progressView(stepIndex: 1, label: "Building graph\u{2026}", determinate: (p, t))
        case .computingNetwork(let u):
            progressView(stepIndex: 2, label: "\(formatCount(u)) unique users", determinate: nil)
        case .filtering(let q):
            progressView(stepIndex: 3, label: "\(q) qualified", determinate: nil)
        case .fetchingRelayLists(let f, let t):
            progressView(stepIndex: 4, label: "Fetching relay lists\u{2026}", determinate: (f, t))
        }
    }

    // MARK: - Idle (no cache)

    private var emptyHero: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 64))
                .foregroundStyle(Color.wispPrimary.opacity(0.7))
            VStack(spacing: 8) {
                Text("Discover your extended network")
                    .font(.title3.weight(.semibold))
                Text("We'll fetch your follows' contact lists, find accounts they all share, and pick the best relays to read posts from your wider circle.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button {
                viewModel.compute()
            } label: {
                Text("Compute Now")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.wispPrimary, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            Spacer()
        }
    }

    // MARK: - Idle / complete (with cache)

    @ViewBuilder
    private var cachedView: some View {
        if let cache = viewModel.cache {
            VStack(spacing: 0) {
                statsHeader(cache: cache)
                Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
                graphAndList(cache: cache)
            }
        } else {
            emptyHero
        }
    }

    private func statsHeader(cache: SocialGraphCache) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(formatCount(cache.stats.secondDegreeUnique)) unique \u{2022} \(formatCount(cache.stats.qualifiedCount)) qualified \u{2022} \(cache.stats.relayCount) relays")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let age = viewModel.cachedAgeDescription {
                    Text("Computed \(age)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func graphAndList(cache: SocialGraphCache) -> some View {
        let (firstNodes, secondNodes, strongest) = buildGraphInputs(cache: cache)
        return GeometryReader { geo in
            VStack(spacing: 0) {
                SocialGraphCanvas(
                    userPubkey: keypair.pubkey,
                    firstDegree: firstNodes,
                    secondDegree: secondNodes,
                    strongestConnector: strongest,
                    profiles: profiles,
                    onTapNode: { node in
                        showDetail(for: node)
                    }
                )
                .frame(height: geo.size.height * 0.55)

                Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))

                rankedList(cache: cache, secondNodes: secondNodes)
            }
        }
    }

    private func rankedList(cache: SocialGraphCache, secondNodes: [GraphNode]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(secondNodes.prefix(30), id: \.pubkey) { node in
                    Button {
                        showDetail(for: node)
                    } label: {
                        HStack(spacing: 12) {
                            CachedAvatarView(url: profiles[node.pubkey]?.picture, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profiles[node.pubkey]?.displayString ?? truncated(node.pubkey))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("\(node.followerCount) of your follows")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                }
            }
        }
    }

    // MARK: - Progress

    private func progressView(stepIndex: Int, label: String, determinate: (Int, Int)?) -> some View {
        VStack(spacing: 24) {
            Spacer()
            stepIndicator(current: stepIndex)
            Text(label)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let (value, total) = determinate, total > 0 {
                ProgressView(value: Double(value), total: Double(total))
                    .progressViewStyle(.linear)
                    .tint(Color.wispPrimary)
                    .frame(maxWidth: 240)
            } else {
                ProgressView()
                    .tint(Color.wispPrimary)
            }
            Spacer()
            Button {
                viewModel.cancel()
            } label: {
                Text("Cancel")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.primary)
            }
            .padding(.bottom, 32)
        }
    }

    private func stepIndicator(current: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(0..<5) { i in
                Circle()
                    .fill(i <= current ? Color.wispPrimary : Color.wispSurfaceVariant)
                    .frame(width: 10, height: 10)
            }
        }
    }

    // MARK: - Failed

    private func failedView(reason: DiscoveryState.Reason) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(failureTitle(reason))
                .font(.headline)
            Text(failureSubtitle(reason))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if case .emptyFollowList = reason {
                EmptyView()
            } else {
                Button {
                    viewModel.compute()
                } label: {
                    Text("Retry")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Color.wispPrimary, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
            }
            Spacer()
        }
    }

    private func failureTitle(_ reason: DiscoveryState.Reason) -> String {
        switch reason {
        case .emptyFollowList: return "No follows"
        case .cancelled: return "Cancelled"
        case .unknown: return "Couldn't compute"
        }
    }

    private func failureSubtitle(_ reason: DiscoveryState.Reason) -> String {
        switch reason {
        case .emptyFollowList: return "Follow some accounts first, then come back to compute your social graph."
        case .cancelled: return "Tap Retry to start again."
        case .unknown(let msg): return msg
        }
    }

    // MARK: - Helpers

    /// Build sorted node arrays + strongest-connector map from the cache. Selects top 15
    /// first-degree by `firstDegreeFollowerCount`, top 64 second-degree by
    /// `secondDegreeFollowerCount`. The strongest-connector map is computed lazily by
    /// looking up SQLite rows for second-degree pubkeys (only the ~64 we actually render).
    private func buildGraphInputs(cache: SocialGraphCache) -> (first: [GraphNode], second: [GraphNode], strongest: [String: String]) {
        let firstSorted = cache.firstDegreeFollowerCount.sorted { $0.value > $1.value }
        let firstNodes: [GraphNode] = firstSorted.prefix(SocialGraphRepository.Constants.topFirstDegreeForViz)
            .map { GraphNode(pubkey: $0.key, followerCount: $0.value) }
        let firstSet = Set(firstNodes.map(\.pubkey))

        let secondSorted = cache.secondDegreeFollowerCount.sorted { $0.value > $1.value }
        let secondNodes: [GraphNode] = secondSorted.prefix(SocialGraphRepository.Constants.topSecondDegreeForViz)
            .map { GraphNode(pubkey: $0.key, followerCount: $0.value) }

        var strongest: [String: String] = [:]
        if let db = try? SocialGraphDb(pubkey: keypair.pubkey) {
            for node in secondNodes {
                let followers = db.getFollowers(node.pubkey)
                let candidates = followers.filter { firstSet.contains($0) }
                if let pick = candidates.max(by: { lhs, rhs in
                    (cache.firstDegreeFollowerCount[lhs] ?? 0) < (cache.firstDegreeFollowerCount[rhs] ?? 0)
                }) {
                    strongest[node.pubkey] = pick
                } else if let any = followers.first {
                    strongest[node.pubkey] = any
                }
            }
        }
        return (firstNodes, secondNodes, strongest)
    }

    private func showDetail(for node: GraphNode) {
        let pubkey = keypair.pubkey
        let followers: [String] = {
            guard let db = try? SocialGraphDb(pubkey: pubkey) else { return [] }
            return db.getFollowers(node.pubkey)
        }()
        selectedNodeFollowers = followers
        selectedNode = node
        // Lazy-fetch profiles for any followers shown in the strip that we don't yet have.
        let needed = followers.prefix(30).filter { profiles[$0] == nil }
        if !needed.isEmpty {
            fetchProfiles(pubkeys: Array(needed))
        }
    }

    /// Batch-fetch profiles for nodes shown on the graph (and the active user).
    private func refreshProfiles(for cache: SocialGraphCache) {
        // Pre-populate from local cache.
        var topNodes = Set([keypair.pubkey])
        topNodes.formUnion(cache.firstDegreeFollowerCount.keys.prefix(SocialGraphRepository.Constants.topFirstDegreeForViz))
        topNodes.formUnion(cache.secondDegreeFollowerCount.keys.prefix(SocialGraphRepository.Constants.topSecondDegreeForViz + 30))
        let repo = ProfileRepository.shared
        var collected: [String: ProfileData] = [:]
        for pk in topNodes {
            if let p = repo.get(pk) { collected[pk] = p }
        }
        profiles = collected
        let missing = topNodes.filter { collected[$0] == nil }
        if !missing.isEmpty {
            fetchProfiles(pubkeys: Array(missing))
        }
    }

    private func fetchProfiles(pubkeys: [String]) {
        profileFetchTask?.cancel()
        profileFetchTask = Task {
            let indexers = RelayDefaults.indexers
            for batch in pubkeys.chunked(into: 150) {
                let events = await RelayPool.query(
                    relays: indexers,
                    filter: NostrFilter(kinds: [0], authors: batch),
                    timeout: 8
                )
                var bestByAuthor: [String: NostrEvent] = [:]
                for event in events where event.kind == 0 {
                    if let existing = bestByAuthor[event.pubkey], event.createdAt <= existing.createdAt { continue }
                    bestByAuthor[event.pubkey] = event
                }
                for (_, event) in bestByAuthor {
                    if let updated = ProfileRepository.shared.updateFromEvent(event) {
                        profiles[event.pubkey] = updated
                    }
                }
            }
        }
    }

    private func formatCount(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: String(format: "%.1fk", Double(n) / 1_000)
        default: "\(n)"
        }
    }

    private func truncated(_ pk: String) -> String {
        String(pk.prefix(8)) + "\u{2026}"
    }
}

extension GraphNode: Identifiable {
    var id: String { pubkey }
}

private struct PubkeyRoute: Identifiable, Hashable {
    let pubkey: String
    var id: String { pubkey }
}
