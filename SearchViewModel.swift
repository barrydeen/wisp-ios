import Foundation
import Observation

@Observable
@MainActor
final class SearchViewModel {
    let keypair: Keypair

    enum Mode: String { case notes, people }
    enum RelayOption: String { case `default`, all, individual }

    // MARK: - Inputs

    var query: String = ""
    var mode: Mode = .people
    var showAdvanced: Bool = false

    var relayOption: RelayOption = .default
    var selectedRelayUrl: String?
    var savedSearchRelays: [String] = []

    var authorFilter: ProfileData?
    var authorQuery: String = ""

    // MARK: - Outputs

    var notes: [NostrEvent] = []
    var noteProfiles: [String: ProfileData] = [:]
    var people: [ProfileData] = []
    var authorResults: [ProfileData] = []

    var engagement: [String: EngagementCounts] = [:]
    var isSearching = false
    var isAuthorSearching = false
    var hasSearched = false

    // MARK: - Internals

    @ObservationIgnored private let profileRepo = ProfileRepository.shared
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var authorDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var authorSearchTask: Task<Void, Never>?
    @ObservationIgnored private var profileUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var searchCounter: Int = 0
    @ObservationIgnored private var authorCounter: Int = 0

    static let defaultSearchRelay = "wss://search.nostrarchives.com"

    private static let engagementFallbackRelays = ["wss://relay.damus.io"]

    private let searchTimeout: TimeInterval = 5
    private let engagementTimeout: TimeInterval = 10
    private let authorTimeout: TimeInterval = 4

    // MARK: - Lifecycle

    init(keypair: Keypair) {
        self.keypair = keypair
    }

    func start() {
        loadPreferences()
        if profileUpdatesTask == nil {
            profileUpdatesTask = Task { @MainActor [weak self] in
                for await pk in MissingProfileWatcher.shared.updates {
                    guard let self else { return }
                    if self.notes.contains(where: { $0.pubkey == pk }),
                       let p = self.profileRepo.get(pk) {
                        self.noteProfiles[pk] = p
                    }
                }
            }
        }
    }

    func stop() {
        debounceTask?.cancel()
        searchTask?.cancel()
        authorDebounceTask?.cancel()
        authorSearchTask?.cancel()
        profileUpdatesTask?.cancel()
        profileUpdatesTask = nil
    }

    // MARK: - Persistence

    private func loadPreferences() {
        let pk = keypair.pubkey
        let opt = UserDefaults.standard.string(forKey: "search_relay_option_\(pk)") ?? "default"
        relayOption = RelayOption(rawValue: opt) ?? .default
        selectedRelayUrl = UserDefaults.standard.string(forKey: "search_relay_url_\(pk)")
        savedSearchRelays = UserDefaults.standard.stringArray(forKey: "search_relays_\(pk)") ?? []
    }

    private func savePreferences() {
        let pk = keypair.pubkey
        UserDefaults.standard.set(relayOption.rawValue, forKey: "search_relay_option_\(pk)")
        if let url = selectedRelayUrl {
            UserDefaults.standard.set(url, forKey: "search_relay_url_\(pk)")
        } else {
            UserDefaults.standard.removeObject(forKey: "search_relay_url_\(pk)")
        }
        UserDefaults.standard.set(savedSearchRelays, forKey: "search_relays_\(pk)")
    }

    // MARK: - Inputs

    func updateQuery(_ text: String) {
        query = text
        debounceTask?.cancel()
        let intent = preprocessQuery(text)
        guard isQueryActionable(intent) else {
            if case .text(let s) = intent, s.isEmpty {
                notes = []
                people = []
                noteProfiles = [:]
                engagement = [:]
                hasSearched = false
            }
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.runSearch()
        }
    }

    func setMode(_ newMode: Mode) {
        guard mode != newMode else { return }
        mode = newMode
        if isQueryActionable(preprocessQuery(query)) { runSearch() }
    }

