import SwiftUI

struct SidebarDrawerView: View {
    let profile: ProfileData?
    let keypair: Keypair
    let onClose: () -> Void
    private var pubkey: String { keypair.pubkey }
    let onSelectTab: (BottomTab) -> Void
    let onLogout: () -> Void
    var onOpenProfile: () -> Void = {}
    var onOpenInterface: () -> Void = {}
    var onOpenKeys: () -> Void = {}
    var onOpenDraftsScheduled: () -> Void = {}
    var onOpenCustomEmojis: () -> Void = {}
    var onOpenLists: () -> Void = {}
    var onOpenHashtagSets: () -> Void = {}
    var onOpenSocialGraph: () -> Void = {}
    var onOpenSafety: () -> Void = {}
    var onOpenProofOfWork: () -> Void = {}
    var onOpenRelays: () -> Void = {}
    var onOpenMediaServers: () -> Void = {}

    @Environment(AppSettings.self) private var settings

    @State private var settingsExpanded = false
    @State private var accountsExpanded = false
    @State private var showLogoutConfirm = false
    @State private var showQRSheet = false
    @State private var showStatusEditor = false
    @State private var statusDraft = ""
    @State private var userStatus: String? = nil
    @State private var torEnabled = false
    @State private var avatarTapCount = 0
    @State private var avatarTapResetTask: Task<Void, Never>?

    private var hasEmbeddedWallet: Bool { false }
    private var displayName: String { profile?.displayString ?? truncatedPubkey }
    private var truncatedPubkey: String {
        String(pubkey.prefix(8)) + "\u{2026}"
    }
    private var npub: String {
        if let data = Hex.decode(pubkey), let s = Nip19.npubEncode(pubkey: Array(data)) {
            return s
        }
        return pubkey
    }
    private var subtitleText: String {
        if let nip05 = profile?.nip05, !nip05.isEmpty { return nip05 }
        return String(npub.prefix(16)) + "\u{2026}"
    }
    private var versionString: String {
        let v = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0"
        return "wisp v\(v)"
    }
    private var accounts: [String] { NostrKey.accounts() }

    private static func cachedStatusKey(_ pubkey: String) -> String {
        "user_status_general_\(pubkey)"
    }

    /// Restore the last-seen status from UserDefaults so the drawer never
    /// flashes the empty placeholder when a relay query is in flight or
    /// fails. Refreshed in the background by `loadStatus()`.
    private func loadCachedStatus() {
        let cached = UserDefaults.standard.string(forKey: Self.cachedStatusKey(pubkey))
        if let cached, !cached.isEmpty { userStatus = cached }
    }

    private func loadStatus() async {
        // Query write ∪ read ∪ top-scored relays in one shot. The previous
        // write-then-read fallback missed statuses published from a different
        // client whose relay set didn't intersect the current cache.
        var relays = Set<String>()
        for r in await RelayListRepository.shared.getWriteRelays(pubkey) { relays.insert(r) }
        for r in await RelayListRepository.shared.getReadRelays(pubkey) { relays.insert(r) }
        if let board = RelayScoreBoard.load(pubkey: pubkey) {
            for r in board.scoredRelays.prefix(5) { relays.insert(r.url) }
        }
        if relays.isEmpty {
            relays = ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
        }
        let filter = NostrFilter(
            kinds: [Nip38.kindUserStatus],
            authors: [pubkey],
            dTags: [Nip38.dTagGeneral],
            limit: 1
        )
        let events = await RelayPool.query(relays: Array(relays), filter: filter, timeout: 10)
        guard let latest = events.max(by: { $0.createdAt < $1.createdAt }) else { return }
        let trimmed = latest.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: String? = trimmed.isEmpty ? nil : trimmed
        userStatus = resolved
        let defaults = UserDefaults.standard
        if let resolved {
            defaults.set(resolved, forKey: Self.cachedStatusKey(pubkey))
        } else {
            defaults.removeObject(forKey: Self.cachedStatusKey(pubkey))
        }
    }

