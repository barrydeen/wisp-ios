import SwiftUI

enum AppScreen {
    case splash
    case loading
    case onboarding
    case signUp
    case main
}

struct ContentView: View {
    @State private var currentScreen: AppScreen = .splash
    @State private var showNostrSheet = false
    @State private var showGoogleAuth = false
    @State private var showAppleAuth = false
    @State private var keypair: Keypair?
    @State private var checkedSavedAccount = false
    @State private var accountSwitchInProgress = false
    @State private var showAddAccount = false
    /// When the user creates a brand-new account via the Apple cloud flow,
    /// the keypair is generated and backed up before the wizard runs. We
    /// route them into `SignUpFlowView` with this pre-generated key so they
    /// still get the profile / follows / hashtags steps without minting a
    /// second key (which would leave the backed-up key abandoned).
    @State private var signUpExistingKeypair: Keypair?

    /// The single place an account is chosen — cold launch and add-account
    /// both. Previously add-account had its own `LoginView`, which had
    /// drifted: it took nsec only (no watch-only npub), offered neither
    /// Apple nor Google, and didn't trim pasted input. Sharing one view
    /// means those can't diverge again.
    @ViewBuilder
    private func loginEntry(mode: SplashView.Mode) -> some View {
        SplashView(
            mode: mode,
            onContinueWithNostr: { showNostrSheet = true },
            onContinueWithGoogle: { showGoogleAuth = true },
            onContinueWithApple: { showAppleAuth = true },
            onCancel: { showAddAccount = false }
        )
        .sheet(isPresented: $showNostrSheet) {
            NostrLoginSheet(
                onLogin: { kp in
                    showNostrSheet = false
                    // Watch-only accounts skip onboarding
                    // (`markOnboardingComplete` runs inside NostrLoginSheet
                    // before this fires).
                    finishLogin(kp, mode: mode)
                },
                onCreateAccount: {
                    showNostrSheet = false
                    if mode == .addAccount { showAddAccount = false }
                    currentScreen = .signUp
                }
            )
        }
        .fullScreenCover(isPresented: $showGoogleAuth) {
            GoogleAuthView(
                onCancel: { showGoogleAuth = false },
                onDone: { _, kp in
                    showGoogleAuth = false
                    // Both new and restored Google accounts run the
                    // outbox-builder onboarding so the feed has
                    // relays-per-author before MainView mounts.
                    finishLogin(kp, mode: mode)
                }
            )
        }
        .fullScreenCover(isPresented: $showAppleAuth) {
            AppleAuthView(
                onCancel: { showAppleAuth = false },
                onDone: { isNewAccount, kp in
                    showAppleAuth = false
                    guard !isNewAccount else {
                        // Brand-new account: run the same profile / follows /
                        // hashtags / intro-note wizard as a "Create new
                        // account" tap, passing the already-generated,
                        // already-backed-up key so the wizard doesn't mint a
                        // second one.
                        keypair = kp
                        signUpExistingKeypair = kp
                        if mode == .addAccount { showAddAccount = false }
                        currentScreen = .signUp
                        return
                    }
                    finishLogin(kp, mode: mode)
                }
            )
        }
    }

    /// Shared post-login routing. The only differences between the two entry
    /// points are dismissing the add-account cover and the shorter loading
    /// delay an account *switch* gets.
    private func finishLogin(_ kp: Keypair, mode: SplashView.Mode) {
        keypair = kp
        if mode == .addAccount { showAddAccount = false }
        // First time this pubkey is seen on the device, run onboarding so the
        // outbox builder fetches kind-3 contacts and kind-10002 relay lists —
        // without those the feed has no follows to query and shows only the
        // user's own posts.
        guard NostrKey.isOnboardingComplete(pubkey: kp.pubkey) else {
            currentScreen = .onboarding
            return
        }
        if mode == .addAccount { accountSwitchInProgress = true }
        currentScreen = .loading
    }

    var body: some View {
        Group {
            switch currentScreen {
            case .splash:
                loginEntry(mode: .firstRun)

            case .signUp:
                SignUpFlowView(existingKeypair: signUpExistingKeypair) { kp in
                    keypair = kp
                    signUpExistingKeypair = nil
                    withAnimation { currentScreen = .main }
                }

            case .loading:
                LoadingView(delay: accountSwitchInProgress ? 350 : 800) {
                    accountSwitchInProgress = false
                    withAnimation { currentScreen = .main }
                }

            case .onboarding:
                if let keypair {
                    OnboardingView(keypair: keypair) {
                        withAnimation { currentScreen = .main }
                    }
                }

            case .main:
                if let keypair {
                    MainView(keypair: keypair, onLogout: {
                        ZapAnimationStore.shared.cancelAll()
                        self.keypair = nil
                        currentScreen = .splash
                    }, onSwitchAccount: { newKeypair in
                        ZapAnimationStore.shared.cancelAll()
                        self.keypair = newKeypair
                        accountSwitchInProgress = true
                        currentScreen = .loading
                    }, onAddAccount: {
                        showAddAccount = true
                    })
                }
            }
        }
        .fullScreenCover(isPresented: $showAddAccount) {
            loginEntry(mode: .addAccount)
                .interactiveDismissDisabled()
        }
        .onAppear {
            guard !checkedSavedAccount else { return }
            checkedSavedAccount = true
            if let saved = NostrKey.load() {
                keypair = saved
                // Ensure accounts set up before multi-account was added are
                // registered in wisp_accounts so they survive an "Add Account" flow.
                NostrKey.registerInAccountList(saved.pubkey)
                if NostrKey.isOnboardingComplete(pubkey: saved.pubkey) {
                    currentScreen = .loading
                } else {
                    currentScreen = .onboarding
                }
            }
        }
        .onChange(of: keypair?.pubkey) { _, newPubkey in
            if let pk = newPubkey {
                AppSettings.shared.loadQuickZapSettings(for: pk)
            }
        }
    }
}

#Preview {
    ContentView()
}
