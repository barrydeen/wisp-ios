import SwiftUI

struct SidebarDrawerView: View {
    let profile: ProfileData?
    let keypair: Keypair
    let onClose: () -> Void
    /// Whether the drawer is currently presented. The mini-wallet widget keys
    /// its balance refresh off this so a wallet the user never opens doesn't
    /// spin up its relay socket / SDK at app launch.
    var isVisible: Bool = false
    private var pubkey: String { keypair.pubkey }
    let onSelectTab: (BottomTab) -> Void
    let onLogout: () -> Void
    var onSwitchAccount: (Keypair) -> Void = { _ in }
    var onAddAccount: () -> Void = {}
    var onOpenProfile: () -> Void = {}
    /// Route to another user's profile by hex pubkey — used when the QR sheet
    /// scans someone else's Nostr QR.
    var onOpenProfileByPubkey: (String) -> Void = { _ in }
    var onOpenInterface: () -> Void = {}
    var onOpenKeys: () -> Void = {}
    var onOpenDraftsScheduled: () -> Void = {}
    var onOpenCustomEmojis: () -> Void = {}
    var onOpenLists: () -> Void = {}
    var onOpenPolls: () -> Void = {}
    var onOpenHashtagSets: () -> Void = {}
    var onOpenSocialGraph: () -> Void = {}
    var onOpenSafety: () -> Void = {}
    var onOpenProofOfWork: () -> Void = {}
    var onOpenRelays: () -> Void = {}
    var onOpenMediaServers: () -> Void = {}

    @Environment(AppSettings.self) private var settings
    @Environment(WalletStore.self) private var walletStore