    private func publishStatus(_ content: String) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = UserDefaults.standard
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Self.cachedStatusKey(pubkey))
        } else {
            defaults.set(trimmed, forKey: Self.cachedStatusKey(pubkey))
        }
        guard let priv = Hex.decode(keypair.privkey) else { return }
        guard let event = try? Nip38.buildStatus(privkey32: priv, pubkey: pubkey, content: content) else { return }
        var relays = await RelayListRepository.shared.getWriteRelays(pubkey)
        if relays.isEmpty { relays = ["wss://relay.damus.io", "wss://relay.primal.net"] }
        _ = await RelayPool.publish(event: event, to: relays, timeout: 6)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.wispBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    headerSection
                        .padding(.top, 16)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)

                    if accountsExpanded {
                        accountPickerSection
                            .transition(.opacity)
                    }

                    Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
                        .padding(.bottom, 8)

                    primaryItems

                    if settingsExpanded {
                        settingsItems
                            .transition(.opacity)
                    }

                    Spacer(minLength: 16)

                    Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
                        .padding(.vertical, 8)

                    logoutButton

                    versionFooter
                        .padding(.top, 16)
                        .padding(.bottom, 24)
                }
            }
        }
        .alert("Logout", isPresented: $showLogoutConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Logout", role: .destructive) { onLogout() }
        } message: {
            if hasEmbeddedWallet {
                Text("Back up your private key before logging out. Without it, your Nostr account cannot be recovered.\n\nBack up your wallet recovery phrase. Without it, your funds cannot be recovered.")
            } else {
                Text("Back up your private key before logging out. Without it, your Nostr account cannot be recovered.")
            }
        }
        .alert("Update Status", isPresented: $showStatusEditor) {
            TextField("What are you up to?", text: $statusDraft)
            Button("Cancel", role: .cancel) {}
            Button("Update") {
                let trimmed = statusDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let newStatus = trimmed.isEmpty ? nil : trimmed
                userStatus = newStatus
                Task { await publishStatus(newStatus ?? "") }
            }
        }
        .task(id: pubkey) {
            // Show the last-seen status immediately from cache, then refresh
            // from relays in the background. Avoids "Set status..." flashing
            // when relay reads are slow or transiently empty.
            loadCachedStatus()
            await loadStatus()
        }
        .sheet(isPresented: $showQRSheet) {
            ProfileQrSheet(
                pubkey: pubkey,
                displayName: displayName,
                avatarUrl: profile?.picture,
                lud16: profile?.lud16
            )
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Button(action: handleAvatarTap) {
                    CachedAvatarView(url: profile?.picture, size: 64, alwaysLoad: true)
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 4) {
                    Button {
                        torEnabled.toggle()
                    } label: {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 20))
                            .foregroundStyle(torEnabled ? Color.wispPrimary : .secondary.opacity(0.5))
                            .frame(width: 36, height: 36)
                    }

                    Button {
                        @Bindable var s = settings
                        s.colorScheme = (settings.colorScheme == .dark) ? .light : .dark
                    } label: {
                        Image(systemName: settings.colorScheme == .dark ? "moon.fill" : "sun.max.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                    }

                    Button {
                        showQRSheet = true
                    } label: {
                        Image(systemName: "qrcode")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    EmojiText(
                        displayName,
                        emojiMap: profile?.emojiMap ?? [:],
                        textStyle: .body,
                        weight: .semibold,
                        color: .label,
                        lineLimit: 1
                    )

                    Button {
                        accountsExpanded.toggle()
                    } label: {
                        Image(systemName: accountsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(subtitleText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button {
                statusDraft = userStatus ?? ""
                showStatusEditor = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                        .font(.system(size: userStatus == nil ? 14 : 12))
                        .foregroundStyle(.secondary)
                    Text(userStatus ?? "Set status\u{2026}")
                        .font(.system(size: 12).italic())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func handleAvatarTap() {
        avatarTapCount += 1
        if avatarTapCount >= 7 {
            fatalError("Test crash")
        }
        avatarTapResetTask?.cancel()
        avatarTapResetTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled {
                avatarTapCount = 0
            }
        }
    }

    // MARK: - Account picker

    private var accountPickerSection: some View {
        VStack(spacing: 0) {
            ForEach(accounts, id: \.self) { acctPubkey in
                Button {
                    accountsExpanded = false
                } label: {
                    HStack(spacing: 12) {
                        CachedAvatarView(url: nil, size: 32)
                        Text(String(acctPubkey.prefix(12)) + "\u{2026}")
                            .font(.system(size: 14))
                            .foregroundStyle(.primary)
                        Spacer()
                        if acctPubkey == pubkey {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.wispPrimary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button {
                accountsExpanded = false
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                    Text("Add Account")
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Primary items

    private var primaryItems: some View {
        VStack(spacing: 0) {
            DrawerRow(icon: "person", label: "My Profile") {
                onOpenProfile()
            }
            DrawerRow(icon: "house", label: "Feeds") {
                onSelectTab(.home)
            }
            DrawerRow(icon: "magnifyingglass", label: "Search") {
                onSelectTab(.search)
            }
            DrawerRow(icon: "envelope", label: "Messages") {
                onSelectTab(.messages)
            }
            DrawerRow(icon: "bolt.fill", label: "Wallet") {
                onSelectTab(.wallet)
            }
            DrawerRow(icon: "list.bullet", label: "Lists") {
                onOpenLists()
            }
            DrawerRow(icon: "number.square", label: "Hashtag Sets") {
                onOpenHashtagSets()
            }
            DrawerRow(icon: "pencil", label: "Drafts & Scheduled") {
                onOpenDraftsScheduled()
            }
            DrawerRow(
                icon: "gearshape",
                label: "Settings",
                trailingChevron: settingsExpanded ? .expanded : .collapsed
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    settingsExpanded.toggle()
                }
            }
        }
    }

    // MARK: - Settings items

    private var settingsItems: some View {
        VStack(spacing: 0) {
            DrawerRow(icon: "paintbrush", label: "Interface", indented: true) {
                onOpenInterface()
            }
            DrawerRow(icon: "server.rack", label: "Relays", indented: true) { onOpenRelays() }
            DrawerRow(icon: "cloud", label: "Media Servers", indented: true) { onOpenMediaServers() }
            DrawerRow(icon: "key", label: "Keys", indented: true) { onOpenKeys() }
            DrawerRow(icon: "hand.raised", label: "Safety", indented: true) { onOpenSafety() }
            DrawerRow(icon: "shield", label: "Proof of Work", indented: true) { onOpenProofOfWork() }
            DrawerRow(icon: "point.3.connected.trianglepath.dotted", label: "Social Graph", indented: true) { onOpenSocialGraph() }
            DrawerRow(icon: "face.smiling", label: "Custom Emojis", indented: true) {
                onOpenCustomEmojis()
            }
            DrawerRow(icon: "heart", label: "Relay Health", indented: true) { onClose() }
            DrawerRow(icon: "ladybug", label: "Console", indented: true) { onClose() }
        }
    }

    // MARK: - Logout & version

    private var logoutButton: some View {
        DrawerRow(
            icon: "rectangle.portrait.and.arrow.right",
            label: "Logout",
            tint: .red
        ) {
            showLogoutConfirm = true
        }
    }

    private var versionFooter: some View {
        HStack(spacing: 6) {
            Image("WispLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .opacity(0.3)
            Text(versionString)
                .font(.system(size: 11))
                .foregroundStyle(.secondary.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

}