    func setRelayOption(_ option: RelayOption, url: String? = nil) {
        relayOption = option
        if option == .individual {
            selectedRelayUrl = url ?? selectedRelayUrl
        }
        savePreferences()
        if isQueryActionable(preprocessQuery(query)) { runSearch() }
    }

    func addCustomRelay(_ url: String) {
        let normalized = normalizeRelayUrl(url)
        guard !normalized.isEmpty else { return }
        if !savedSearchRelays.contains(normalized) {
            savedSearchRelays.append(normalized)
        }
        selectedRelayUrl = normalized
        relayOption = .individual
        savePreferences()
    }

    func removeCustomRelay(_ url: String) {
        savedSearchRelays.removeAll { $0 == url }
        if selectedRelayUrl == url {
            selectedRelayUrl = nil
            if relayOption == .individual { relayOption = .default }
        }
        savePreferences()
    }

    func setAuthorFilter(_ profile: ProfileData?) {
        authorFilter = profile
        authorResults = []
        authorQuery = ""
        if mode == .notes, isQueryActionable(preprocessQuery(query)) {
            runSearch()
        }
    }

    func updateAuthorQuery(_ text: String) {
        authorQuery = text
        authorDebounceTask?.cancel()
        guard case .text(let trimmed) = preprocessQuery(text), trimmed.count >= 2 else {
            authorResults = []
            return
        }
        authorDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.runAuthorSearch(trimmed)
        }
    }

    // MARK: - Search

    func runSearch() {
        let intent = preprocessQuery(query)
        guard isQueryActionable(intent) else { return }

        searchCounter += 1
        let myCounter = searchCounter
        let mode = self.mode

        searchTask?.cancel()
        isSearching = true
        hasSearched = true
        if mode == .notes {
            notes = []
            engagement = [:]
            noteProfiles = [:]
        } else {
            people = []
        }

        let timeout = searchTimeout
        searchTask = Task { [weak self] in
            guard let self else { return }

            // For people search, NIP-05 identifiers need an async HTTP lookup
            // before we can build the relay filter.
            if mode == .people, case .nip05(let identifier) = intent {
                let pubkey = await Nip05Verifier.lookup(identifier: identifier)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard myCounter == self.searchCounter else { return }
                    if let pubkey {
                        self.runPubkeyFetch(pubkey: pubkey, counter: myCounter, timeout: timeout)
                    } else {
                        // NIP-05 lookup failed — nothing to show
                        self.people = []
                        self.isSearching = false
                    }
                }
                return
            }

            let relays = self.relaysToQuery()
            guard !relays.isEmpty else {
                await MainActor.run { self.isSearching = false }
                return
            }

            let filter: NostrFilter
            let queryRelays: [String]
            switch mode {
            case .people:
                switch intent {
                case .pubkey(let pubkey):
                    filter = NostrFilter(kinds: [0], authors: [pubkey], limit: 1)
                    let combined = ([Self.defaultSearchRelay] + Array(RelayDefaults.indexers))
                        .reduce(into: [String]()) { acc, url in if !acc.contains(url) { acc.append(url) } }
                    queryRelays = combined
                case .text(let trimmed):
                    filter = NostrFilter(kinds: [0], limit: 20, search: trimmed)
                    queryRelays = relays
                case .nip05:
                    // Handled above via the early-return path
                    return
                }
            case .notes:
                let authorPubkey = self.authorFilter?.pubkey
                guard case .text(let trimmed) = intent else { return }
                filter = NostrFilter(
                    kinds: [1],
                    authors: authorPubkey.map { [$0] },
                    limit: 50,
                    search: trimmed
                )
                queryRelays = relays
            }

            let events = await RelayPool.query(relays: queryRelays, filter: filter, timeout: timeout)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard myCounter == self.searchCounter else { return }
                switch mode {
                case .people: self.handlePeopleResults(events)
                case .notes:  self.handleNoteResults(events)
                }
                self.isSearching = false
            }
        }
    }

    /// Fetch a single kind-0 by pubkey after a NIP-05 lookup resolved the pubkey.
    /// Runs a new sub-task so the NIP-05 path can return early from its task.
    private func runPubkeyFetch(pubkey: String, counter: Int, timeout: TimeInterval) {
        let filter = NostrFilter(kinds: [0], authors: [pubkey], limit: 1)
        let combined = ([Self.defaultSearchRelay] + Array(RelayDefaults.indexers))
            .reduce(into: [String]()) { acc, url in if !acc.contains(url) { acc.append(url) } }
        searchTask = Task { [weak self] in
            let events = await RelayPool.query(relays: combined, filter: filter, timeout: timeout)
            guard let self else { return }
            await MainActor.run {
                guard counter == self.searchCounter else { return }
                self.handlePeopleResults(events)
                self.isSearching = false
            }
        }
    }

    private func handlePeopleResults(_ events: [NostrEvent]) {
        var seen = Set<String>()
        var results: [ProfileData] = []
        for event in events where event.kind == 0 {
            guard seen.insert(event.pubkey).inserted else { continue }
            if let profile = profileRepo.updateFromEvent(event) {
                results.append(profile)
            } else {
                results.append(ProfileData(pubkey: event.pubkey))
            }
        }
        let follows = FollowsCache.shared.followsSet(for: keypair.pubkey)
        results.sort { lhs, rhs in
            let lf = follows.contains(lhs.pubkey)
            let rf = follows.contains(rhs.pubkey)
            if lf != rf { return lf && !rf }
            return false
        }
        people = results
    }

    private func handleNoteResults(_ events: [NostrEvent]) {
        var seen = Set<String>()
        var ordered: [NostrEvent] = []
        for event in events where event.kind == 1 {
            if seen.insert(event.id).inserted {
                ordered.append(event)
            }
        }
        notes = ordered

        // Seed profiles from cache so names/avatars render immediately.
        var seedProfiles: [String: ProfileData] = [:]
        for pubkey in Set(ordered.map(\.pubkey)) {
            if let p = profileRepo.get(pubkey) {
                seedProfiles[pubkey] = p
            }
        }
        noteProfiles = seedProfiles

        let ids = ordered.map(\.id)
        let missingPubkeys = Set(ordered.map(\.pubkey)).filter { noteProfiles[$0] == nil }
        Task { [weak self] in
            await self?.loadEngagement(for: ids)
        }
        if !missingPubkeys.isEmpty {
            MissingProfileWatcher.shared.observePubkeys(missingPubkeys)
        }
    }

    // MARK: - Engagement

    private func loadEngagement(for ids: [String]) async {
        guard !ids.isEmpty else { return }
        let relays = engagementRelays()
        let kinds = [1, 6, 7, 9735]
        let chunks = ids.chunked(into: 200)
        let timeout = engagementTimeout
        await withTaskGroup(of: [NostrEvent].self) { group in
            for chunk in chunks {
                group.addTask {
                    await RelayPool.query(
                        relays: relays,
                        filter: NostrFilter(kinds: kinds, eTags: chunk, limit: 500),
                        timeout: timeout
                    )
                }
            }
            for await batch in group {
                ingestEngagement(batch)
            }
        }
    }

    private func ingestEngagement(_ events: [NostrEvent]) {
        for event in events {
            guard let target = event.tags.first(where: { $0.first == "e" && $0.count >= 2 })?[1] else { continue }
            var current = engagement[target] ?? EngagementCounts()
            switch event.kind {
            case 1:
                current.replies += 1
            case 6:
                current.reposts += 1
            case 7:
                current.reactions += 1
                let reactor = Reactor(
                    pubkey: event.pubkey,
                    emoji: event.content,
                    customEmojiUrl: EngagementRepository.customEmojiUrl(for: event.content, in: event.tags)
                )
                if !current.reactors.contains(where: { $0.pubkey == reactor.pubkey && $0.emoji == reactor.emoji }) {
                    current.reactors.append(reactor)
                }
            case 9735:
                if let bolt = event.tags.first(where: { $0.first == "bolt11" && $0.count >= 2 })?[1],
                   let decoded = Bolt11.decode(bolt),
                   let sats = decoded.amountSats {
                    current.zapSats += sats
                    current.zapCount += 1
                } else {
                    current.zapCount += 1
                }
            default: break
            }
            engagement[target] = current
        }
    }

    // MARK: - Author autocomplete

    private func runAuthorSearch(_ trimmed: String) {
        authorCounter += 1
        let myCounter = authorCounter
        let relays = relaysToQuery()
        guard !relays.isEmpty else { return }
        isAuthorSearching = true
        authorSearchTask?.cancel()
        let timeout = authorTimeout
        authorSearchTask = Task { [weak self] in
            let events = await RelayPool.query(
                relays: relays,
                filter: NostrFilter(kinds: [0], limit: 10, search: trimmed),
                timeout: timeout
            )
            guard let self else { return }
            await MainActor.run {
                guard myCounter == self.authorCounter else { return }
                var seen = Set<String>()
                var results: [ProfileData] = []
                for event in events where event.kind == 0 {
                    guard seen.insert(event.pubkey).inserted else { continue }
                    if let profile = self.profileRepo.updateFromEvent(event) {
                        results.append(profile)
                    } else {
                        results.append(ProfileData(pubkey: event.pubkey))
                    }
                }
                self.authorResults = Array(results.prefix(10))
                self.isAuthorSearching = false
            }
        }
    }

    // MARK: - Search intent

    enum SearchIntent {
        case text(String)     // full-text search via NIP-50
        case pubkey(String)   // resolved hex pubkey → authors: filter
        case nip05(String)    // name@domain → async HTTP lookup → authors: filter
    }

    // MARK: - Helpers

    private func relaysToQuery() -> [String] {
        switch relayOption {
        case .default:
            return [Self.defaultSearchRelay]
        case .all:
            let combined = ([Self.defaultSearchRelay] + savedSearchRelays).reduce(into: [String]()) { acc, url in
                if !acc.contains(url) { acc.append(url) }
            }
            return combined.isEmpty ? [Self.defaultSearchRelay] : combined
        case .individual:
            if let url = selectedRelayUrl, !url.isEmpty { return [url] }
            return [Self.defaultSearchRelay]
        }
    }

    private func engagementRelays() -> [String] {
        if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
            let top = board.scoredRelays.prefix(20).map(\.url)
            if !top.isEmpty { return top }
        }
        return Self.engagementFallbackRelays
    }

    private func preprocessQuery(_ text: String) -> SearchIntent {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("nostr:") { s = String(s.dropFirst("nostr:".count)) }

        let lower = s.lowercased()

        // npub / nprofile → decode to hex pubkey
        if lower.hasPrefix("npub1") || lower.hasPrefix("nprofile1") {
            if let data = Nip19.decodeNostrUri(s), case .profileRef(let pubkey, _) = data {
                return .pubkey(pubkey)
            }
        }

        // Bare 64-char hex pubkey
        if s.count == 64, s.allSatisfy({ $0.isHexDigit }) {
            return .pubkey(s.lowercased())
        }

        // NIP-05 identifier: name@domain or _@domain
        if s.contains("@") {
            let parts = s.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") {
                return .nip05(s)
            }
        }

        return .text(s)
    }

    private func isQueryActionable(_ intent: SearchIntent) -> Bool {
        switch intent {
        case .text(let s): return s.count >= 2
        case .pubkey, .nip05: return true
        }
    }

    private func normalizeRelayUrl(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("wss://") || trimmed.hasPrefix("ws://") { return trimmed }
        return "wss://" + trimmed
    }
}
