import Foundation
import Observation

/// Top-level NIP-29 controller. Mirrors the Kotlin `GroupListViewModel`.
/// Owns the per-group subscription lifecycle, executes user actions
/// (create / join / leave / admin), publishes the kind-10009 list to
/// keep other devices in sync, and feeds incoming events into the repository.
@Observable
@MainActor
final class GroupListViewModel {

    let keypair: Keypair
    let repository: GroupRepository

    @ObservationIgnored private let pool = GroupRelayPool.shared
    @ObservationIgnored private var groupTasks: [String: [Task<Void, Never>]] = [:]
    @ObservationIgnored private var subIds: [String: [String]] = [:]
    @ObservationIgnored private var started = false

    /// Surface for UI toasts on join/admin failures.
    var lastJoinError: JoinError?
    var lastAdminError: AdminError?
    var isJoining = false

    /// Set by `MainView` when the user taps a `wss://host'<groupid>` link in
    /// note content. `MessagesView` observes this, switches to the rooms
    /// sub-tab, joins (idempotent), pushes the room onto its NavigationPath,
    /// and clears the value back to nil.
    var pendingChatDeepLink: ChatDeepLink?

    /// Default + indexer relays where we'll look for the user's own kind-10009 list
    /// at startup so other-device joins surface here too.
    private static let listLookupRelays: [String] = [
        Nip29.defaultGroupRelay,
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://relay.nostr.band"
    ]

    init(keypair: Keypair) {
        self.keypair = keypair
        self.repository = GroupRepository(ownerPubkey: keypair.pubkey)
    }

    // MARK: - Lifecycle

    func start() async {
        guard !started else { return }
        started = true
        await repository.seedFromDisk()
        // Subscribe to every cached group.
        for room in repository.joinedGroups {
            await ensureRelayAndSubscribe(relayUrl: room.relayUrl, groupId: room.groupId)
        }
        // Sync from kind-10009 (other-device joins).
        await syncFromRemoteGroupList()
    }

    func stop() {
        for tasks in groupTasks.values { for t in tasks { t.cancel() } }
        groupTasks.removeAll()
        subIds.removeAll()
        Task { await pool.shutdownAll() }
        started = false
    }

    // MARK: - Per-group subscriptions

    private func ensureRelayAndSubscribe(relayUrl: String, groupId: String) async {
        await pool.ensureRelay(relayUrl, keypair: keypair)
        subscribeToGroup(relayUrl: relayUrl, groupId: groupId)
    }

    private func subscribeToGroup(relayUrl: String, groupId: String) {
        let key = "\(relayUrl)|\(groupId)"
        if subIds[key] != nil { return }   // Already subscribed.

        var ids: [String] = []
        var tasks: [Task<Void, Never>] = []

        func add(filter: NostrFilter, suffix: String) {
            let subId = "grp-\(suffix)-\(groupId.prefix(12))"
            ids.append(subId)
            let task = Task { [weak self] in
                guard let self else { return }
                let stream = await self.pool.subscribe(relayUrl: relayUrl, filter: filter, subId: subId)
                for await event in stream {
                    await self.handleIncoming(event: event, relayUrl: relayUrl, groupId: groupId)
                }
            }
            tasks.append(task)
        }

        add(filter: NostrFilter(kinds: [Nip29.kindChatMessage], hTags: [groupId], limit: 100), suffix: "msg")
        add(filter: NostrFilter(kinds: [Nip29.kindGroupMetadata], dTags: [groupId]), suffix: "meta")
        add(filter: NostrFilter(kinds: [Nip29.kindGroupAdmins],   dTags: [groupId]), suffix: "admins")
        add(filter: NostrFilter(kinds: [Nip29.kindGroupMembers],  dTags: [groupId]), suffix: "members")
        add(filter: NostrFilter(kinds: [7], hTags: [groupId], limit: 500), suffix: "react")

        subIds[key] = ids
        groupTasks[key] = tasks
    }

