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
                        currentScreen = .onboarding
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
                        self.keypair = nil
                        currentScreen = .splash
                    }, onSwitchAccount: { newKeypair in
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
                accountSwitchInProgress = true
                currentScreen = .loading
            }
            .interactiveDismissDisabled()
        }
        .onAppear {
            guard !checkedSavedAccount else { return }
            checkedSavedAccount = true
            if let saved = NostrKey.load() {
                keypair = saved
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
