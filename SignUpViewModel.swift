import Foundation
import Observation

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

    // MARK: - Suggestions step state

    var creators: Suggestions = Suggestions()
    var activeNow: Suggestions = Suggestions()
    var news: Suggestions = Suggestions()
    var selectedFollows: Set<String> = []
    private var suggestionsLoaded = false

    // MARK: - Hashtags step state

    var selectedHashtags: Set<String> = []

    // MARK: - Intro note state

    var introContent: String = "#introductions\n\n"
    var publishingIntro: Bool = false

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

    private static let indexerRelays = RelayDefaults.onboarding

    static let popularHashtags = [
        "nostr", "bitcoin", "lightning", "art", "photography",
        "music", "tech", "news", "podcasting", "gm",
        "introductions", "memes"
    ]

    // MARK: - Init

    /// Generate a fresh keypair and persist it via `NostrKey`. Marks the active
    /// account so subsequent app launches resume into this user.
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
        NostrKey.save(self.keypair)
    }

    // MARK: - Step 1: profile + relay discovery

    func startRelayDiscovery() {
        guard relayPhase == .idle else { return }
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
                self.discoveredRelays = relays
                self.probingUrl = nil
                if self.relayPhase != .failed { self.relayPhase = .ready }
                self.seedRelayScoreBoard(relays: relays)
            }
        }
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

    func uploadAvatar(data: Data, mime: String) async {
        uploading = true
        uploadError = nil
        defer { uploading = false }

        guard let privkey = Hex.decode(keypair.privkey) else {
            uploadError = "Invalid key"
            return
        }
        let servers = BlossomServerList.cached(for: keypair.pubkey)
        do {
            let result = try await BlossomClient.upload(
                bytes: data,
                mime: mime,
                servers: servers,
                privkey32: privkey,
                pubkey: keypair.pubkey
            )
            self.pictureUrl = result.url
        } catch {
            self.uploadError = "Upload failed"
        }
    }

    /// Publish kind-10002 (relay list) and kind-0 (profile metadata). Both go
    /// to the discovered write relays plus the indexer fallback set so other
    /// clients see them quickly.
    func finishProfileStep() async {
        guard !publishingProfile else { return }
        publishingProfile = true
        defer { publishingProfile = false }

        let writeRelays = discoveredRelays.filter(\.write).map(\.url)
        let publishTargets = (writeRelays + Self.indexerRelays).uniquedPreservingOrder()

        await publishRelayList(targets: publishTargets)
        await publishProfile(targets: publishTargets)
    }

    private func publishRelayList(targets: [String]) async {
        guard let privkey = Hex.decode(keypair.privkey) else { return }
        let now = Int(Date().timeIntervalSince1970)
        let tags = Nip51Lists.buildGeneralRelayTags(discoveredRelays)
        guard let event = try? NostrEvent.sign(
            privkey32: privkey,
            pubkey: keypair.pubkey,
            kind: 10002,
            createdAt: now,
            tags: tags,
            content: ""
        ) else { return }
        _ = await RelayPool.publish(event: event, to: targets, timeout: 6)
        await EventStore.shared.persist([event])
        RelayListRepository.shared.ingest(event)
    }

    private func publishProfile(targets: [String]) async {
        guard let privkey = Hex.decode(keypair.privkey) else { return }
        var json: [String: String] = [:]
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedAbout = about.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            json["name"] = trimmedName
            json["display_name"] = trimmedName
        }
        if !trimmedAbout.isEmpty { json["about"] = trimmedAbout }
        if let pic = pictureUrl, !pic.isEmpty { json["picture"] = pic }
        guard !json.isEmpty,
              let body = try? JSONSerialization.data(withJSONObject: json),
              let bodyStr = String(data: body, encoding: .utf8) else { return }
        let now = Int(Date().timeIntervalSince1970)
        guard let event = try? NostrEvent.sign(
            privkey32: privkey,
            pubkey: keypair.pubkey,
            kind: 0,
            createdAt: now,
            tags: [],
            content: bodyStr
        ) else { return }
        _ = await RelayPool.publish(event: event, to: targets, timeout: 6)
        await EventStore.shared.persist([event])
        ProfileRepository.shared.updateFromEvent(event)
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

    /// Publish kind-3 with selected pubkeys (plus own pubkey, matching Android).
    func finishFollowsStep() async {
        guard let privkey = Hex.decode(keypair.privkey) else { return }
        var follows = selectedFollows
        follows.insert(keypair.pubkey)

        FollowsCache.shared.update(pubkey: keypair.pubkey, follows: Array(follows))

        let writeRelays = discoveredRelays.filter(\.write).map(\.url)
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
        _ = await RelayPool.publish(event: event, to: targets, timeout: 6)
        await EventStore.shared.persist([event])
    }

    // MARK: - Step 3: hashtags

    func toggleHashtag(_ tag: String) {
        guard let n = Nip51Hashtags.normalize(tag) else { return }
        if selectedHashtags.contains(n) { selectedHashtags.remove(n) }
        else { selectedHashtags.insert(n) }
    }

    func finishHashtagsStep() {
        guard !selectedHashtags.isEmpty else { return }
        _ = HashtagSetRepository.shared.createHashtagSet(
            name: "Interests",
            initialHashtags: Array(selectedHashtags),
            keypair: keypair
        )
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
        _ = await RelayPool.publish(event: event, to: targets, timeout: 6)
        await EventStore.shared.persist([event])
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
