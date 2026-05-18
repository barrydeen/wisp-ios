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
    @State private var showLogin = false
    @State private var keypair: Keypair?
    @State private var checkedSavedAccount = false
    @State private var accountSwitchInProgress = false
    @State private var showAddAccount = false

    var body: some View {
        Group {
            switch currentScreen {
            case .splash:
                SplashView(
                    onSignUp: {
                        currentScreen = .signUp
                    },
                    onLogIn: {
                        showLogin = true
                    }
                )
                .sheet(isPresented: $showLogin) {
                    LoginView { kp in
                        keypair = kp
                        showLogin = false
                        // Watch-only accounts skip onboarding (markOnboardingComplete
                        // is called in LoginView before this closure fires).
                        if NostrKey.isOnboardingComplete(pubkey: kp.pubkey) {
                            currentScreen = .loading
                        } else {
                            currentScreen = .onboarding
                        }
                    }
                }

            case .signUp:
                SignUpFlowView { kp in
                    keypair = kp
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
                    }, onForceRerunOnboarding: {
                        // Triggered by the follow-history guard after the user
                        // accepts a restore. Bounce through onboarding so the
                        // relay scoreboard gets rebuilt from the restored
                        // follow list; OnboardingView lands back here when done.
                        withAnimation { currentScreen = .onboarding }
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
                // Remote-signer accounts need their NIP-46 session rehydrated
                // before any signing surface is reachable. Restore on a Task
                // because `Nip46Manager.restoreSession` is async (opens
                // WebSockets to the signer's relays).
                if saved.isRemote && !NostrKey.isWatchOnly(pubkey: saved.pubkey) {
                    Task { _ = await Nip46Manager.shared.restoreSession(pubkey: saved.pubkey) }
                }
                if NostrKey.isOnboardingComplete(pubkey: saved.pubkey) {
                    currentScreen = .loading
                } else {
                    currentScreen = .onboarding
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
