import SwiftUI
import PhotosUI

/// Four-step new-user sign-up wizard. Distinct from the returning-user
/// `OnboardingView` (which only runs the outbox builder). Layout mirrors the
/// Android wisp `OnboardingScreen`/`OnboardingSuggestionsScreen`/
/// `OnboardingTopicsScreen`/`OnboardingFirstPostScreen` 1:1.
struct SignUpFlowView: View {
    var onComplete: (Keypair) -> Void

    @State private var viewModel = SignUpViewModel()
    @State private var step = 0

    var body: some View {
        // A `TabView(.page)` would let the user swipe horizontally back to
        // earlier steps — easy to do by accident and capable of jumping all
        // the way to the start of the flow. Drive the step transitions off
        // a simple switch instead so the only way forward (or back) is via
        // the explicit buttons each step provides.
        Group {
            switch step {
            case 0:
                ProfileStep(viewModel: viewModel, onNext: { advance() })
            case 1:
                SuggestionsStep(viewModel: viewModel, onNext: { advance() })
            case 2:
                TopicsStep(viewModel: viewModel, onNext: { advance() }, onSkip: { advance() })
            default:
                IntroNoteStep(
                    viewModel: viewModel,
                    onPosted: { finish() },
                    onSkip: { finish() }
                )
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing),
            removal: .move(edge: .leading)
        ))
        .background(Color.wispBackground.ignoresSafeArea())
        .task {
            viewModel.registerAccount()
            viewModel.startRelayDiscovery()
        }
    }

    private func advance() {
        withAnimation { step += 1 }
        switch step {
        case 1: viewModel.loadSuggestions()
        case 2: viewModel.loadTopics()
        default: break
        }
    }

    private func finish() {
        // Wait for the outbox builder kicked off in `finishFollowsStep` to
        // populate per-author write relays before handing off to `MainView`,
        // otherwise the first feed query has no scoreboard mappings for the
        // just-followed users and comes back empty.
        Task {
            await viewModel.awaitOutboxReady()
            // SparkWallet.storageDir is a single shared path today, so let the
            // signup-time wallet go before MainView's WalletStore stands up
            // its own SparkWallet against the same on-disk store.
            viewModel.tearDownSignupWallet()
            viewModel.markComplete()
            onComplete(viewModel.keypair)
        }
    }
}

// MARK: - Step 1: profile + relay discovery

private struct ProfileStep: View {
    @Bindable var viewModel: SignUpViewModel
    var onNext: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var pickedImage: UIImage?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer().frame(height: 40)

                avatarPicker

                Text("Add photo")
                    .font(.caption)
                    .foregroundStyle(Color.wispOnSurfaceVariant)

                Spacer().frame(height: 8)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Display name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Display name", text: $viewModel.name)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("About")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("About", text: $viewModel.about, axis: .vertical)
                        .lineLimit(3...3)
                        .textFieldStyle(.roundedBorder)
                }

                Spacer().frame(height: 8)

                Button {
                    Task {
                        await viewModel.finishProfileStep()
                        onNext()
                    }
                } label: {
                    Text(continueLabel).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.wispPrimary)
                .controlSize(.large)
                .disabled(!continueEnabled)

                relayStatus

                Spacer().frame(height: 32)
            }
            .padding(.horizontal, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(
            TapGesture().onEnded {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
        )
    }

    private var continueEnabled: Bool {
        let phaseReady = viewModel.relayPhase == .ready || viewModel.relayPhase == .failed
        let hasName = !viewModel.name.trimmingCharacters(in: .whitespaces).isEmpty
        return phaseReady && !viewModel.publishingProfile && !viewModel.uploading && hasName
    }

    private var continueLabel: String {
        if viewModel.publishingProfile { return "Publishing\u{2026}" }
        let phaseReady = viewModel.relayPhase == .ready || viewModel.relayPhase == .failed
        if !phaseReady { return "Please wait\u{2026}" }
        return "Continue"
    }

    private var avatarPicker: some View {
        PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
            ZStack {
                Circle()
                    .fill(Color.wispSurfaceVariant)
                    .frame(width: 96, height: 96)

                if let image = pickedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "camera.fill")
                        .font(.title2)
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                }

                if viewModel.uploading {
                    Circle()
                        .fill(Color.black.opacity(0.4))
                        .frame(width: 96, height: 96)
                    ProgressView().tint(.white)
                }
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                guard let data = try? await newItem.loadTransferable(type: Data.self) else { return }
                if let img = UIImage(data: data) { pickedImage = img }
                let mime = "image/jpeg"
                let bytes = pickedImage?.jpegData(compressionQuality: 0.85) ?? data
                await viewModel.uploadAvatar(data: bytes, mime: mime)
            }
        }
    }

    @ViewBuilder
    private var relayStatus: some View {
        let phase = viewModel.relayPhase
        let phaseReady = phase == .ready || phase == .failed
        HStack(spacing: 10) {
            if !phaseReady {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(phase.displayText)
                        .foregroundStyle(.secondary)
                    if phase == .testing, let url = viewModel.probingUrl {
                        Text(url.replacingOccurrences(of: "wss://", with: ""))
                            .font(.caption)
                            .foregroundStyle(Color.wispOnSurfaceVariant.opacity(0.7))
                    }
                }
            } else {
                Text(phase.displayText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.wispPrimary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: phaseReady ? .center : .leading)
        .padding(.top, 8)
    }
}

