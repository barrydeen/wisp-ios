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

    var body: some View {
        Group {
            switch currentScreen {
            case .splash:
                SplashView(
                    onContinueWithNostr: {
                        showNostrSheet = true
                    },
                    onContinueWithGoogle: {
                        showGoogleAuth = true
                    },
                    onContinueWithApple: {
                        showAppleAuth = true
                    }
                )
                .sheet(isPresented: $showNostrSheet) {
                    NostrLoginSheet(
                        onLogin: { kp in
                            keypair = kp
                            showNostrSheet = false
                            // Watch-only accounts skip onboarding (markOnboardingComplete
                            // is called in NostrLoginSheet before this closure fires).
                            if NostrKey.isOnboardingComplete(pubkey: kp.pubkey) {
                                currentScreen = .loading
                            } else {
                                currentScreen = .onboarding
                            }
                        },
                        onCreateAccount: {
                            showNostrSheet = false
                            currentScreen = .signUp
                        }
                    )
                }
                .fullScreenCover(isPresented: $showGoogleAuth) {
                    GoogleAuthView(
                        onCancel: { showGoogleAuth = false },
                        onDone: { _, kp in
                            keypair = kp
                            showGoogleAuth = false
                            // Both new and restored Google accounts run the
                            // outbox-builder onboarding so the feed has
                            // relays-per-author before MainView mounts.
                            // `OnboardingView`'s watch-only fast path is
                            // skipped because we always have a privkey here.
                            if NostrKey.isOnboardingComplete(pubkey: kp.pubkey) {
                                currentScreen = .loading
                            } else {
                                currentScreen = .onboarding
                            }
                        }
                    )
                }
                .fullScreenCover(isPresented: $showAppleAuth) {
                    AppleAuthView(
                        onCancel: { showAppleAuth = false },
                        onDone: { isNewAccount, kp in
                            keypair = kp
                            showAppleAuth = false
                            if isNewAccount {
                                // Brand-new account: run the same profile /
                                // follows / hashtags / intro-note wizard as
                                // a "Create new account" tap, passing the
                                // already-generated, already-backed-up key
                                // so the wizard doesn't mint a second one.
                                signUpExistingKeypair = kp
                                currentScreen = .signUp
                            } else if NostrKey.isOnboardingComplete(pubkey: kp.pubkey) {
                                currentScreen = .loading
                            } else {
                                // Restored account: outbox-builder fetches
                                // kind-3 / kind-10002 from relays so the
                                // feed has follows + per-author write
                                // relays before MainView mounts.
                                currentScreen = .onboarding
                            }
                        }
                    )
                }

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
            LoginView { newKeypair in
                showAddAccount = false
                self.keypair = newKeypair
                // First time we see this pubkey on the device, run onboarding
                // so the outbox builder fetches kind-3 contacts and kind-10002
                // relay lists — without that the feed has no follows to query
                // and falls back to showing only the user's own posts. Already-
                // onboarded accounts (the user re-adding a previously-used
                // pubkey) skip straight to the loading splash.
                if NostrKey.isOnboardingComplete(pubkey: newKeypair.pubkey) {
                    accountSwitchInProgress = true
                    currentScreen = .loading
                } else {
                    currentScreen = .onboarding
                }
            }
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
