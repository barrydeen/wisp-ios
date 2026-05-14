import SwiftUI

struct OnboardingView: View {
    let keypair: Keypair
    var onComplete: () -> Void

    @State private var viewModel: OnboardingViewModel
    @State private var currentPage = 0

    init(keypair: Keypair, onComplete: @escaping () -> Void) {
        self.keypair = keypair
        self.onComplete = onComplete
        _viewModel = State(initialValue: OnboardingViewModel(keypair: keypair))
    }

    var body: some View {
        // A `TabView(.page)` would let the user swipe horizontally back to
        // earlier steps — easy to do by accident. Drive the transitions off
        // a switch instead so the only way forward is the explicit button
        // each step provides.
        Group {
            if keypair.isWatchOnly {
                // Watch-only accounts skip the welcome / follow / zap teaching
                // since none of those mechanics are usable read-only. We still
                // need the outbox builder to run so the user's kind-10002 is
                // ingested and the feed has relays to query.
                WatchOnlyStep(viewModel: viewModel, keypair: keypair, onComplete: onComplete)
            } else {
                switch currentPage {
                case 0:
                    WelcomeStep(onNext: { withAnimation { currentPage = 1 } })
                case 1:
                    OutboxStep(onNext: { withAnimation { currentPage = 2 } })
                case 2:
                    FollowStep(onNext: { withAnimation { currentPage = 3 } })
                case 3:
                    ZapStep(onNext: { withAnimation { currentPage = 4 } })
                default:
                    WaitingStep(viewModel: viewModel, keypair: keypair, onComplete: onComplete)
                }
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing),
            removal: .move(edge: .leading)
        ))
        // Force the step content to fill the screen so the background covers
        // every edge — the waiting step's VStack would otherwise size to its
        // widest text and let the system black show through on the sides.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.wispBackground)
        .ignoresSafeArea()
        .task { await viewModel.startOutboxBuilding() }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    var onNext: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image("WispLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 20)

            Text("Welcome back")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white)
                .opacity(appeared ? 1 : 0)

            Text("Let\u{2019}s get you set up")
                .font(.title3)
                .foregroundStyle(.secondary)
                .opacity(appeared ? 1 : 0)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onNext() }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { appeared = true }
            Task {
                try? await Task.sleep(for: .seconds(3))
                onNext()
            }
        }
    }
}

// MARK: - Step 2: Outbox Explanation

private struct OutboxStep: View {
    var onNext: () -> Void

    var body: some View {
        StepLayout(
            icon: "network",
            title: "Your network, your relays",
            message: "Wisp discovers which relays your friends actually use, then connects directly to those relays.\n\nThis means faster delivery and fewer missed posts \u{2014} no central server needed.",
            buttonTitle: "Continue",
            action: onNext
        )
    }
}

// MARK: - Step 3: Long-Press Demo

private struct FollowStep: View {
    var onNext: () -> Void
    @State private var didLongPress = false
    @State private var glowAmount: CGFloat = 0.4
    @State private var showFollowed = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .foregroundStyle(Color.wispPrimary)
                .shadow(color: Color.wispPrimary.opacity(glowAmount), radius: 20)
                .scaleEffect(showFollowed ? 1.1 : 1.0)
                .onLongPressGesture(minimumDuration: 0.5) {
                    withAnimation(.spring(response: 0.3)) {
                        showFollowed = true
                        didLongPress = true
                    }
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        withAnimation { showFollowed = false }
                    }
                }

            if showFollowed {
                Text("Followed!")
                    .font(.headline)
                    .foregroundStyle(Color.wispPrimary)
                    .transition(.scale.combined(with: .opacity))
            }

            Text("Quick follow")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)

            Text("Long-press any profile picture to follow or unfollow")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if !didLongPress {
                Text("Try it \u{2014} long-press the picture above")
                    .font(.subheadline)
                    .foregroundStyle(Color.wispPrimary)
            }

            Spacer()

            Button("Continue", action: onNext)
                .buttonStyle(.borderedProminent)
                .tint(.wispPrimary)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .opacity(didLongPress ? 1 : 0.4)
                .disabled(!didLongPress)

            Spacer().frame(height: 48)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                glowAmount = 0.8
            }
        }
    }
}

// MARK: - Step 4: Zaps

private struct ZapStep: View {
    var onNext: () -> Void

    var body: some View {
        StepLayout(
            icon: "bolt.fill",
            title: "Zaps",
            message: "Wisp supports zaps with an embedded Lightning wallet or Nostr Wallet Connect.\n\nYou can set this up anytime from the Wallet screen.",
            buttonTitle: "Continue",
            action: onNext
        )
    }
}

// MARK: - Step 5: Waiting / Loading

private struct WaitingStep: View {
    var viewModel: OnboardingViewModel
    let keypair: Keypair
    var onComplete: () -> Void