// MARK: - Step 2: suggested follows

private struct SuggestionsStep: View {
    @Bindable var viewModel: SignUpViewModel
    var onNext: () -> Void

    private static let creatorRoles: [String: String] = [
        "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d": "Creator of Nostr",
        "e2ccf7cf20403f3f2a4a55b328f0de3be38558a7d5f33632fdaaefc726c1c8eb": "Creator of Wisp"
    ]

    private var totalSelected: Int { viewModel.selectedFollows.count }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Spacer().frame(height: 24)

                    HStack {
                        Text("Find people to follow")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(Color.wispOnSurface)
                        Spacer()
                        #if DEBUG
                        Button("Skip", action: onNext)
                            .font(.callout)
                        #endif
                    }

                    Text("Follow at least 5 accounts to build your feed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    creatorsSection
                    activeNowSection
                    newsSection

                    Spacer().frame(height: 16)
                }
                .padding(.horizontal, 16)
            }

            Button {
                Task { await viewModel.finishFollowsStep() }
                onNext()
            } label: {
                Text(continueLabel).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.wispPrimary)
            .controlSize(.large)
            .disabled(totalSelected < 5)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var continueLabel: String {
        totalSelected >= 5
            ? "Follow \(totalSelected) accounts"
            : "Select at least 5 (\(totalSelected)/5)"
    }

    @ViewBuilder
    private var creatorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Meet the creators")
                .font(.headline)
                .foregroundStyle(Color.wispOnSurface)

            if viewModel.creators.loading {
                loadingRow(height: 80)
            } else if viewModel.creators.profiles.isEmpty {
                emptyRow("No creators right now")
            } else {
                HStack(spacing: 12) {
                    ForEach(viewModel.creators.profiles, id: \.pubkey) { profile in
                        CreatorCard(
                            profile: profile,
                            role: Self.creatorRoles[profile.pubkey] ?? "",
                            selected: viewModel.selectedFollows.contains(profile.pubkey),
                            onToggle: { viewModel.togglePubkey(profile.pubkey) }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var activeNowSection: some View {
        let profiles = viewModel.activeNow.profiles
        let allSelected = !profiles.isEmpty && profiles.allSatisfy { viewModel.selectedFollows.contains($0.pubkey) }

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Active right now")
                        .font(.headline)
                        .foregroundStyle(Color.wispOnSurface)
                    if !profiles.isEmpty {
                        Text("\(profiles.count) people posting right now")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !profiles.isEmpty {
                    Button {
                        viewModel.toggleFollowAll(.activeNow)
                    } label: {
                        Text(allSelected ? "Unfollow All" : "Follow All")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(allSelected
                                               ? Color.wispSurfaceVariant
                                               : Color.wispPrimary)
                            )
                            .foregroundStyle(allSelected ? Color.wispOnSurface : Color.white)
                    }
                    .buttonStyle(.plain)
                }
            }

            if viewModel.activeNow.loading {
                loadingRow(height: 60)
            } else if profiles.isEmpty {
                emptyRow("No active users found")
            } else {
                StackedAvatars(
                    profiles: profiles,
                    selected: viewModel.selectedFollows,
                    onToggle: { viewModel.togglePubkey($0) }
                )
            }
        }
    }

    @ViewBuilder
    private var newsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("News sources")
                .font(.headline)
                .foregroundStyle(Color.wispOnSurface)
            Text("Pick the news sources you want to follow")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer().frame(height: 4)

            if viewModel.news.loading {
                loadingRow(height: 60)
            } else if viewModel.news.profiles.isEmpty {
                emptyRow("No news sources found")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(viewModel.news.profiles, id: \.pubkey) { profile in
                            NewsCard(
                                profile: profile,
                                selected: viewModel.selectedFollows.contains(profile.pubkey),
                                onToggle: { viewModel.togglePubkey(profile.pubkey) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func loadingRow(height: CGFloat) -> some View {
        HStack {
            ProgressView().controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }

    private func emptyRow(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }
}

// MARK: - Step 3: topics (was hashtags)

private struct TopicsStep: View {
    @Bindable var viewModel: SignUpViewModel
    var onNext: () -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Spacer().frame(height: 24)

                    HStack {
                        Text("Follow topics")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(Color.wispOnSurface)
                        Spacer()
                        Button("Skip", action: onSkip).font(.callout)
                    }

                    Text("Pick a few hashtags so your feed has more to show")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    searchField

                    if !viewModel.topicQuery.isEmpty {
                        suggestionsDropdown
                    }

                    if !viewModel.selectedHashtags.isEmpty {
                        selectedSection
                    }

                    popularSection

                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }

            Button {
                viewModel.finishHashtagsStep()
                onNext()
            } label: {
                Text(continueLabel).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.wispPrimary)
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(
            TapGesture().onEnded {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
        )
    }

    private var continueLabel: String {
        let n = viewModel.selectedHashtags.count
        if n == 0 { return "Continue without topics" }
        return n == 1 ? "Follow 1 topic" : "Follow \(n) topics"
    }

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 8) {
            TextField("Search topics", text: $viewModel.topicQuery)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if !viewModel.topicQuery.isEmpty {
                if viewModel.topicSuggestions.isEmpty {
                    Button {
                        viewModel.addCustomTopic()
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3)
                            .foregroundStyle(Color.wispPrimary)
                    }
                } else {
                    Button {
                        viewModel.topicQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.wispOnSurfaceVariant)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var suggestionsDropdown: some View {
        if !viewModel.topicSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(viewModel.topicSuggestions, id: \.self) { topic in
                            Button {
                                viewModel.toggleHashtag(topic)
                                viewModel.topicQuery = ""
                            } label: {
                                HStack {
                                    Text("#\(topic)")
                                        .foregroundStyle(Color.wispOnSurface)
                                    Spacer()
                                    Image(systemName: "plus")
                                        .font(.callout)
                                        .foregroundStyle(Color.wispPrimary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.wispSurfaceVariant.opacity(0.5))
            )
        }
    }

    @ViewBuilder
    private var selectedSection: some View {
        let sorted = viewModel.selectedHashtags.sorted()
        VStack(alignment: .leading, spacing: 8) {
            Text("Your topics (\(sorted.count))")
                .font(.headline)
                .foregroundStyle(Color.wispOnSurface)

            FlowLayout {
                ForEach(sorted, id: \.self) { topic in
                    OnboardingFilterChip(
                        label: "#\(topic)",
                        selected: true,
                        leadingCheck: true,
                        action: { viewModel.toggleHashtag(topic) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var popularSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Popular topics")
                .font(.headline)
                .foregroundStyle(Color.wispOnSurface)

            if viewModel.loadingPopular {
                HStack {
                    ProgressView().controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 120)
            } else if viewModel.popularTopics.isEmpty {
                Text("Couldn't load trending topics — you can still search above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout {
                    ForEach(viewModel.popularTopics.prefix(40), id: \.self) { topic in
                        OnboardingFilterChip(
                            label: "#\(topic)",
                            selected: viewModel.selectedHashtags.contains(topic),
                            leadingCheck: false,
                            action: { viewModel.toggleHashtag(topic) }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Step 4: introduction note

private struct IntroNoteStep: View {
    @Bindable var viewModel: SignUpViewModel
    var onPosted: () -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Spacer().frame(height: 24)

                    HStack {
                        Text("Say hello to nostr")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(Color.wispOnSurface)
                        Spacer()
                        Button("Skip", action: onSkip)
                            .font(.callout)
                            .disabled(viewModel.publishingIntro || viewModel.postCountdown != nil)
                    }

                    Text("Post a short introduction with the #introductions hashtag — a few words about you and how you found wisp is plenty.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $viewModel.introContent)
                        .frame(minHeight: 220)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 12).fill(Color.wispSurface)
                        )
                        .scrollContentBackground(.hidden)
                        .disabled(viewModel.publishingIntro || viewModel.postCountdown != nil)

                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }

            bottomBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(
            TapGesture().onEnded {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
        )
        .onDisappear { viewModel.cancelPostCountdown() }
    }

    private var introIsEmpty: Bool {
        let trimmed = viewModel.introContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.lowercased() == "#introductions"
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let countdown = viewModel.postCountdown {
            IntroPostCountdownBar(
                countdown: countdown,
                onUndo: { viewModel.cancelPostCountdown() },
                onPostNow: {
                    viewModel.postIntroNow {
                        await MainActor.run { onPosted() }
                    }
                }
            )
        } else {
            Button {
                viewModel.startPostCountdown {
                    await MainActor.run { onPosted() }
                }
            } label: {
                if viewModel.publishingIntro {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Post introduction").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.wispPrimary)
            .controlSize(.large)
            .disabled(viewModel.publishingIntro || introIsEmpty)
        }
    }
}