    @State private var settingsExpanded = false
    @State private var showAccountSwitcher = false
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
        Nip19.shortNpub(hex: pubkey)
    }
    private var npub: String {
        if let data = Hex.decode(pubkey), let s = Nip19.npubEncode(pubkey: Array(data)) {
            return s
        }
        return pubkey
    }
    private var subtitleText: String {
        if let nip05 = profile?.nip05, !nip05.isEmpty { return nip05.nip05DisplayString }
        return String(npub.prefix(16)) + "\u{2026}"
    }
    private var versionString: String {
        let v = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0"
        return "wisp v\(v)"
    }
    private var accounts: [String] {
        var list = NostrKey.accounts()
        if !list.contains(pubkey) { list.insert(pubkey, at: 0) }
        return list
    }

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
        var relays = await RelayListRepository.shared.getWriteRelays(pubkey)
        if relays.isEmpty { relays = await RelayListRepository.shared.getReadRelays(pubkey) }
        if relays.isEmpty { return }
        let filter = NostrFilter(
            kinds: [Nip38.kindUserStatus],
            authors: [pubkey],
            dTags: [Nip38.dTagGeneral],
            limit: 1
        )
        let events = await RelayPool.query(relays: relays, filter: filter, timeout: 6)
        guard let latest = events.max(by: { $0.createdAt < $1.createdAt }) else { return }
        let trimmed = latest.content.trimmingCharacters(in: .whitespacesAndNewlines)
        userStatus = trimmed.isEmpty ? nil : trimmed
    }

    private func publishStatus(_ content: String) async {
        guard let priv = Hex.decode(keypair.privkey) else { return }
        guard let event = try? Nip38.buildStatus(privkey32: priv, pubkey: pubkey, content: content) else { return }
        var relays = await RelayListRepository.shared.getWriteRelays(pubkey)
        if relays.isEmpty { relays = ["wss://relay.damus.io", "wss://relay.primal.net"] }
        _ = await RelayPool.publish(event: event, to: relays, timeout: 6)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.wispBackground.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        headerSection
                            .padding(.top, 16)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)

                        if !keypair.isWatchOnly {
                            SidebarMiniWalletView(keypair: keypair) {
                                onSelectTab(.wallet)
                            }
                        }

                        DrawerRow(icon: "person", label: "My Profile") {
                            onOpenProfile()
                        }

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
                .onChange(of: settingsExpanded) { _, expanded in
                    if expanded {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            withAnimation {
                                proxy.scrollTo("settingsBottom", anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .alert("Logout", isPresented: $showLogoutConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Logout", role: .destructive) { onLogout() }
        } message: {
            if keypair.isWatchOnly {
                Text("Sign back in with your npub anytime to resume watching this account.")
            } else if hasEmbeddedWallet {
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
            await loadStatus()
        }
        .task(id: isVisible) {
            // Bring the configured wallet up (and refresh its balance) when
            // the drawer opens, so the widget's figure is live rather than
            // only as fresh as the last wallet-tab visit. `startIfConfigured`
            // is idempotent — an already-connected wallet just gets a
            // balance/transaction refresh.
            guard isVisible, !keypair.isWatchOnly else { return }
            await walletStore.startIfConfigured()
        }
        .sheet(isPresented: $showQRSheet) {
            ProfileQrSheet(
                pubkey: pubkey,
                displayName: displayName,
                avatarUrl: profile?.picture,
                lud16: profile?.lud16,
                onOpenProfile: onOpenProfileByPubkey
            )
        }
        .sheet(isPresented: $showAccountSwitcher) {
            AccountSwitcherSheet(
                initialAccounts: accounts,
                activePubkey: pubkey,
                activeProfile: profile,
                onSwitchAccount: onSwitchAccount,
                onAddAccount: onAddAccount
            )
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Button(action: handleAvatarTap) {
                    CachedAvatarView(url: profile?.picture, size: 64, alwaysLoad: true)
                }
                .buttonStyle(.plain)

            // Icon-only affordance that opens the account switcher sheet. Same
            // action (switch or add an account) regardless of how many
            // accounts are signed in; shows a "+N" badge counting the other
            // accounts when more than one is signed in.
            let otherCount = accounts.count - 1
            Button {
                showAccountSwitcher = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.2")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                    if otherCount > 0 {
                        Text("+\(otherCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.wispSurfaceVariant, in: Capsule())
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
                    .buttonStyle(.plain)

                    Button {
                        @Bindable var s = settings
                        s.colorScheme = (settings.colorScheme == .dark) ? .light : .dark
                    } label: {
                        Image(systemName: settings.colorScheme == .dark ? "moon.fill" : "sun.max.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showQRSheet = true
                    } label: {
                        Image(systemName: "qrcode")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
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

                }

                Text(subtitleText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !keypair.isWatchOnly {
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

    // MARK: - Primary items

    private var primaryItems: some View {
        VStack(spacing: 0) {
            DrawerRow(icon: "house", label: "Feeds") {
                onSelectTab(.home)
            }
            DrawerRow(icon: "magnifyingglass", label: "Search") {
                onSelectTab(.search)
            }
            if !keypair.isWatchOnly {
                DrawerRow(icon: "envelope", label: "Messages") {
                    onSelectTab(.messages)
                }
                // Wallet lives in the mini-wallet widget near the top of the
                // drawer now.
            }
            DrawerRow(icon: "list.bullet", label: "Lists") {
                onOpenLists()
            }
            DrawerRow(icon: "chart.bar", label: "My Polls") {
                onOpenPolls()
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
            // DrawerRow(icon: "heart", label: "Relay Health", indented: true) { onClose() }
            // DrawerRow(icon: "ladybug", label: "Console", indented: true) { onClose() }
            Color.clear.frame(height: 1).id("settingsBottom")
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

// MARK: - Mini wallet widget

/// Compact live-balance card replacing the Wallet row in the drawer menu.
/// Shows the active wallet's balance (compacted to "1.2M"-style once the
/// grouped number gets long), a hide/show toggle that shares the wallet
/// dashboard's per-pubkey hidden state, and a "Set up wallet" call-to-action
/// when no wallet is configured. Tapping the card opens the wallet tab.
private struct SidebarMiniWalletView: View {
    let keypair: Keypair
    let onSelectWallet: () -> Void

    @Environment(WalletStore.self) private var store
    /// Same key the wallet dashboard's balance display uses, so hiding here
    /// hides there and vice versa.
    @AppStorage private var balanceDisplayRaw: String
    /// Display mode to restore when un-hiding, so a fiat-mode dashboard isn't
    /// reset to sats by the toggle.
    @AppStorage private var unhideDisplayRaw: String

    private static let unhideKeyPrefix = "walletBalanceDisplayRestore_"

    init(keypair: Keypair, onSelectWallet: @escaping () -> Void) {
        self.keypair = keypair
        self.onSelectWallet = onSelectWallet
        _balanceDisplayRaw = AppStorage(
            wrappedValue: WalletBalanceDisplayMode.sats.rawValue,
            WalletBalanceDisplayMode.storageKey(pubkey: keypair.pubkey)
        )
        _unhideDisplayRaw = AppStorage(
            wrappedValue: WalletBalanceDisplayMode.sats.rawValue,
            Self.unhideKeyPrefix + keypair.pubkey
        )
    }

    private var displayMode: WalletBalanceDisplayMode {
        WalletBalanceDisplayMode(rawValue: balanceDisplayRaw) ?? .sats
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "creditcard")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            content

            Spacer(minLength: 8)

            if store.mode != nil {
                hideToggleButton
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        // Same leading/trailing padding as `DrawerRow` so the icon and label
        // line up with the rest of the menu; the edge-to-edge background
        // stripe is what sets the widget apart.
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurfaceVariant.opacity(0.5))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelectWallet)
    }

    @ViewBuilder private var content: some View {
        if store.mode == nil {
            // No wallet configured — the whole card acts as the setup button.
            Text("Set up wallet")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.primary)
        } else {
            balanceLine
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.25), value: store.balanceMsats)
        }
    }

    /// One `Text` so VoiceOver reads the figure as a unit. Compacts long
    /// balances ("1,234,567 sats" → "1.2M sats") to keep the card on one
    /// line; fiat mode renders the converted amount when a rate is cached.
    private var balanceLine: Text {
        if displayMode == .hidden {
            return Text("* * * * *")
        }
        guard let msats = store.balanceMsats else {
            // Never render an unknown balance as "0" — see the matching
            // comment in `WalletView.balanceCard`.
            return Text("…")
        }
        let sats = msats / 1000
        // The wallet-scoped FIAT display mode renders the converted amount
        // when a rate is cached; the unit display is the fallback — same as
        // the dashboard's balance card.
        if displayMode == .fiat, let fiat = CurrencyFormatter.walletFiat(sats: sats) {
            return Text(fiat)
        }
        let number = sats >= 1_000_000
            ? CurrencyFormatter.formatSatsShort(sats)
            : CurrencyFormatter.formatNumber(sats)
        return Text("\(number) sats")
    }

    private var hideToggleButton: some View {
        Button {
            toggleHidden()
        } label: {
            Image(systemName: displayMode == .hidden ? "eye" : "eye.slash")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(displayMode == .hidden ? "Show balance" : "Hide balance")
    }

    private func toggleHidden() {
        if displayMode == .hidden {
            balanceDisplayRaw = (unhideDisplayRaw == WalletBalanceDisplayMode.hidden.rawValue)
                ? WalletBalanceDisplayMode.sats.rawValue
                : unhideDisplayRaw
        } else {
            unhideDisplayRaw = balanceDisplayRaw
            balanceDisplayRaw = WalletBalanceDisplayMode.hidden.rawValue
        }
    }
}
