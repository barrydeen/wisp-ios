import Foundation
import Observation
import os.log

private let signupLog = Logger(subsystem: "wisp", category: "signup-wallet")

/// Orchestrates the brand-new-user sign-up flow:
///
///   1. profile (avatar + bio) while RelayProber discovers good relays
///   2. follow some suggested accounts (creators / active now / news)
///   3. pick hashtags as an "Interests" set
///   4. compose an introduction note
///
/// Distinct from the returning-user `OnboardingViewModel`, which assumes the
/// account already exists and runs an outbox-builder over the user's kind-3.
/// Here we generate the keypair locally and seed every downstream relay-routing
/// path (RelayScoreBoard, kind-10002, kind-3) ourselves.
@Observable
@MainActor
final class SignUpViewModel {

    // MARK: - Sub-models

    enum RelayPhase: Equatable {
        case idle
        case connecting
        case discovering
        case selecting
        case testing
        case ready
        case failed

        var displayText: String {
            switch self {
            case .idle, .connecting: "Connecting to bootstrap relays\u{2026}"
            case .discovering:       "Discovering relays\u{2026}"
            case .selecting:         "Selecting the best relays\u{2026}"
            case .testing:           "Testing relays\u{2026}"
            case .ready:             "Ready"
            case .failed:            "Using default relays"
            }
        }
    }

    enum SuggestionSection: String, CaseIterable, Identifiable {
        case creators, activeNow, news
        var id: String { rawValue }
        var title: String {
            switch self {
            case .creators:  "Creators"
            case .activeNow: "Active right now"
            case .news:      "News"
            }
        }
    }

    struct Suggestions {
        var profiles: [ProfileData] = []
        var loading: Bool = true
    }

    // MARK: - Identity

    let keypair: Keypair

    // MARK: - Wallet state

    /// Lightning address registered for this account during signup, e.g.
    /// "bluepanda42@<spark-domain>". Embedded into kind-0 as `lud16` when set.
    var lightningAddress: String?

    @ObservationIgnored private var sparkWallet: SparkWallet?
    @ObservationIgnored private var sparkConnectTask: Task<Void, Never>?

    // MARK: - Profile step state

    var name: String = ""
    var about: String = ""
    var pictureUrl: String?
    var uploading: Bool = false
    var uploadError: String?

    var relayPhase: RelayPhase = .idle
    var probingUrl: String?
    var discoveredRelays: [GeneralRelay] = []
    var publishingProfile: Bool = false

    @ObservationIgnored private var outboxBuilderTask: Task<Void, Never>?

    // MARK: - Suggestions step state

    var creators: Suggestions = Suggestions()
    var activeNow: Suggestions = Suggestions()
    var news: Suggestions = Suggestions()
    var selectedFollows: Set<String> = []
    private var suggestionsLoaded = false

    // MARK: - Topics step state (was "hashtags")

    var selectedHashtags: Set<String> = []
    var topicQuery: String = "" {
        didSet { applyTopicQuery() }
    }
    var topicSuggestions: [String] = []
    var popularTopics: [String] = []
    var loadingPopular: Bool = true
    @ObservationIgnored private var allTopics: [String] = []
    @ObservationIgnored private var topicsLoaded = false

    // MARK: - Intro note state

    var introContent: String = "#introductions\n\n"
    var publishingIntro: Bool = false
    var postCountdown: Int? = nil
    @ObservationIgnored private var countdownTask: Task<Void, Never>?

    // MARK: - Constants

    private static let creatorPubkeys = [
        "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d",  // fiatjaf
        "e2ccf7cf20403f3f2a4a55b328f0de3be38558a7d5f33632fdaaefc726c1c8eb"   // utxo
    ]

    private static let activeRelays = [
        "wss://premium.primal.net",
        "wss://nostr.wine",
        "wss://relay.wisp.talk",
        "wss://pyramid.fiatjaf.com"
    ]

    private static let newsRelay = "wss://news.utxo.one"

    private static let topicsTrendingRelay = "wss://feeds.nostrarchives.com/hashtags/trending"
    private static let topicsAllRelay = "wss://feeds.nostrarchives.com/hashtags/all"

    private static let indexerRelays = RelayDefaults.onboarding