    @State private var messageIndex = 0
    @State private var rotation: Double = 0
    @State private var profile: ProfileData?
    /// Staged entrance flags. The ring draws itself in first; the avatar
    /// fades in once the ring has settled. Without the stage, the avatar
    /// painted alongside the slide-in transition before the ring was
    /// visually "in place," so for a frame it looked like a bare profile
    /// picture floating without its loading affordance.
    @State private var ringDrawn: CGFloat = 0
    @State private var avatarRevealed = false

    /// Spinner ring sized to match the success checkmark so the
    /// transition reads as the same widget swapping its content,
    /// and the avatar inside has room to read at a glance.
    private let spinnerSize: CGFloat = 64
    private let avatarSize: CGFloat = 52

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if viewModel.isReady {
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: spinnerSize, height: spinnerSize)
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                ZStack {
                    CachedAvatarView(url: profile?.picture, size: avatarSize)
                        .opacity(avatarRevealed ? 1 : 0)
                    Circle()
                        .trim(from: 0, to: ringDrawn)
                        .stroke(Color.wispPrimary, lineWidth: 4)
                        .frame(width: spinnerSize, height: spinnerSize)
                        .rotationEffect(.degrees(rotation))
                }
                .frame(width: spinnerSize, height: spinnerSize)
            }

            if viewModel.isReady {
                VStack(spacing: 8) {
                    Text("You\u{2019}re all set!")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)

                    if viewModel.followCount > 0 {
                        let relayCount = viewModel.scoreBoard?.scoredRelays.count ?? 0
                        Text("Following \(viewModel.followCount) people across \(relayCount) relays")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity)
            } else {
                Text(OnboardingViewModel.statusMessages[messageIndex])
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .id(messageIndex)
            }

            Spacer()

            if viewModel.isReady {
                Button("Let\u{2019}s go", action: onComplete)
                    .buttonStyle(.borderedProminent)
                    .tint(.wispPrimary)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Spacer().frame(height: 48)
        }
        .animation(.easeInOut, value: viewModel.isReady)
        .onAppear {
            profile = ProfileRepository.shared.get(keypair.pubkey)
            // Stage 1: ring draws itself in. Stage 2: rotation kicks off
            // and the avatar fades in inside the now-visible ring.
            withAnimation(.easeOut(duration: 0.45)) { ringDrawn = 0.7 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
                withAnimation(.easeIn(duration: 0.25)) { avatarRevealed = true }
            }
            Task {
                while !viewModel.isReady {
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !viewModel.isReady else { break }
                    withAnimation {
                        messageIndex = (messageIndex + 1) % OnboardingViewModel.statusMessages.count
                    }
                }
            }
        }
    }
}

// MARK: - Shared Step Layout

private struct StepLayout: View {
    let icon: String
    let title: String
    let message: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundStyle(Color.wispPrimary)

            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .tint(.wispPrimary)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)

            Spacer().frame(height: 48)
        }
    }
}

// MARK: - Watch-Only Step

private struct WatchOnlyStep: View {
    var viewModel: OnboardingViewModel
    let keypair: Keypair
    var onComplete: () -> Void

    @State private var rotation: Double = 0
    @State private var ringDrawn: CGFloat = 0
    @State private var avatarRevealed = false
    @State private var profile: ProfileData?

    private let spinnerSize: CGFloat = 64
    private let avatarSize: CGFloat = 52

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if viewModel.isReady {
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: spinnerSize, height: spinnerSize)
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                ZStack {
                    CachedAvatarView(url: profile?.picture, size: avatarSize)
                        .opacity(avatarRevealed ? 1 : 0)
                    Circle()
                        .trim(from: 0, to: ringDrawn)
                        .stroke(Color.wispPrimary, lineWidth: 4)
                        .frame(width: spinnerSize, height: spinnerSize)
                        .rotationEffect(.degrees(rotation))
                }
                .frame(width: spinnerSize, height: spinnerSize)
            }

            VStack(spacing: 8) {
                Text("Watch-only mode")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Text("You can read but not post — no private key is stored on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            if viewModel.isReady {
                Button("Let\u{2019}s go", action: onComplete)
                    .buttonStyle(.borderedProminent)
                    .tint(.wispPrimary)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Spacer().frame(height: 48)
        }
        .animation(.easeInOut, value: viewModel.isReady)
        .onAppear {
            profile = ProfileRepository.shared.get(keypair.pubkey)
            withAnimation(.easeOut(duration: 0.45)) { ringDrawn = 0.7 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
                withAnimation(.easeIn(duration: 0.25)) { avatarRevealed = true }
            }
        }
    }
}

#Preview {
    OnboardingView(
        keypair: Keypair(privkey: "test", pubkey: "test"),
        onComplete: {}
    )
}
