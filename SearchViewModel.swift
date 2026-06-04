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
        // No-op when the text hasn't actually changed. SwiftUI's
        // `TextField` binding fires `set` again when the field loses
        // focus (e.g. `scrollDismissesKeyboard` during a scroll over the
        // results), passing back the same string. Without this guard,
        // every scroll cancelled the previous debounce + restarted the
        // 500 ms timer, then ran a fresh `runSearch()` that cleared the
        // visible results and re-fetched them.
        guard text != query else { return }
        // A pasted `nostr:` URI scheme is transport syntax, never search
        // terms — strip it from the field itself (the binding's `get`
        // re-reads `query`) when a NIP-19 entity follows. Plain text after
        // `nostr:` is left alone so typing the literal word isn't mangled;
        // `preprocessQuery` still drops the scheme for intent either way.
        let text = strippedNostrScheme(from: text)
        guard text != query else { return }
        query = text
        debounceTask?.cancel()
        let intent = preprocessQuery(text)
        // An explicit NIP-19 entity implies its search mode — an event
        // reference can only resolve as a note, a profile reference only
        // as a person. Re-aim the mode chip so the result actually shows.
        if let implied = impliedMode(for: text), mode != implied {
            mode = implied
        }
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

        // A pasted event reference is only ever a direct note lookup —
        // re-align the mode in case the user toggled People with the
        // reference still in the field.
        if case .eventRef = intent, mode != .notes { mode = .notes }

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

            // Direct id lookup for a pasted note1/nevent1 — queries the
            // nevent's relay hints plus discovery relays, and verifies the
            // result against the requested id (see runEventLookup).
            if case .eventRef(let id, let hints) = intent {
                await self.runEventLookup(id: id, relayHints: hints, counter: myCounter)
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
                case .nip05, .eventRef:
                    // Handled above via the early-return paths
                    return
                }
            case .notes:
                let authorPubkey = self.authorFilter?.pubkey
                guard case .text(let trimmed) = intent else {
                    // Identity intents (pubkey / NIP-05) have no notes-mode
                    // form — end the search instead of stranding the spinner.
                    await MainActor.run {
                        guard myCounter == self.searchCounter else { return }
                        self.isSearching = false
                    }
                    return
                }
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

    /// Direct event-id lookup for a pasted `note1` / `nevent1` reference.
    /// Queries the nevent's relay hints plus the search + indexer relays,
    /// and only accepts an event whose *recomputed* id matches the request:
    /// a misbehaving relay can answer an `ids:` filter with a different
    /// note (or forge the requested id onto different content), and
    /// first-event-wins would render the wrong note.
    private func runEventLookup(id: String, relayHints: [String], counter: Int) async {
        var seen = Set<String>()
        var relays: [String] = []
        for raw in relayHints {
            let url = normalizeRelayUrl(raw)
            if !url.isEmpty, seen.insert(url).inserted { relays.append(url) }
        }
        for url in relaysToQuery() where seen.insert(url).inserted { relays.append(url) }
        for url in RelayDefaults.indexers where seen.insert(url).inserted { relays.append(url) }

        var filter = NostrFilter()
        filter.ids = [id]
        filter.limit = 1
        let events = await RelayPool.query(relays: relays, filter: filter, timeout: searchTimeout)
        guard !Task.isCancelled, counter == searchCounter else { return }

        let match = events.first { event in
            event.id == id && NostrEvent.computeId(
                pubkey: event.pubkey,
                createdAt: event.createdAt,
                kind: event.kind,
                tags: event.tags,
                content: event.content
            ) == id
        }
        handleNoteResults(match.map { [$0] } ?? [])
        isSearching = false
    }

    private func handlePeopleResults(_ events: [NostrEvent]) {
        var seen = Set<String>()
        var results: [ProfileData] = []
        for event in events where event.kind == 0 {
            guard seen.insert(canonicalPubkey(event.pubkey)).inserted else { continue }
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
                    guard seen.insert(self.canonicalPubkey(event.pubkey)).inserted else { continue }
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
        case eventRef(id: String, relays: [String])  // note1/nevent1 → ids: lookup
    }

    // MARK: - Helpers

    /// Collapse the different string forms the same identity can arrive in
    /// from a search relay — mixed-case or whitespace-padded hex, or an
    /// `npub` / `nprofile` in place of raw hex — down to one canonical
    /// lowercase-hex key. Without this, two index entries for one account
    /// slip past the `Set`-based dedup and render as duplicate rows.
    private func canonicalPubkey(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("npub1") || lower.hasPrefix("nprofile1"),
           case .profileRef(let hex, _)? = Nip19.decodeNostrUri(lower) {
            return hex
        }
        return lower
    }

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
        // Strip a sole leading `@` so a user who reflexively types
        // `@scrubby` (the composer-mention syntax) gets matched against
        // the same content the bare-handle form would. NIP-05 lookups
        // like `_@domain.com` still parse because the `_` precedes the
        // `@` — we only drop the very first `@` if it's at position 0.
        if s.hasPrefix("@") { s = String(s.dropFirst()) }
        if s.lowercased().hasPrefix("nostr:") { s = String(s.dropFirst("nostr:".count)) }

        let lower = s.lowercased()

        // npub / nprofile → decode to hex pubkey
        if lower.hasPrefix("npub1") || lower.hasPrefix("nprofile1") {
            if let data = Nip19.decodeNostrUri(s), case .profileRef(let pubkey, _) = data {
                return .pubkey(pubkey)
            }
        }

        // note / nevent → decode to a direct event-id lookup
        if lower.hasPrefix("note1") || lower.hasPrefix("nevent1") {
            if let data = Nip19.decodeNostrUri(s),
               case .noteRef(let eventId, let relays, _) = data, !eventId.isEmpty {
                return .eventRef(id: eventId, relays: relays)
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
        case .pubkey, .nip05, .eventRef: return true
        }
    }

    /// Visible-field form of the `nostr:` strip: drop the scheme only when a
    /// NIP-19 entity actually follows, so a paste shows the bare entity but
    /// someone typing the literal text "nostr:..." keeps their input.
    private func strippedNostrScheme(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("nostr:") else { return text }
        let rest = String(trimmed.dropFirst("nostr:".count))
        let restLower = rest.lowercased()
        let entityPrefixes = ["npub1", "nprofile1", "note1", "nevent1", "naddr1"]
        guard entityPrefixes.contains(where: { restLower.hasPrefix($0) }) else { return text }
        return rest
    }

    /// Mode implied by an explicit NIP-19 entity at the head of the query,
    /// or nil when the text doesn't pin one down.
    private func impliedMode(for text: String) -> Mode? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("@") { s = String(s.dropFirst()) }
        if s.hasPrefix("nostr:") { s = String(s.dropFirst("nostr:".count)) }
        if s.hasPrefix("note1") || s.hasPrefix("nevent1") { return .notes }
        if s.hasPrefix("npub1") || s.hasPrefix("nprofile1") { return .people }
        return nil
    }

    private func normalizeRelayUrl(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("wss://") || trimmed.hasPrefix("ws://") { return trimmed }
        return "wss://" + trimmed
    }
}