    /// Always-on relay published into every new user's kind-10002 (read+write)
    /// and kind-10050 list, regardless of RelayProber outcome.
    private static let wispOutboxRelay = "wss://relay.wisp.talk"
    private static let wispDmRelay = "wss://auth.nostr1.com"

    static let popularHashtags = [
        "nostr", "bitcoin", "lightning", "art", "photography",
        "music", "tech", "news", "podcasting", "gm",
        "introductions", "memes"
    ]

    // MARK: - Init

    /// Generate a fresh keypair. Must be side-effect free: SwiftUI evaluates
    /// the `@State` default value (`SignUpViewModel()` in `SignUpFlowView`)
    /// on every parent-body reconstruction and discards every result except
    /// the first. Persisting here would leak abandoned pubkeys into
    /// `wisp_accounts`, surfacing them as phantom accounts in the sidebar.
    /// Persistence happens once on view mount via `registerAccount()`.
    init() {
        let priv = Schnorr.randomPrivkey()
        let pub: Data
        do {
            pub = try Schnorr.xonlyPubkey(privkey32: priv)
        } catch {
            // Pure crypto path; failure here only happens on malformed entropy.
            // Fall back to a regenerated key so we never hand out an invalid pair.
            pub = (try? Schnorr.xonlyPubkey(privkey32: Schnorr.randomPrivkey())) ?? Data(count: 32)
        }
        self.keypair = Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    /// Persist the generated keypair to the Keychain and the multi-account
    /// list. Called from `SignUpFlowView.task`, which runs once per view
    /// identity — i.e. once per signup flow.
    func registerAccount() {
        NostrKey.save(self.keypair)
    }

    // MARK: - Step 1: profile + relay discovery

    func startRelayDiscovery() {
        guard relayPhase == .idle else { return }
        startWalletSetup()
        relayPhase = .connecting
        let kp = self.keypair
        Task { [weak self] in
            let relays = await RelayProber.discoverAndSelect(
                keypair: kp,
                onPhase: { phase in
                    Task { @MainActor in self?.applyProbePhase(phase) }
                },
                onProbing: { url in
                    Task { @MainActor in self?.probingUrl = url }
                }
            )
            await MainActor.run {
                guard let self else { return }
                let merged = Self.ensureWispOutbox(in: relays)
                self.discoveredRelays = merged
                self.probingUrl = nil
                if self.relayPhase != .failed { self.relayPhase = .ready }
                self.seedRelayScoreBoard(relays: merged)
            }
        }
    }

    /// Inject the wisp outbox relay into the discovered list (read+write) so
    /// it always lands in the published kind-10002, regardless of probing
    /// outcome. Idempotent: matches by normalised URL.
    private static func ensureWispOutbox(in relays: [GeneralRelay]) -> [GeneralRelay] {
        let target = Nip51Lists.normalize(wispOutboxRelay) ?? wispOutboxRelay
        if relays.contains(where: { (Nip51Lists.normalize($0.url) ?? $0.url) == target }) {
            return relays
        }
        return [GeneralRelay(url: wispOutboxRelay, read: true, write: true)] + relays
    }

    private func applyProbePhase(_ phase: RelayProber.Phase) {
        switch phase {
        case .connecting:  relayPhase = .connecting
        case .discovering: relayPhase = .discovering
        case .selecting:   relayPhase = .selecting
        case .testing:     relayPhase = .testing
        case .done:        relayPhase = .ready
        case .failed:      relayPhase = .failed
        }
    }

    /// Populate `RelayScoreBoard` so every downstream publish (kind-0, kind-3,
    /// kind-30015, kind-1) targets the discovered relays via the same
    /// `topWriteRelays` lookup the rest of the app uses.
    private func seedRelayScoreBoard(relays: [GeneralRelay]) {
        let urls = relays.filter(\.write).map(\.url)
        guard !urls.isEmpty else { return }
        let board = RelayScoreBoard()
        let writeMap: [String: [String]] = [keypair.pubkey: urls]
        board.build(follows: [keypair.pubkey], writeRelaysByAuthor: writeMap, redundancy: urls.count)
        board.save(pubkey: keypair.pubkey)
    }

    // MARK: - Wallet setup

    /// Generate a Bip39 mnemonic and start the Breez Spark connect in parallel
    /// with relay discovery, so by the time the user taps Continue on the
    /// profile step the SDK is usually already up. Silent on failure: a
    /// missing API key, bad entropy, or network error just leaves
    /// `sparkWallet?.isConnected == false` so `finishProfileStep` skips the
    /// lud16 path and publishes the profile bare.
    private func startWalletSetup() {
        guard sparkWallet == nil else { return }
        guard BreezConfig.hasApiKey else {
            signupLog.warning("Breez API key missing — skipping auto-wallet setup")
            return
        }
        let wallet = SparkWallet(pubkey: keypair.pubkey)
        do {
            let mnemonic = try Bip39.newMnemonic()
            wallet.saveMnemonic(mnemonic)
        } catch {
            signupLog.warning("Bip39.newMnemonic failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        sparkWallet = wallet
        sparkConnectTask = Task { await wallet.connect() }
    }

    /// Wait up to 15s for the Spark SDK to flip `isConnected = true`, then try
    /// up to 3 random `{color}{animal}{number}` handles via Breez. On success
    /// persists `WalletMode.spark` so MainView's WalletStore reconnects to the
    /// same on-disk wallet automatically. Returns nil on any failure.
    private func registerSparkLightningAddressIfReady() async -> String? {
        guard let wallet = sparkWallet else { return nil }

        let deadline = Date().addingTimeInterval(15)
        while !wallet.isConnected && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard wallet.isConnected else {
            signupLog.warning("Spark connect timed out — skipping lud16 setup")
            return nil
        }

        for attempt in 1...3 {
            let username = SparkUsername.generate()
            if await wallet.checkLightningAddressAvailable(username: username) {
                do {
                    let address = try await wallet.registerLightningAddress(username: username)
                    WalletMode.save(.spark, for: keypair.pubkey)
                    self.lightningAddress = address
                    return address
                } catch {
                    signupLog.warning("registerLightningAddress(\(username, privacy: .public)) failed (attempt \(attempt)): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        signupLog.warning("All 3 lightning-address handle attempts failed")
        return nil
    }

    /// Disconnect the signup-time SparkWallet so MainView's WalletStore can
    /// connect its own SparkWallet against the same on-disk Spark store.
    /// `SparkWallet.storageDir` is currently a single shared path, so two
    /// concurrent connects would conflict.
    func tearDownSignupWallet() {
        sparkConnectTask?.cancel()
        sparkConnectTask = nil
        sparkWallet?.disconnect()
        sparkWallet = nil
    }

    func uploadAvatar(data: Data, mime: String) async {
        uploading = true
        uploadError = nil
        defer { uploading = false }

        let servers = BlossomServerList.cached(for: keypair.pubkey)
        do {
            let result = try await BlossomClient.upload(
                bytes: data,
                mime: mime,
                servers: servers,
                keypair: keypair
            )
            self.pictureUrl = result.url
        } catch {
            self.uploadError = "Upload failed"
        }
    }

    /// Persist kind-10002 (relay list) and kind-0 (profile metadata) locally
    /// and seed the DM relay (kind-10050). The relay fan-out is fire-and-forget
    /// — we don't block the UI on a 6 s × N-relay timeout, matching the pattern
    /// used by `RelaySettingsRepository.publish` and `finishFollowsStep`.
    func finishProfileStep() async {
        guard !publishingProfile else { return }
        publishingProfile = true
        defer { publishingProfile = false }

        // Wait up to 15s for the Spark wallet started in `startWalletSetup`
        // to come up, then claim a random Lightning-address handle. Failure
        // returns nil and the kind-0 below ships without `lud16` — never
        // blocks the user from advancing.
        let lightning = await registerSparkLightningAddressIfReady()

        let writeRelays = discoveredRelays.filter(\.write).map(\.url)
        let publishTargets = (writeRelays + Self.indexerRelays).uniquedPreservingOrder()

        let relayListEvent = signRelayListEvent()
        let profileEvent = signProfileEvent(lightningAddress: lightning)

        if let e = relayListEvent {
            await EventStore.shared.persist([e])
            RelayListRepository.shared.ingest(e)
        }
        if let e = profileEvent {
            await EventStore.shared.persist([e])
            ProfileRepository.shared.updateFromEvent(e)
        }

        // Seed the DM relay so kind-10050 is published with auth.nostr1.com.
        // `addDmRelay` already fires the publish via Task.detached internally.
        RelaySettingsRepository.shared.ensureLoaded(pubkey: keypair.pubkey)
        RelaySettingsRepository.shared.addDmRelay(Self.wispDmRelay, keypair: keypair)

        // Background fan-out for kind-10002 and kind-0. Local state is already
        // durable above, so the UI can advance immediately.
        Task.detached { [relayListEvent, profileEvent, publishTargets] in
            if let e = relayListEvent {
                _ = await RelayPool.publish(event: e, to: publishTargets, timeout: 6)
            }
            if let e = profileEvent {
                _ = await RelayPool.publish(event: e, to: publishTargets, timeout: 6)
            }
        }

        // NIP-78 encrypted seed backup: fire-and-forget to write relays only,
        // matching Android's `relayPool.sendToWriteRelays(backupMsg)` semantics.
        if lightning != nil, let mnemonic = sparkWallet?.loadMnemonic(), !writeRelays.isEmpty {
            let kp = self.keypair
            Task.detached { [mnemonic, writeRelays] in
                do {
                    let event = try await Nip78Backup.createBackupEvent(keypair: kp, mnemonic: mnemonic)
                    _ = await RelayPool.publish(event: event, to: writeRelays, timeout: 6)
                } catch {
                    signupLog.warning("NIP-78 backup publish failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func signRelayListEvent() -> NostrEvent? {
        guard let privkey = Hex.decode(keypair.privkey) else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        let tags = Nip51Lists.buildGeneralRelayTags(discoveredRelays)
        return try? NostrEvent.sign(
            privkey32: privkey,
            pubkey: keypair.pubkey,
            kind: 10002,
            createdAt: now,
            tags: tags,
            content: ""
        )
    }

    private func signProfileEvent(lightningAddress: String? = nil) -> NostrEvent? {
        guard let privkey = Hex.decode(keypair.privkey) else { return nil }
        var json: [String: String] = [:]
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedAbout = about.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            json["name"] = trimmedName
            json["display_name"] = trimmedName
        }
        if !trimmedAbout.isEmpty { json["about"] = trimmedAbout }
        if let pic = pictureUrl, !pic.isEmpty { json["picture"] = pic }
        if let lud16 = lightningAddress, !lud16.isEmpty { json["lud16"] = lud16 }
        guard !json.isEmpty,
              let body = try? JSONSerialization.data(withJSONObject: json),
              let bodyStr = String(data: body, encoding: .utf8) else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        return try? NostrEvent.sign(
            privkey32: privkey,
            pubkey: keypair.pubkey,
            kind: 0,
            createdAt: now,
            tags: [],
            content: bodyStr
        )
    }

    // MARK: - Step 2: suggestions

    func loadSuggestions() {
        guard !suggestionsLoaded else { return }
        suggestionsLoaded = true
        Task { await loadCreators() }
        Task { await loadActiveNow() }
        Task { await loadNews() }
    }

    private func loadCreators() async {
        let events = await RelayPool.query(
            relays: Self.activeRelays,
            filter: NostrFilter(kinds: [0], authors: Self.creatorPubkeys),
            timeout: 8
        )
        let profiles = latestKind0Profiles(events)
        creators = Suggestions(profiles: profiles, loading: false)
    }

    private func loadActiveNow() async {
        let since = Int(Date().timeIntervalSince1970) - 20 * 60
        let events = await RelayPool.query(
            relays: Self.activeRelays,
            filter: NostrFilter(kinds: [1], limit: 200, since: since),
            timeout: 8
        )
        let unique = Array(Set(events.map(\.pubkey))).shuffled().prefix(20).map { $0 }
        guard !unique.isEmpty else {
            activeNow = Suggestions(profiles: [], loading: false)
            return
        }
        let profileEvents = await RelayPool.query(
            relays: Self.activeRelays,
            filter: NostrFilter(kinds: [0], authors: unique),
            timeout: 8
        )
        let profiles = latestKind0Profiles(profileEvents)
        activeNow = Suggestions(profiles: profiles, loading: false)
    }

    private func loadNews() async {
        let events = await RelayPool.query(
            relays: [Self.newsRelay],
            filter: NostrFilter(kinds: [1], limit: 100),
            timeout: 8
        )
        let unique = Array(Set(events.map(\.pubkey)))
        guard !unique.isEmpty else {
            news = Suggestions(profiles: [], loading: false)
            return
        }
        let profileEvents = await RelayPool.query(
            relays: [Self.newsRelay] + Self.activeRelays,
            filter: NostrFilter(kinds: [0], authors: unique),
            timeout: 8
        )
        let profiles = latestKind0Profiles(profileEvents)
        news = Suggestions(profiles: profiles, loading: false)
    }

    private func latestKind0Profiles(_ events: [NostrEvent]) -> [ProfileData] {
        var byPubkey: [String: NostrEvent] = [:]
        for event in events where event.kind == 0 {
            if let existing = byPubkey[event.pubkey], existing.createdAt >= event.createdAt { continue }
            byPubkey[event.pubkey] = event
        }
        var profiles: [ProfileData] = []
        for event in byPubkey.values {
            guard let data = event.content.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            profiles.append(ProfileData(pubkey: event.pubkey, json: json))
            ProfileRepository.shared.updateFromEvent(event)
        }
        return profiles
    }

    func togglePubkey(_ pubkey: String) {
        if selectedFollows.contains(pubkey) { selectedFollows.remove(pubkey) }
        else { selectedFollows.insert(pubkey) }
    }

    func toggleFollowAll(_ section: SuggestionSection) {
        let profiles: [ProfileData] = {
            switch section {
            case .creators:  creators.profiles
            case .activeNow: activeNow.profiles
            case .news:      news.profiles
            }
        }()
        let pubkeys = Set(profiles.map(\.pubkey))
        let allSelected = !pubkeys.isEmpty && pubkeys.isSubset(of: selectedFollows)
        if allSelected {
            selectedFollows.subtract(pubkeys)
        } else {
            selectedFollows.formUnion(pubkeys)
        }
    }

    /// Publish kind-3 with selected pubkeys (plus own pubkey, matching Android),
    /// and kick off the outbox-model builder so the user's scoreboard contains
    /// real per-author relay mappings by the time `MainView` mounts. Without
    /// this, the freshly-signed-up feed comes back empty because every follow
    /// falls through to `fallbackAuthors` and hits indexer relays that don't
    /// stock their notes.
    func finishFollowsStep() async {
        guard let privkey = Hex.decode(keypair.privkey) else { return }
        var follows = selectedFollows
        follows.insert(keypair.pubkey)

        FollowsCache.shared.update(pubkey: keypair.pubkey, follows: Array(follows))

        let writeRelays = discoveredRelays.filter(\.write).map(\.url)

        // Kick off the outbox builder synchronously (Task.detached is non-
        // blocking) BEFORE any awaits so `awaitOutboxReady` always finds a
        // real task to wait on. The user's own write-relay set comes along
        // for the ride so the resulting scoreboard keeps a mapping for
        // ownPubkey even when their just-published kind-10002 hasn't yet
        // landed on the indexer relays we fetch from.
        startOutboxBuilder(follows: Array(follows), ownWriteRelays: writeRelays)

        let targets = (writeRelays + Self.indexerRelays).uniquedPreservingOrder()
        let now = Int(Date().timeIntervalSince1970)
        let tags: [[String]] = follows.map { ["p", $0] }
        guard let event = try? NostrEvent.sign(
            privkey32: privkey,
            pubkey: keypair.pubkey,
            kind: 3,
            createdAt: now,
            tags: tags,
            content: ""
        ) else { return }
        await EventStore.shared.persist([event])
        Task.detached { [event, targets] in
            _ = await RelayPool.publish(event: event, to: targets, timeout: 6)
        }
    }

    /// Mirror of `OnboardingViewModel.startOutboxBuilding`'s relay-list phase:
    /// fetch kind-10002 for every follow, ingest, and rebuild the
    /// `RelayScoreBoard` so the home feed has real per-author write-relays. Runs
    /// in the background while the user is on Steps 3 and 4; `finish()` awaits
    /// completion before transitioning to `MainView`.
    ///
    /// Merges with the existing scoreboard rather than replacing it — the
    /// scoreboard `seedRelayScoreBoard` saved during Step 1 contains the
    /// user's own pubkey → discovered-write-relays mapping, and the indexer
    /// query below typically can't recover that (the user's just-published
    /// kind-10002 hasn't propagated yet). Without the merge, the rebuilt
    /// board drops ownPubkey, the user's own intro note routes through
    /// fallback indexers (which don't have it yet), and the feed looks
    /// almost-empty until app reopen.
    private func startOutboxBuilder(follows: [String], ownWriteRelays: [String]) {
        outboxBuilderTask?.cancel()
        let pubkey = keypair.pubkey
        outboxBuilderTask = Task.detached(priority: .userInitiated) {
            let batchSize = 150
            var bestByAuthor: [String: NostrEvent] = [:]
            for start in stride(from: 0, to: follows.count, by: batchSize) {
                let end = min(start + batchSize, follows.count)
                let chunk = Array(follows[start..<end])
                let events = await RelayPool.query(
                    relays: RelayDefaults.indexers,
                    filter: NostrFilter(kinds: [10002], authors: chunk),
                    timeout: 15
                )
                for event in events {
                    if let existing = bestByAuthor[event.pubkey] {
                        if event.createdAt > existing.createdAt { bestByAuthor[event.pubkey] = event }
                    } else {
                        bestByAuthor[event.pubkey] = event
                    }
                }
            }

            await EventStore.shared.persist(Array(bestByAuthor.values))

            var writeRelaysByAuthor: [String: [String]] = [:]
            for (author, event) in bestByAuthor {
                let relays = event.tags.compactMap { tag -> String? in
                    guard tag.count >= 2, tag[0] == "r" else { return nil }
                    if tag.count == 2 || tag[2] == "write" { return tag[1] }
                    return nil
                }
                if !relays.isEmpty { writeRelaysByAuthor[author] = relays }
            }

            // Always preserve the user's own outbox so their own intro note,
            // boosts, and replies stay reachable on relay.wisp.talk + the
            // discovered set.
            if writeRelaysByAuthor[pubkey] == nil, !ownWriteRelays.isEmpty {
                writeRelaysByAuthor[pubkey] = ownWriteRelays
            }

            let snapshot = bestByAuthor
            await MainActor.run {
                for (_, event) in snapshot {
                    RelayListRepository.shared.ingest(event)
                }

                // Carry forward any author entries we already had (notably
                // ownPubkey from `seedRelayScoreBoard`) for follows whose
                // kind-10002 wasn't on the indexers.
                var merged = writeRelaysByAuthor
                if let existing = RelayScoreBoard.load(pubkey: pubkey) {
                    for (author, relays) in existing.authorRelays where merged[author] == nil {
                        merged[author] = Array(relays)
                    }
                }

                let board = RelayScoreBoard()
                board.build(follows: follows, writeRelaysByAuthor: merged, redundancy: 3)
                guard !board.scoredRelays.isEmpty else { return }
                board.save(pubkey: pubkey)
            }
        }
    }

    /// Block until the background outbox-builder finishes (or the call returns
    /// immediately if it never started or already completed).
    func awaitOutboxReady() async {
        await outboxBuilderTask?.value
    }

    // MARK: - Step 3: hashtags

    func toggleHashtag(_ tag: String) {
        guard let n = Nip51Hashtags.normalize(tag) else { return }
        if selectedHashtags.contains(n) { selectedHashtags.remove(n) }
        else { selectedHashtags.insert(n) }
    }

    func addCustomTopic() {
        guard let n = Nip51Hashtags.normalize(topicQuery) else { return }
        selectedHashtags.insert(n)
        topicQuery = ""
    }

    func finishHashtagsStep() {
        guard !selectedHashtags.isEmpty else { return }
        _ = HashtagSetRepository.shared.createHashtagSet(
            name: "Interests",
            initialHashtags: Array(selectedHashtags),
            keypair: keypair
        )
    }

    /// Fetch trending + all kind-30015 interest sets from the
    /// `feeds.nostrarchives.com` topic feeds. Trending populates the popular
    /// chip list; "all" backs the search-suggestions filter.
    func loadTopics() {
        guard !topicsLoaded else { return }
        topicsLoaded = true
        Task { await fetchTrendingTopics() }
        Task { await fetchAllTopics() }
    }

    private func fetchTrendingTopics() async {
        let events = await RelayPool.query(
            relays: [Self.topicsTrendingRelay],
            filter: NostrFilter(kinds: [30015], dTags: ["trending"], limit: 1),
            timeout: 8
        )
        let topics = extractTopics(from: events)
        popularTopics = topics
        loadingPopular = false
    }

    private func fetchAllTopics() async {
        let events = await RelayPool.query(
            relays: [Self.topicsAllRelay],
            filter: NostrFilter(kinds: [30015], dTags: ["all"], limit: 1),
            timeout: 8
        )
        let topics = extractTopics(from: events)
        allTopics = topics
        applyTopicQuery()
    }

    private func extractTopics(from events: [NostrEvent]) -> [String] {
        let latest = events.max(by: { $0.createdAt < $1.createdAt })
        guard let event = latest else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for tag in event.tags where tag.count >= 2 && tag[0] == "t" {
            guard let n = Nip51Hashtags.normalize(tag[1]) else { continue }
            if seen.insert(n).inserted { out.append(n) }
        }
        return out
    }

    private func applyTopicQuery() {
        let q = topicQuery
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
            .lowercased()
        guard !q.isEmpty else {
            topicSuggestions = []
            return
        }
        let prefix = allTopics.filter { $0.hasPrefix(q) }
        let other = allTopics.filter { !$0.hasPrefix(q) && $0.contains(q) }
        let ranked = (prefix.sorted { $0.count < $1.count } + other.sorted { $0.count < $1.count })
        topicSuggestions = Array(ranked.prefix(20))
    }

    // MARK: - Step 4: intro note

    func publishIntroNote() async {
        let trimmed = introContent.trimmingCharacters(in: .whitespacesAndNewlines)
        // Don't publish if the user only has the prefix and nothing else.
        let onlyPrefix = trimmed.lowercased() == "#introductions"
        guard !trimmed.isEmpty, !onlyPrefix else { return }

        publishingIntro = true
        defer { publishingIntro = false }

        guard let privkey = Hex.decode(keypair.privkey) else { return }
        var tags: [[String]] = [["t", "introductions"]]
        if let clientTag = NostrEvent.clientTagIfEnabled() { tags.append(clientTag) }

        let writeRelays = discoveredRelays.filter(\.write).map(\.url)
        let targets = writeRelays.isEmpty ? Self.indexerRelays : writeRelays
        let now = Int(Date().timeIntervalSince1970)
        guard let event = try? NostrEvent.sign(
            privkey32: privkey,
            pubkey: keypair.pubkey,
            kind: 1,
            createdAt: now,
            tags: tags,
            content: introContent
        ) else { return }
        await EventStore.shared.persist([event])
        Task.detached { [event, targets] in
            _ = await RelayPool.publish(event: event, to: targets, timeout: 6)
        }
    }

    /// Begin the post-now countdown. After `seconds` ticks of 1 Hz the intro
    /// note is published, then the completion handler runs. Cancellable via
    /// `cancelPostCountdown` or when the view disappears.
    func startPostCountdown(seconds: Int = 5, onComplete: @escaping () async -> Void) {
        cancelPostCountdown()
        postCountdown = seconds
        countdownTask = Task { [weak self] in
            for remaining in stride(from: seconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.postCountdown = remaining }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await self?.publishIntroNote()
            await MainActor.run {
                self?.postCountdown = nil
                self?.countdownTask = nil
            }
            await onComplete()
        }
    }

    func cancelPostCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        postCountdown = nil
    }

    func postIntroNow(onComplete: @escaping () async -> Void) {
        cancelPostCountdown()
        Task {
            await publishIntroNote()
            await onComplete()
        }
    }

    // MARK: - Completion

    func markComplete() {
        NostrKey.markOnboardingComplete(pubkey: keypair.pubkey)
    }
}

private extension Array where Element == String {
    func uniquedPreservingOrder() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for url in self where seen.insert(url).inserted { out.append(url) }
        return out
    }
}
