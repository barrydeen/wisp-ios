import SwiftUI

struct MainView: View {
    let keypair: Keypair
    let onLogout: () -> Void
    var onSwitchAccount: (Keypair) -> Void = { _ in }
    @State private var viewModel: FeedViewModel
    @State private var messagesVM: MessagesViewModel
    @State private var notificationsVM: NotificationsViewModel
    @State private var groupListVM: GroupListViewModel
    @State private var searchVM: SearchViewModel
    @State private var walletStore: WalletStore
    @State private var selectedTab: BottomTab = .home
    @State private var feedPath = NavigationPath()
    @State private var placeholderPath = NavigationPath()
    @State private var notificationsPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    /// Per-tab side-channel mirroring the eventIds of any ThreadRoute pushes on
    /// the matching path, in stack order. Lets ThreadView smart-pop back to an
    /// already-visited ancestor instead of pushing a duplicate. Maintained by
    /// ThreadView's `.task` (append) + `.onDisappear` (remove-tail).
    @State private var feedThreadChain: [String] = []
    @State private var placeholderThreadChain: [String] = []
    @State private var notificationsThreadChain: [String] = []
    @State private var searchThreadChain: [String] = []
    @State private var drawerOpen = false
    @State private var drawerDragOffset: CGFloat = 0
    @State private var engagementRepo = EngagementRepository.shared
    @State private var liveStreamRepo = LiveStreamRepository.shared
    @State private var showInterfaceSettings = false
    @State private var showKeys = false
    @State private var showCustomEmojis = false
    @State private var showHashtagSets = false
    @State private var showLists = false
    @State private var showCompose = false
    @State private var showDraftsScheduled = false
    @State private var showRelayPicker = false
    @State private var showOnlineSheet = false
    @State private var showSocialGraph = false
    @State private var showSafety = false
    @State private var showProofOfWork = false
    @State private var showMediaServers = false
    @State private var hashtagSetRepo = HashtagSetRepository.shared
    @Environment(AudioPlayerStore.self) private var audioPlayer
    @State private var showRelaySettings = false
    @State private var pendingAuthRequest: PendingAuthRequest?
    @State private var feedFabOpacity: Double = 1.0
    /// Shared toast store — written to by every `ComposeView` autosave-on-dismiss
    /// (new / reply / quote alike). Watched here so the orange pill renders no
    /// matter which navigation surface presented the composer.
    @State private var draftToast = DraftSavedToastStore.shared
    @State private var draftSavedToastTask: Task<Void, Never>?
    /// Set to reopen the composer pointed at an existing draft (populated by
    /// the draft-saved toast tap). Separate from `showCompose` so SwiftUI
    /// mounts a fresh `ComposeView` keyed off the draft's dTag.
    @State private var reopenDraft: Nip37.Draft?
    /// Bumped from `popToRoot(.home)` so the feed `ScrollViewReader` can scroll
    /// to the top anchor. Tap-on-active-tab clears the nav stack first; on a
    /// subsequent tap (when the stack is already empty) it animates to the top.
    @State private var feedScrollToTopTrigger: Int = 0

    private let drawerWidth: CGFloat = 320

    var onAddAccount: () -> Void = {}