    private func unsubscribeFromGroup(relayUrl: String, groupId: String) async {
        let key = "\(relayUrl)|\(groupId)"
        if let ids = subIds.removeValue(forKey: key) {
            for sid in ids { await pool.cancelSubscription(relayUrl: relayUrl, subId: sid) }
        }
        if let tasks = groupTasks.removeValue(forKey: key) { for t in tasks { t.cancel() } }
        // If no other group on this relay, release it.
        let stillUsed = repository.joinedGroups.contains { $0.relayUrl == relayUrl && $0.groupId != groupId }
        if !stillUsed {
            await pool.releaseRelay(relayUrl)
        }
    }

    private func handleIncoming(event: NostrEvent, relayUrl: String, groupId: String) async {
        switch event.kind {
        case Nip29.kindChatMessage:
            let replyId = Nip29.extractReplyId(from: event)
            let emojiTags = ContentParser.parseEmojiTags(event.tags)
            let msg = GroupMessage(id: event.id, senderPubkey: event.pubkey,
                                   content: event.content, createdAt: event.createdAt,
                                   replyToId: replyId, emojiTags: emojiTags)
            repository.addMessage(msg, relayUrl: relayUrl, groupId: groupId)
            // Eagerly load any custom-emoji images referenced by this message.
            for url in emojiTags.values { EmojiImageCache.shared.ensureLoaded(url) }
            // Kick off profile fetch for the sender if we don't have it cached yet.
            Task { await self.requestProfileIfNeeded(event.pubkey) }

        case Nip29.kindGroupMetadata:
            if let metadata = Nip29.parseGroupMetadata(event) {
                repository.updateMetadata(metadata, relayUrl: relayUrl)
            }

        case Nip29.kindGroupAdmins:
            let admins = Nip29.parseGroupAdminPubkeys(event)
            repository.updateAdmins(admins, relayUrl: relayUrl, groupId: groupId)

        case Nip29.kindGroupMembers:
            let members = Nip29.parseGroupMembers(event)
            repository.updateMembers(members, relayUrl: relayUrl, groupId: groupId)

        case 7:
            // Reaction. e-tag = message id, h-tag = group id.
            guard let messageId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] else { return }
            let emoji = event.content.isEmpty ? "+" : event.content
            let emojiUrl = event.tags.first(where: { $0.count >= 3 && $0[0] == "emoji" && $0[1] == emoji })?[2]
            repository.addReaction(messageId: messageId, reactorPubkey: event.pubkey,
                                   emoji: emoji, emojiUrl: emojiUrl,
                                   relayUrl: relayUrl, groupId: groupId)

        default:
            break
        }
    }

    // MARK: - Create

    func createGroup(relayUrl: String, name: String,
                     isPrivate: Bool = false, isClosed: Bool = false,
                     isRestricted: Bool = false, isHidden: Bool = false) async -> Result<GroupRoom, AdminError> {
        let trimmedRelay = normalizeRelay(relayUrl)
        let groupId = Nip29.generateGroupId()
        let priv = Hex.decode(keypair.privkey) ?? Data()

        // Optimistic local insert + subscribe.
        let optimisticRoom = repository.addGroup(relayUrl: trimmedRelay, groupId: groupId, name: name)
        await ensureRelayAndSubscribe(relayUrl: trimmedRelay, groupId: groupId)

        // Send kind 9007 (create-group).
        do {
            let create = try Nip29.buildCreateGroup(privkey32: priv, pubkey: keypair.pubkey, groupId: groupId)
            let result = await pool.publishWithAuthRetry(create, to: trimmedRelay)
            switch result {
            case .ok, .duplicate:
                break
            case .timeout:
                // Best-effort: assume relay accepted silently. Continue.
                break
            case .rejected(let msg):
                repository.removeGroup(relayUrl: trimmedRelay, groupId: groupId)
                await unsubscribeFromGroup(relayUrl: trimmedRelay, groupId: groupId)
                lastAdminError = .rejected(message: msg)
                return .failure(.rejected(message: msg))
            case .authRequired:
                repository.removeGroup(relayUrl: trimmedRelay, groupId: groupId)
                await unsubscribeFromGroup(relayUrl: trimmedRelay, groupId: groupId)
                lastAdminError = .notAuthenticated
                return .failure(.notAuthenticated)
            case .network:
                repository.removeGroup(relayUrl: trimmedRelay, groupId: groupId)
                await unsubscribeFromGroup(relayUrl: trimmedRelay, groupId: groupId)
                lastAdminError = .network
                return .failure(.network)
            }
        } catch {
            repository.removeGroup(relayUrl: trimmedRelay, groupId: groupId)
            await unsubscribeFromGroup(relayUrl: trimmedRelay, groupId: groupId)
            return .failure(.network)
        }

        // If any flag set, follow up with kind 9002 after a short delay to let the relay
        // bootstrap the group's metadata event (mirrors Android's 1.5s delay).
        if isPrivate || isClosed || isRestricted || isHidden || !name.isEmpty {
            try? await Task.sleep(for: .milliseconds(1500))
            do {
                let edit = try Nip29.buildEditMetadata(
                    privkey32: priv, pubkey: keypair.pubkey, groupId: groupId,
                    name: name, isPrivate: isPrivate, isClosed: isClosed,
                    isRestricted: isRestricted, isHidden: isHidden)
                _ = await pool.publishWithAuthRetry(edit, to: trimmedRelay)
            } catch {}
        }

        await publishGroupList()
        return .success(optimisticRoom)
    }

    // MARK: - Join

    func joinGroup(inviteLink: String) async -> Result<Void, JoinError> {
        guard let parsed = Nip29.parseInviteLink(inviteLink) else {
            lastJoinError = .invalidLink
            return .failure(.invalidLink)
        }
        return await joinGroup(relayUrl: parsed.relayUrl, groupId: parsed.groupId, code: parsed.code)
    }

    func joinGroup(relayUrl: String, groupId: String, code: String? = nil) async -> Result<Void, JoinError> {
        let normalized = normalizeRelay(relayUrl)
        if let existing = repository.getRoom(relayUrl: normalized, groupId: groupId), !existing.messages.isEmpty {
            return .success(())
        }
        isJoining = true
        defer { isJoining = false }
        await pool.ensureRelay(normalized, keypair: keypair)

        let priv = Hex.decode(keypair.privkey) ?? Data()
        let event: NostrEvent
        do { event = try Nip29.buildJoinRequest(privkey32: priv, pubkey: keypair.pubkey,
                                                groupId: groupId, inviteCode: code) }
        catch { lastJoinError = .network; return .failure(.network) }

        let result = await pool.publishWithAuthRetry(event, to: normalized)
        switch result {
        case .ok, .duplicate, .timeout:
            await commitJoin(relayUrl: normalized, groupId: groupId)
            return .success(())
        case .rejected(let msg):
            // Some private relays reply with `auth-required:` as a rejection text — covered above.
            lastJoinError = .rejected(message: msg)
            // If we held a relay open just for this attempt, release it.
            await releaseRelayIfUnused(normalized)
            return .failure(.rejected(message: msg))
        case .authRequired:
            lastJoinError = .authRequired
            await releaseRelayIfUnused(normalized)
            return .failure(.authRequired)
        case .network:
            lastJoinError = .network
            await releaseRelayIfUnused(normalized)
            return .failure(.network)
        }
    }

    /// Used when kind-10009 sync surfaces a group we don't yet know about (other-device join).
    func silentJoin(relayUrl: String, groupId: String, name: String? = nil) async {
        let normalized = normalizeRelay(relayUrl)
        if repository.getRoom(relayUrl: normalized, groupId: groupId) != nil { return }
        _ = repository.addGroup(relayUrl: normalized, groupId: groupId, name: name)
        await ensureRelayAndSubscribe(relayUrl: normalized, groupId: groupId)
    }

    private func commitJoin(relayUrl: String, groupId: String) async {
        _ = repository.addGroup(relayUrl: relayUrl, groupId: groupId)
        subscribeToGroup(relayUrl: relayUrl, groupId: groupId)
        await publishGroupList()
        // Re-fire REQs after 2s to handle relays that closed pre-membership REQs
        // with `restricted: not a member`.
        try? await Task.sleep(for: .seconds(2))
        await unsubscribeFromGroup(relayUrl: relayUrl, groupId: groupId)
        await ensureRelayAndSubscribe(relayUrl: relayUrl, groupId: groupId)
    }

    private func releaseRelayIfUnused(_ relayUrl: String) async {
        let stillUsed = repository.joinedGroups.contains { $0.relayUrl == relayUrl }
        if !stillUsed { await pool.releaseRelay(relayUrl) }
    }

    // MARK: - Leave / delete

    func leaveGroup(relayUrl: String, groupId: String) async {
        let priv = Hex.decode(keypair.privkey) ?? Data()
        if let event = try? Nip29.buildLeaveRequest(privkey32: priv, pubkey: keypair.pubkey, groupId: groupId) {
            _ = await pool.publishWithAuthRetry(event, to: relayUrl)
        }
        repository.removeGroup(relayUrl: relayUrl, groupId: groupId)
        await unsubscribeFromGroup(relayUrl: relayUrl, groupId: groupId)
        await publishGroupList()
    }

    func deleteGroup(relayUrl: String, groupId: String) async -> Result<Void, AdminError> {
        let priv = Hex.decode(keypair.privkey) ?? Data()
        guard let event = try? Nip29.buildDeleteGroup(privkey32: priv, pubkey: keypair.pubkey, groupId: groupId) else {
            return .failure(.network)
        }
        let res = await pool.publishWithAuthRetry(event, to: relayUrl)
        switch res {
        case .ok, .duplicate, .timeout:
            repository.removeGroup(relayUrl: relayUrl, groupId: groupId)
            await unsubscribeFromGroup(relayUrl: relayUrl, groupId: groupId)
            await publishGroupList()
            return .success(())
        case .rejected(let msg): return .failure(.rejected(message: msg))
        case .authRequired: return .failure(.notAuthenticated)
        case .network: return .failure(.network)
        }
    }

    // MARK: - Admin actions

    func updateMetadataOnRelay(relayUrl: String, groupId: String,
                               name: String? = nil, about: String? = nil, picture: String? = nil,
                               isPrivate: Bool? = nil, isClosed: Bool? = nil,
                               isRestricted: Bool? = nil, isHidden: Bool? = nil) async -> Result<Void, AdminError> {
        let priv = Hex.decode(keypair.privkey) ?? Data()
        guard let event = try? Nip29.buildEditMetadata(privkey32: priv, pubkey: keypair.pubkey, groupId: groupId,
                                                       name: name, about: about, picture: picture,
                                                       isPrivate: isPrivate, isClosed: isClosed,
                                                       isRestricted: isRestricted, isHidden: isHidden) else {
            return .failure(.network)
        }
        return await runAdmin(event: event, relayUrl: relayUrl)
    }

    func createInvite(relayUrl: String, groupId: String) async -> Result<String, AdminError> {
        let priv = Hex.decode(keypair.privkey) ?? Data()
        let code = Nip29.generateInviteCode()
        guard let event = try? Nip29.buildCreateInvite(privkey32: priv, pubkey: keypair.pubkey,
                                                       groupId: groupId, code: code) else {
            return .failure(.network)
        }
        let res = await runAdmin(event: event, relayUrl: relayUrl)
        switch res {
        case .success: return .success(code)
        case .failure(let e): return .failure(e)
        }
    }

    func putUser(relayUrl: String, groupId: String, targetPubkey: String,
                 roles: [String] = []) async -> Result<Void, AdminError> {
        let priv = Hex.decode(keypair.privkey) ?? Data()
        guard let event = try? Nip29.buildPutUser(privkey32: priv, pubkey: keypair.pubkey,
                                                  groupId: groupId, targetPubkey: targetPubkey, roles: roles) else {
            return .failure(.network)
        }
        return await runAdmin(event: event, relayUrl: relayUrl)
    }

    func removeUser(relayUrl: String, groupId: String, targetPubkey: String) async -> Result<Void, AdminError> {
        let priv = Hex.decode(keypair.privkey) ?? Data()
        guard let event = try? Nip29.buildRemoveUser(privkey32: priv, pubkey: keypair.pubkey,
                                                     groupId: groupId, targetPubkey: targetPubkey) else {
            return .failure(.network)
        }
        return await runAdmin(event: event, relayUrl: relayUrl)
    }

    private func runAdmin(event: NostrEvent, relayUrl: String) async -> Result<Void, AdminError> {
        let res = await pool.publishWithAuthRetry(event, to: relayUrl)
        switch res {
        case .ok, .duplicate, .timeout: return .success(())
        case .rejected(let msg): lastAdminError = .rejected(message: msg); return .failure(.rejected(message: msg))
        case .authRequired: lastAdminError = .notAuthenticated; return .failure(.notAuthenticated)
        case .network: lastAdminError = .network; return .failure(.network)
        }
    }

    // MARK: - Group preview / discovery

    func fetchGroupPreview(relayUrl: String, groupId: String) async -> GroupPreview? {
        let normalized = normalizeRelay(relayUrl)
        let metaFilter = NostrFilter(kinds: [Nip29.kindGroupMetadata], dTags: [groupId])
        let memFilter = NostrFilter(kinds: [Nip29.kindGroupMembers], dTags: [groupId])
        async let metaEvents = RelayPool.query(relays: [normalized], filter: metaFilter, timeout: 6)
        async let memEvents  = RelayPool.query(relays: [normalized], filter: memFilter, timeout: 6)
        let (m, mem) = await (metaEvents, memEvents)
        let metadata = m.first.flatMap { Nip29.parseGroupMetadata($0) }
        let members = mem.first.map { Nip29.parseGroupMembers($0) } ?? []
        if metadata == nil && members.isEmpty { return nil }
        return GroupPreview(metadata: metadata, members: members)
    }

    func discoverGroups() async -> [DiscoveredGroup] {
        let joinedRelays = Set(repository.joinedGroups.map { $0.relayUrl })
        var relayList = [Nip29.defaultGroupRelay]
        relayList.append(contentsOf: joinedRelays)
        relayList = Array(Set(relayList))
        let metaFilter = NostrFilter(kinds: [Nip29.kindGroupMetadata], limit: 200)
        let memFilter = NostrFilter(kinds: [Nip29.kindGroupMembers], limit: 200)

        var byKey: [String: (relay: String, meta: GroupMetadata?, count: Int)] = [:]
        for relay in relayList {
            async let metas = RelayPool.query(relays: [relay], filter: metaFilter, timeout: 6)
            async let mems  = RelayPool.query(relays: [relay], filter: memFilter, timeout: 6)
            let (mList, memList) = await (metas, mems)
            for m in mList {
                guard let metadata = Nip29.parseGroupMetadata(m), !metadata.isHidden else { continue }
                let key = "\(relay)|\(metadata.groupId)"
                var entry = byKey[key] ?? (relay, nil, 0)
                entry.meta = metadata
                byKey[key] = entry
            }
            for m in memList {
                guard let groupId = m.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1] else { continue }
                let count = Nip29.parseGroupMembers(m).count
                let key = "\(relay)|\(groupId)"
                var entry = byKey[key] ?? (relay, nil, 0)
                entry.count = max(entry.count, count)
                byKey[key] = entry
            }
        }

        let joinedKeys = Set(repository.joinedGroups.map { "\($0.relayUrl)|\($0.groupId)" })
        return byKey.compactMap { (key, entry) -> DiscoveredGroup? in
            guard let metadata = entry.meta, !joinedKeys.contains(key) else { return nil }
            return DiscoveredGroup(relayUrl: entry.relay, metadata: metadata, memberCount: entry.count)
        }.sorted { $0.memberCount > $1.memberCount }
    }

    // MARK: - kind-10009 publish/sync

    func publishGroupList() async {
        let entries: [Nip51Groups.SimpleGroupEntry] = repository.joinedGroups.map {
            Nip51Groups.SimpleGroupEntry(groupId: $0.groupId, relayUrl: $0.relayUrl, name: $0.metadata?.name)
        }
        let tags = Nip51Groups.buildTags(from: entries)
        let priv = Hex.decode(keypair.privkey) ?? Data()
        guard let event = try? NostrEvent.sign(privkey32: priv, pubkey: keypair.pubkey,
                                               kind: Nip51Groups.kindSimpleGroups,
                                               createdAt: Int(Date().timeIntervalSince1970),
                                               tags: tags, content: "") else { return }

        // Publish to: known group relays + chat.wisp.talk + indexers (best-effort).
        var targets = Set<String>(Self.listLookupRelays)
        targets.insert(Nip29.defaultGroupRelay)
        for room in repository.joinedGroups { targets.insert(room.relayUrl) }
        // Top write relays from the score board.
        if let board = RelayScoreBoard.load(pubkey: keypair.pubkey) {
            for entry in board.scoredRelays.prefix(10) { targets.insert(entry.url) }
        }
        _ = await RelayPool.publish(event: event, to: Array(targets))
    }

    private func syncFromRemoteGroupList() async {
        let filter = NostrFilter(kinds: [Nip51Groups.kindSimpleGroups],
                                 authors: [keypair.pubkey], limit: 1)
        let events = await RelayPool.query(relays: Self.listLookupRelays, filter: filter, timeout: 6)
        guard let latest = events.max(by: { $0.createdAt < $1.createdAt }) else { return }
        let entries = Nip51Groups.parse(latest)
        for entry in entries {
            if repository.getRoom(relayUrl: entry.relayUrl, groupId: entry.groupId) == nil {
                await silentJoin(relayUrl: entry.relayUrl, groupId: entry.groupId, name: entry.name)
            }
        }
    }

    // MARK: - Profiles

    /// Cache of profiles already in flight so we don't double-query.
    @ObservationIgnored private var profileFetchInFlight: Set<String> = []

    /// Fetch a kind-0 for `pubkey` from indexer relays if we don't already have one cached.
    /// Triggers a UI refresh of `repository.joinedGroups` (no-op if profile already known).
    func requestProfileIfNeeded(_ pubkey: String) async {
        if ProfileRepository.shared.get(pubkey) != nil { return }
        if profileFetchInFlight.contains(pubkey) { return }
        profileFetchInFlight.insert(pubkey)
        defer { profileFetchInFlight.remove(pubkey) }
        let filter = NostrFilter(kinds: [0], authors: [pubkey], limit: 5)
        let events = await RelayPool.query(relays: Self.listLookupRelays, filter: filter, timeout: 6)
        if let best = events.filter({ $0.kind == 0 }).max(by: { $0.createdAt < $1.createdAt }) {
            _ = ProfileRepository.shared.updateFromEvent(best)
        }
    }

    // MARK: - Helpers

    private func normalizeRelay(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        if !s.hasPrefix("wss://") && !s.hasPrefix("ws://") { s = "wss://" + s }
        return s
    }
}