    init(keypair: Keypair, onLogout: @escaping () -> Void = {}, onSwitchAccount: @escaping (Keypair) -> Void = { _ in }, onAddAccount: @escaping () -> Void = {}) {
        self.keypair = keypair
        self.onLogout = onLogout
        self.onSwitchAccount = onSwitchAccount
        self.onAddAccount = onAddAccount
        _viewModel = State(initialValue: FeedViewModel(keypair: keypair))
        _messagesVM = State(initialValue: MessagesViewModel(keypair: keypair))
        _notificationsVM = State(initialValue: NotificationsViewModel(keypair: keypair))
        _groupListVM = State(initialValue: GroupListViewModel(keypair: keypair))
        _searchVM = State(initialValue: SearchViewModel(keypair: keypair))
        _walletStore = State(initialValue: WalletStore(keypair: keypair))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            mainShell

            if let draft = draftToast.pendingDraft {
                draftSavedPill(draft: draft)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }

            if drawerOpen {
                Color.black
                    .opacity(0.4)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { closeDrawer() }
            }

            SidebarDrawerView(
                profile: viewModel.userProfile,
                keypair: keypair,
                onClose: { closeDrawer() },
                onSelectTab: { tab in
                    selectedTab = tab
                    closeDrawer()
                },
                onLogout: {
                    closeDrawer()
                    Task {
                        // Multi-account branch: when another saved account
                        // exists, only delete the current account's keychain
                        // + per-pubkey UserDefaults + NIP-46 session and hand
                        // off to the next account. The full `AppDataWipe`
                        // path was throwing every saved account out of the
                        // app, forcing a multi-account user back through the
                        // splash login / signup flow on every logout.
                        let currentPubkey = keypair.pubkey
                        let nextPubkey = NostrKey.accounts().first { $0 != currentPubkey }
                        if let nextPubkey, let nextKp = NostrKey.switchAccount(pubkey: nextPubkey) {
                            NostrKey.deleteAccount(pubkey: currentPubkey)
                            await Nip46Manager.shared.clearActive()
                            onSwitchAccount(nextKp)
                        } else {
                            await AppDataWipe.wipeEverything()
                            onLogout()
                        }
                    }
                },
                onSwitchAccount: { newKeypair in
                    closeDrawer()
                    onSwitchAccount(newKeypair)
                },
                onAddAccount: {
                    closeDrawer()
                    onAddAccount()
                },
                onOpenProfile: {
                    closeDrawer()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(280))
                        selectedTab = .home
                        feedPath.append(ProfileRoute(pubkey: keypair.pubkey))
                    }
                },
                onOpenInterface: {
                    closeDrawer()
                    showInterfaceSettings = true
                },
                onOpenKeys: {
                    closeDrawer()
                    showKeys = true
                },
                onOpenDraftsScheduled: {
                    closeDrawer()
                    showDraftsScheduled = true
                },
                onOpenCustomEmojis: {
                    closeDrawer()
                    showCustomEmojis = true
                },
                onOpenLists: {
                    closeDrawer()
                    showLists = true
                },
                onOpenHashtagSets: {
                    closeDrawer()
                    showHashtagSets = true
                },
                onOpenSocialGraph: {
                    closeDrawer()
                    showSocialGraph = true
                },
                onOpenSafety: {
                    closeDrawer()
                    showSafety = true
                },
                onOpenProofOfWork: {
                    closeDrawer()
                    showProofOfWork = true
                },
                onOpenRelays: {
                    closeDrawer()
                    showRelaySettings = true
                },
                onOpenMediaServers: {
                    closeDrawer()
                    showMediaServers = true
                }
            )
            .frame(width: drawerWidth)
            .frame(maxHeight: .infinity)
            .background(Color.wispBackground)
            .offset(x: drawerOpen ? drawerDragOffset : -drawerWidth)
            .animation(.smooth(duration: 0.25), value: drawerOpen)
            .gesture(drawerDragGesture)
        }
        .background(Color.wispBackground)
        .environment(walletStore)
        .onReceive(NotificationCenter.default.publisher(for: .openWalletTab)) { _ in
            // PostCardView posts this when the user tries to zap without
            // a configured wallet and chooses "Set Up Wallet" on the
            // resulting prompt — switch to the wallet tab so they land on
            // the setup UI directly.
            selectedTab = .wallet
        }
        .task {
            GroupListViewModelRegistry.register(groupListVM)

            // NIP-42 AUTH wiring. Set the static hooks before any RelayPool call so
            // pre-approved relays auto-sign their challenges. The approval check reads
            // UserDefaults directly (thread-safe, callable from socket task contexts);
            // the signer captures the active keypair via closure.
            let activeKeypair = keypair
            let activePubkey = keypair.pubkey
            RelayPool.authApprovalCheck = { url in
                RelaySettingsRepository.isAuthApproved(url, pubkey: activePubkey)
            }
            RelayPool.authSigner = { url, challenge in
                try? Nip42.buildAuthEvent(challenge: challenge, relayUrl: url, keypair: activeKeypair)
            }

            // Drain pending AUTH challenges into the approval sheet state.
            Task { @MainActor in
                for await req in RelayPool.pendingAuth {
                    if pendingAuthRequest == nil {
                        pendingAuthRequest = req
                    }
                }
            }

            // Safety bootstrap — bind the per-account stores, rebuild the lockless filter
            // snapshot, then kick the off-main work (NSpam warmup, mute sync, optional WoT
            // recompute). All four ingest paths consult the snapshot lockless on every event,
            // so this must run before any subscription opens.
            let privkey32 = Hex.decode(keypair.privkey)
            MuteRepository.shared.bind(
                activePubkey: keypair.pubkey,
                privkey32: privkey32,
                keypair: keypair
            )
            SafetyPreferences.shared.bind(activePubkey: keypair.pubkey)
            await ExtendedNetworkRepository.shared.bind(activePubkey: keypair.pubkey)
            await SafetyFilter.shared.rebuildSnapshot()
            Task.detached { try? await SpamScorer.shared.warmUp() }
            // Background fetcher for kind-0 profiles whose pubkey we've seen
            // but haven't cached. Hooks into EventPersistQueue, EngagementRepository,
            // and individual VMs (which call observe / observePubkeys); also runs
            // a periodic sweep over registered event sources at 3s/8s/15s/120s.
            MissingProfileWatcher.shared.start(activePubkey: keypair.pubkey)
            if let priv = privkey32 {
                MuteRepository.shared.startSync(privkey32: priv)
            }
            Task.detached(priority: .utility) {
                if await SafetyPreferences.shared.wotFilterEnabled,
                   await ExtendedNetworkRepository.shared.isStale() {
                    await ExtendedNetworkRepository.shared.recompute()
                }
            }

            // Run all VM startups concurrently — sequential awaits made notifications wait
            // ~5-8s for feed + messages to finish their relay round trips before even opening
            // a single websocket of their own.
            async let feed: Void = viewModel.start()
            async let messages: Void = messagesVM.start()
            async let notifications: Void = notificationsVM.start()
            async let groups: Void = groupListVM.start()
            async let emoji: Void = EmojiRepository.shared.refresh(for: keypair.pubkey)
            async let hashtagSets: Void = HashtagSetRepository.shared.bootstrap(keypair: keypair)
            async let peopleLists: Void = PeopleListRepository.shared.bootstrap(keypair: keypair)
            async let noteLists: Void = NoteListRepository.shared.bootstrap(keypair: keypair)
            async let relaySettings: Void = RelaySettingsRepository.shared.bootstrap(keypair: keypair)
            // Pre-warm the wallet at app start so the wallet tab opens with live data
            // instead of waiting for the user to land on it before kicking off the
            // 3-8s Spark SDK init or NWC relay handshake.
            async let wallet: Void = walletStore.startIfConfigured()
            _ = await (feed, messages, notifications, groups, emoji, hashtagSets, peopleLists, noteLists, relaySettings, wallet)
        }
        .onDisappear {
            viewModel.stop()
            messagesVM.stop()
            notificationsVM.stop()
            groupListVM.stop()
            searchVM.stop()
            MissingProfileWatcher.shared.stop()
        }
        .sheet(isPresented: $showInterfaceSettings) {
            NavigationStack {
                InterfaceSettingsView()
            }
        }
        .sheet(isPresented: $showKeys) {
            NavigationStack {
                KeysSettingsView(keypair: keypair)
            }
        }
        .sheet(isPresented: $showRelaySettings) {
            NavigationStack {
                RelaySettingsView(keypair: keypair)
            }
        }
        .sheet(item: $pendingAuthRequest) { req in
            RelayAuthApprovalSheet(
                relayUrl: req.relayUrl,
                keypair: keypair,
                onDismiss: { pendingAuthRequest = nil }
            )
        }
        .sheet(isPresented: $showCustomEmojis) {
            NavigationStack {
                CustomEmojiSettingsView(keypair: keypair)
            }
        }
        .sheet(isPresented: $showLists) {
            NavigationStack {
                ListsHubView(
                    keypair: keypair,
                    onViewPeopleFeed: { list in
                        showLists = false
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            feedPath.append(PeopleListFeedRoute(dTag: list.dTag))
                            selectedTab = .home
                        }
                    },
                    onViewNoteFeed: { list in
                        showLists = false
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            feedPath.append(NoteListFeedRoute(dTag: list.dTag))
                            selectedTab = .home
                        }
                    }
                )
                .navigationDestination(for: PeopleListEditorRoute.self) { route in
                    PeopleListEditorView(
                        keypair: keypair,
                        dTag: route.dTag,
                        onViewFeed: { list in
                            showLists = false
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(350))
                                feedPath.append(PeopleListFeedRoute(dTag: list.dTag))
                                selectedTab = .home
                            }
                        }
                    )
                }
                .navigationDestination(for: NoteListEditorRoute.self) { route in
                    NoteListEditorView(
                        keypair: keypair,
                        dTag: route.dTag,
                        onViewFeed: { list in
                            showLists = false
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(350))
                                feedPath.append(NoteListFeedRoute(dTag: list.dTag))
                                selectedTab = .home
                            }
                        }
                    )
                }
            }
        }
        .sheet(isPresented: $showHashtagSets) {
            NavigationStack {
                HashtagSetsView(
                    keypair: keypair,
                    onViewFeed: { set in
                        showHashtagSets = false
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            feedPath.append(HashtagFeedRoute(setDTag: set.dTag))
                            selectedTab = .home
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $showCompose) {
            ComposeView(keypair: keypair, mode: .new)
        }
        .sheet(item: $reopenDraft) { draft in
            ComposeView(keypair: keypair, draft: draft)
        }
        .onChange(of: draftToast.pendingDraft?.dTag) { _, dTag in
            // Auto-dismiss the pill on a timer whenever a new draft arrives.
            // Reading the dTag (a value type) keeps the watcher cheap.
            guard dTag != nil else { return }
            draftSavedToastTask?.cancel()
            draftSavedToastTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3.5))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    draftToast.pendingDraft = nil
                }
            }
        }
        .sheet(isPresented: $showRelayPicker) {
            RelayPickerSheet(
                keypair: keypair,
                onSelectRelay: { url in viewModel.selectRelay(url: url) },
                onSelectRelaySet: { set in viewModel.selectRelaySet(set) }
            )
        }
        .sheet(isPresented: $showSocialGraph) {
            SocialGraphView(keypair: keypair)
        }
        .sheet(isPresented: $showSafety) {
            NavigationStack {
                SafetySettingsView(keypair: keypair)
            }
        }
        .sheet(isPresented: $showProofOfWork) {
            NavigationStack {
                ProofOfWorkSettingsView()
            }
        }
        .sheet(isPresented: $showMediaServers) {
            NavigationStack {
                MediaServersView(keypair: keypair)
            }
        }
        .sheet(isPresented: $showDraftsScheduled) {
            DraftsScheduledView(keypair: keypair)
        }
        .sheet(isPresented: $showOnlineSheet) {
            OnlineNowSheet(
                networkPubkeys: viewModel.onlineNetworkPubkeys,
                globalCount: viewModel.globalOnlineCount,
                profiles: viewModel.profiles,
                onTapProfile: { pubkey in
                    showOnlineSheet = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        feedPath.append(ProfileRoute(pubkey: pubkey))
                        selectedTab = .home
                    }
                }
            )
            .presentationDetents([.medium, .large])
        }
    }


    private var mainShell: some View {
        VStack(spacing: 0) {
            ZStack {
                switch selectedTab {
                case .home:
                    NavigationStack(path: $feedPath) {
                        ZStack(alignment: .bottomTrailing) {
                            feedContent
                            if !drawerOpen {
                                ComposeFAB { showCompose = true }
                                    .padding(.trailing, 18)
                                    .padding(.bottom, 32 + (audioPlayer.currentTrack != nil ? MiniAudioPlayerView.collapsedHeight : 0))
                                    .opacity(feedFabOpacity)
                                    .animation(.easeInOut(duration: 0.2), value: feedFabOpacity)
                                    .animation(.smooth(duration: 0.22), value: audioPlayer.currentTrack != nil)
                            }
                        }
                            // Frosted unified top header — same `.regularMaterial` look as
                            // ProfileView. Inside the NavigationStack so it auto-disappears
                            // when the user pushes a destination, and content scrolls under
                            // it instead of starting below an opaque bar.
                            .safeAreaInset(edge: .top, spacing: 0) {
                                topBar.background(
                                    LinearGradient(
                                        colors: [
                                            Color.wispBackground.opacity(0.92),
                                            Color.wispBackground.opacity(0.65)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                            }
                            .navigationDestination(for: ProfileRoute.self) { route in
                                ProfileView(
                                    pubkey: route.pubkey,
                                    activeUserPubkey: keypair.pubkey,
                                    onProfileTap: { pk in feedPath.append(ProfileRoute(pubkey: pk)) },
                                    onNoteTap: { eid in feedPath.append(ThreadRoute(eventId: eid, authorPubkey: route.pubkey)) },
                                    onHashtagTap: { tag in feedPath.append(HashtagFeedRoute(tag: tag)) }
                                )
                            }
                            .navigationDestination(for: ThreadRoute.self) { route in
                                ThreadView(
                                    seedEventId: route.eventId,
                                    authorHint: route.authorPubkey,
                                    keypair: keypair,
                                    path: $feedPath,
                                    chain: $feedThreadChain
                                )
                            }
                            .navigationDestination(for: LiveStreamRoute.self) { route in
                                LiveStreamView(route: route, keypair: keypair)
                                    .environment(walletStore)
                            }
                            .navigationDestination(for: HashtagFeedRoute.self) { route in
                                hashtagFeedView(for: route)
                            }
                            .navigationDestination(for: PeopleListFeedRoute.self) { route in
                                PeopleListFeedView(
                                    keypair: keypair,
                                    dTag: route.dTag,
                                    onProfileTap: { pubkey in
                                        feedPath.append(ProfileRoute(pubkey: pubkey))
                                    },
                                    onNoteTap: { eventId in
                                        feedPath.append(ThreadRoute(eventId: eventId, authorPubkey: ""))
                                    },
                                    onHashtagTap: { tag in
                                        feedPath.append(HashtagFeedRoute(tag: tag))
                                    }
                                )
                            }
                            .navigationDestination(for: NoteListFeedRoute.self) { route in
                                NoteListFeedView(
                                    keypair: keypair,
                                    dTag: route.dTag,
                                    onProfileTap: { pubkey in
                                        feedPath.append(ProfileRoute(pubkey: pubkey))
                                    },
                                    onNoteTap: { eventId in
                                        feedPath.append(ThreadRoute(eventId: eventId, authorPubkey: ""))
                                    },
                                    onHashtagTap: { tag in
                                        feedPath.append(HashtagFeedRoute(tag: tag))
                                    }
                                )
                            }
                            .navigationDestination(for: TrendingFeedRoute.self) { _ in
                                TrendingFeedView(
                                    keypair: keypair,
                                    onProfileTap: { pubkey in
                                        feedPath.append(ProfileRoute(pubkey: pubkey))
                                    },
                                    onNoteTap: { eventId in
                                        feedPath.append(ThreadRoute(eventId: eventId, authorPubkey: ""))
                                    },
                                    onHashtagTap: { tag in
                                        feedPath.append(HashtagFeedRoute(tag: tag))
                                    }
                                )
                            }
                            .toolbar(.hidden, for: .navigationBar)
                    }
                case .messages:
                    MessagesView(viewModel: messagesVM, groupListVM: groupListVM)
                case .search:
                    NavigationStack(path: $searchPath) {
                        SearchView(keypair: keypair, viewModel: searchVM, path: $searchPath)
                            .navigationDestination(for: ProfileRoute.self) { route in
                                ProfileView(
                                    pubkey: route.pubkey,
                                    activeUserPubkey: keypair.pubkey,
                                    onProfileTap: { pk in searchPath.append(ProfileRoute(pubkey: pk)) },
                                    onNoteTap: { eid in searchPath.append(ThreadRoute(eventId: eid, authorPubkey: route.pubkey)) },
                                    onHashtagTap: { _ in }
                                )
                            }
                            .navigationDestination(for: ThreadRoute.self) { route in
                                ThreadView(
                                    seedEventId: route.eventId,
                                    authorHint: route.authorPubkey,
                                    keypair: keypair,
                                    path: $searchPath,
                                    chain: $searchThreadChain
                                )
                            }
                            .toolbar(.hidden, for: .navigationBar)
                    }
                case .notifications:
                    NavigationStack(path: $notificationsPath) {
                        NotificationsView(
                            viewModel: notificationsVM,
                            onPeerTap: { pubkey in
                                notificationsPath.append(ProfileRoute(pubkey: pubkey))
                            },
                            onDmTap: { _ in
                                selectedTab = .messages
                            },
                            onNoteTap: { eventId, authorHint in
                                // Prefer the actual reply author (passed up from
                                // the row) over keypair.pubkey — gives ThreadView
                                // a relay set that actually has the focal +
                                // ancestors instead of the user's own inbox.
                                notificationsPath.append(ThreadRoute(
                                    eventId: eventId,
                                    authorPubkey: authorHint ?? keypair.pubkey
                                ))
                            }
                        )
                        .navigationDestination(for: ProfileRoute.self) { route in
                            ProfileView(
                                pubkey: route.pubkey,
                                activeUserPubkey: keypair.pubkey,
                                onProfileTap: { pk in notificationsPath.append(ProfileRoute(pubkey: pk)) },
                                onNoteTap: { eid in notificationsPath.append(ThreadRoute(eventId: eid, authorPubkey: route.pubkey)) },
                                onHashtagTap: { _ in }
                            )
                        }
                        .navigationDestination(for: ThreadRoute.self) { route in
                            ThreadView(
                                seedEventId: route.eventId,
                                authorHint: route.authorPubkey,
                                keypair: keypair,
                                path: $notificationsPath,
                                chain: $notificationsThreadChain
                            )
                        }
                        .toolbar(.hidden, for: .navigationBar)
                    }
                case .wallet:
                    NavigationStack {
                        WalletView(store: walletStore)
                            .toolbar(.hidden, for: .navigationBar)
                    }
                default:
                    NavigationStack(path: $placeholderPath) {
                        placeholderTab
                            .navigationDestination(for: ProfileRoute.self) { route in
                                ProfileView(pubkey: route.pubkey, activeUserPubkey: keypair.pubkey)
                            }
                            .navigationDestination(for: ThreadRoute.self) { route in
                                ThreadView(
                                    seedEventId: route.eventId,
                                    authorHint: route.authorPubkey,
                                    keypair: keypair,
                                    path: $placeholderPath,
                                    chain: $placeholderThreadChain
                                )
                            }
                            .toolbar(.hidden, for: .navigationBar)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if audioPlayer.currentTrack != nil {
                MiniAudioPlayerView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
            }

            bottomBar
        }
        .background(Color.wispBackground)
        .animation(.smooth(duration: 0.22), value: audioPlayer.currentTrack != nil)
    }

    // MARK: - Drawer

    private func openDrawer() {
        drawerDragOffset = 0
        withAnimation(.smooth(duration: 0.25)) { drawerOpen = true }
    }

    private func closeDrawer() {
        withAnimation(.smooth(duration: 0.25)) {
            drawerOpen = false
            drawerDragOffset = 0
        }
    }

    private var drawerDragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard drawerOpen else { return }
                drawerDragOffset = min(0, value.translation.width)
            }
            .onEnded { value in
                guard drawerOpen else { return }
                if value.translation.width < -drawerWidth * 0.3 {
                    closeDrawer()
                } else {
                    withAnimation(.smooth(duration: 0.2)) { drawerDragOffset = 0 }
                }
            }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            profileAvatar

            Spacer()

            HStack(spacing: 8) {
                if !viewModel.onlineNetworkPubkeys.isEmpty {
                    Button {
                        showOnlineSheet = true
                    } label: {
                        statusPill(
                            icon: "person.fill",
                            value: formatCount(viewModel.onlineNetworkPubkeys.count),
                            color: .wispRepostColor
                        )
                    }
                    .buttonStyle(.plain)
                }

                Menu {
                    if viewModel.connectedRelays.isEmpty {
                        Text("Not connected")
                    } else {
                        ForEach(viewModel.connectedRelays, id: \.url) { relay in
                            let host = URL(string: relay.url)?.host ?? relay.url
                            Button { } label: {
                                Text("\(host) (\(relay.authorCount))")
                            }
                        }
                    }
                } label: {
                    statusPill(
                        icon: "network",
                        value: "\(viewModel.connectedRelayCount)",
                        color: viewModel.connectedRelayCount > 0 ? .wispRepostColor : .red
                    )
                }
            }
        }
        .overlay(feedPicker)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var profileAvatar: some View {
        Button {
            openDrawer()
        } label: {
            CachedAvatarView(url: viewModel.userProfile?.picture, size: 32)
        }
        .buttonStyle(.plain)
    }

    private var feedPicker: some View {
        Menu {
            Button {
                viewModel.selectFollows()
            } label: {
                Label("Follows", systemImage: viewModel.currentKind == .follows ? "checkmark" : "person.2")
            }
            Button {
                showRelayPicker = true
            } label: {
                let active: Bool = {
                    switch viewModel.currentKind {
                    case .follows, .extendedNetwork: return false
                    case .relay, .relaySet: return true
                    }
                }()
                Label("Relay", systemImage: active ? "checkmark" : "antenna.radiowaves.left.and.right")
            }

            Button {
                viewModel.selectExtendedNetwork()
            } label: {
                Label(
                    "Extended Network",
                    systemImage: viewModel.currentKind == .extendedNetwork
                        ? "checkmark"
                        : "point.3.connected.trianglepath.dotted"
                )
            }

            Button {
                showHashtagSets = true
            } label: {
                Label("Hashtags", systemImage: "number")
            }

            Button {
                showLists = true
            } label: {
                Label("Lists", systemImage: "list.bullet")
            }

            Button {
                feedPath.append(TrendingFeedRoute())
            } label: {
                Label("Trending", systemImage: "flame")
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.currentKind.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.wispSurfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(Color.primary)
        }
    }

    @ViewBuilder
    private func draftSavedPill(draft: Nip37.Draft) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                draftToast.pendingDraft = nil
            }
            draftSavedToastTask?.cancel()
            reopenDraft = draft
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Draft saved")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.wispPrimary, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func statusPill(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            Text(value)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.wispSurfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Feed Content

    private var emptyStateTitle: String {
        switch viewModel.currentKind {
        case .follows: return "No posts yet"
        case .relay: return "Connecting…"
        case .relaySet: return "Connecting…"
        case .extendedNetwork:
            return SocialGraphCache.load(pubkey: keypair.pubkey) == nil
                ? "No extended network yet"
                : "Connecting…"
        }
    }

    private var emptyStateSubtitle: String {
        switch viewModel.currentKind {
        case .follows:
            return "Follow some people to see their posts here"
        case .relay(let url):
            return "Waiting for events from \(URL(string: url)?.host ?? url)."
        case .relaySet(let set):
            return "Waiting for events across \(set.relays.count) relay\(set.relays.count == 1 ? "" : "s")."
        case .extendedNetwork:
            if SocialGraphCache.load(pubkey: keypair.pubkey) == nil {
                return "Compute your social graph to see posts from accounts followed by your follows."
            }
            return "Waiting for events from your extended network."
        }
    }

    @ViewBuilder
    private var emptyStateExtraAction: some View {
        if case .extendedNetwork = viewModel.currentKind,
           SocialGraphCache.load(pubkey: keypair.pubkey) == nil {
            Button {
                showSocialGraph = true
            } label: {
                Text("Compute Now")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.wispPrimary, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var relayFeedStatusBanner: some View {
        if case .follows = viewModel.currentKind {
            EmptyView()
        } else {
            switch viewModel.relayFeedStatus {
            case .idle, .streaming:
                EmptyView()
            case .connecting:
                statusBanner(text: "Connecting…", color: .secondary)
            case .noEvents:
                statusBanner(text: "No events received yet", color: .orange)
            case .timedOut:
                statusBanner(text: "Connection timed out", color: .red)
            case .connectionFailed(let msg):
                statusBanner(text: msg, color: .red)
            }
        }
    }

    private func statusBanner(text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.wispSurfaceVariant.opacity(0.4))
    }

    private var feedContent: some View {
        VStack(spacing: 0) {
            relayFeedStatusBanner
            feedBody
        }
    }

    private var feedBody: some View {
        Group {
            if viewModel.isLoading && viewModel.events.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading your feed\u{2026}")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.events.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(emptyStateTitle)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(emptyStateSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    emptyStateExtraAction
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { feedProxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Anchor for tap-Home-on-Home → scroll-to-top. Zero-height
                        // so it doesn't reserve layout space.
                        Color.clear.frame(height: 0).id("feedTop")
                        let liveStreams = liveStreamRepo.liveNowSorted
                        if !liveStreams.isEmpty {
                            LiveNowRow(
                                streams: liveStreams,
                                profiles: viewModel.profiles,
                                onSelect: { stream in
                                    feedPath.append(LiveStreamRoute(
                                        aTagValue: stream.aTagValue,
                                        hostPubkey: stream.activity.hostPubkey,
                                        dTag: stream.activity.dTag,
                                        relayHints: stream.activity.relayHints
                                    ))
                                }
                            )
                            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                        }
                        // Iterating events directly with `id: \.id` keeps row
                        // identity stable when the array shifts (new posts
                        // prepended). The previous `Array(events.enumerated())`
                        // wrapper changed every row's underlying tuple
                        // identity on every prepend, forcing SwiftUI to
                        // re-instantiate every visible PostCardView.
                        ForEach(viewModel.events, id: \.id) { event in
                            PostCardView(
                                event: event,
                                profile: viewModel.profiles[event.pubkey],
                                profiles: viewModel.profiles,
                                engagement: nil,
                                onProfileTap: { pubkey in
                                    Task { await viewModel.requestProfileIfNeeded(pubkey) }
                                },
                                onNoteTap: { eventId in
                                    feedPath.append(ThreadRoute(eventId: eventId, authorPubkey: event.pubkey))
                                },
                                onHashtagTap: { tag in
                                    feedPath.append(HashtagFeedRoute(tag: tag))
                                }
                            )
                            // Programmatic push instead of wrapping the card in a
                            // NavigationLink — the link's press gesture loses races
                            // against the inner avatar / action-bar / link buttons,
                            // so taps on empty card space frequently needed two
                            // presses to fire. Inner Buttons still capture their
                            // own taps before this gesture runs.
                            .contentShape(Rectangle())
                            .onTapGesture {
                                feedPath.append(ThreadRoute(eventId: event.id, authorPubkey: event.pubkey))
                            }
                            .onAppear {
                                engagementRepo.markVisible(event: event)
                                if let idx = viewModel.events.firstIndex(where: { $0.id == event.id }),
                                   idx >= viewModel.events.count - 5 {
                                    switch viewModel.currentKind {
                                    case .follows: break
                                    case .relay, .relaySet, .extendedNetwork: viewModel.loadMore()
                                    }
                                }
                            }
                            Divider()
                                .overlay(Color.wispSurfaceVariant.opacity(0.3))
                        }
                    }
                }
                .refreshable { await viewModel.refresh() }
                .onScrollPhaseChange { _, newPhase in
                    switch newPhase {
                    case .tracking, .interacting:
                        feedFabOpacity = 0.35
                    case .decelerating, .animating:
                        feedFabOpacity = 0.75
                    case .idle:
                        feedFabOpacity = 1.0
                    @unknown default:
                        feedFabOpacity = 1.0
                    }
                }
                .onChange(of: feedScrollToTopTrigger) { _, _ in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        feedProxy.scrollTo("feedTop", anchor: .top)
                    }
                }
                }
            }
        }
    }

    private var placeholderTab: some View {
        VStack(spacing: 12) {
            Image(systemName: selectedTab.icon)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(selectedTab.rawValue.capitalized)
                .font(.title3.weight(.medium))
                .foregroundStyle(.tertiary)
            Text("Coming soon")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            ForEach(BottomTab.allCases, id: \.self) { tab in
                Button {
                    if selectedTab == tab {
                        popToRoot(tab)
                    } else {
                        selectedTab = tab
                    }
                } label: {
                    Image(systemName: tab == selectedTab ? tab.selectedIcon : tab.icon)
                        .font(.system(size: 22))
                        .frame(height: 28)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .topTrailing) {
                            if tab == .notifications, notificationsVM.hasUnread {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                                    .offset(x: -10, y: 2)
                            }
                        }
                }
                .foregroundStyle(tab == selectedTab ? Color.wispPrimary : .secondary)
            }
        }
        .padding(.vertical, 10)
        .padding(.bottom, 2)
    }

    // MARK: - Helpers

    /// Tapping the already-selected tab pops its navigation stack back to the
    /// tab's root view. Mirrors the standard iOS tab-bar gesture.
    /// For Home, also bump `feedScrollToTopTrigger` — when the stack is already
    /// empty (already on the feed root) the path-clear is a no-op and only the
    /// scroll-to-top fires; when there's something pushed, the path-clear pops
    /// first and the scroll-to-top runs against the now-visible feed.
    private func popToRoot(_ tab: BottomTab) {
        switch tab {
        case .home:
            feedPath = NavigationPath()
            feedScrollToTopTrigger &+= 1
        case .wallet: placeholderPath = NavigationPath()
        case .search: searchPath = NavigationPath()
        case .notifications: notificationsPath = NavigationPath()
        case .messages: break  // MessagesView owns its own NavigationStack
        }
    }

    private func formatCount(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: String(format: "%.1fk", Double(n) / 1_000)
        default: "\(n)"
        }
    }

    @ViewBuilder
    private func hashtagFeedView(for route: HashtagFeedRoute) -> some View {
        if let tag = route.tag {
            HashtagFeedView(
                keypair: keypair,
                source: .single(tag),
                onHashtagTap: { newTag in
                    feedPath.append(HashtagFeedRoute(tag: newTag))
                }
            )
        } else if let dTag = route.setDTag,
                  let set = hashtagSetRepo.hashtagSet(dTag: dTag) {
            HashtagFeedView(
                keypair: keypair,
                source: .set(set),
                onHashtagTap: { newTag in
                    feedPath.append(HashtagFeedRoute(tag: newTag))
                }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("Set not found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.wispBackground)
        }
    }
}

// MARK: - Bottom Tab Definition

enum BottomTab: String, CaseIterable {
    case home
    case wallet
    case search
    case messages
    case notifications

    var icon: String {
        switch self {
        case .home: "house"
        case .wallet: "creditcard"
        case .search: "magnifyingglass"
        case .messages: "bubble.left.and.bubble.right"
        case .notifications: "bell"
        }
    }

    var selectedIcon: String {
        switch self {
        case .home: "house.fill"
        case .wallet: "creditcard.fill"
        case .search: "magnifyingglass"
        case .messages: "bubble.left.and.bubble.right.fill"
        case .notifications: "bell.fill"
        }
    }
}

private struct OnlineNowSheet: View {
    let networkPubkeys: [String]
    let globalCount: Int?
    let profiles: [String: ProfileData]
    let onTapProfile: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Online Now")
                    .font(.title2.weight(.semibold))

                row(text: "\(networkPubkeys.count) online in your network")
                if let g = globalCount {
                    row(text: "\(g) online across all of Nostr")
                }

                FlowLayout(spacing: 8) {
                    ForEach(networkPubkeys, id: \.self) { pk in
                        Button {
                            onTapProfile(pk)
                        } label: {
                            CachedAvatarView(url: profiles[pk]?.picture, size: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private func row(text: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color.wispRepostColor).frame(width: 8, height: 8)
            Text(text).font(.subheadline)
        }
    }
}
