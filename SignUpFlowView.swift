import SwiftUI
import PhotosUI

/// Four-step new-user sign-up wizard. Distinct from the returning-user
/// `OnboardingView` (which only runs the outbox builder).
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
                HashtagsStep(viewModel: viewModel, onNext: { advance() }, onSkip: { advance() })
            default:
                IntroNoteStep(
                    viewModel: viewModel,
                    onPost: {
                        Task {
                            await viewModel.publishIntroNote()
                            finish()
                        }
                    },
                    onSkip: { finish() }
                )
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing),
            removal: .move(edge: .leading)
        ))
        // Bleed the bg color into the safe area so the screen stays uniform
        // edge-to-edge, but keep step content inside the safe area so titles
        // don't sit under the dynamic island / home indicator.
        .background(Color.wispBackground.ignoresSafeArea())
        .task {
            viewModel.registerAccount()
            viewModel.startRelayDiscovery()
        }
    }

    private func advance() {
        withAnimation { step += 1 }
        if step == 1 { viewModel.loadSuggestions() }
    }

    private func finish() {
        viewModel.markComplete()
        onComplete(viewModel.keypair)
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
            VStack(spacing: 20) {
                Spacer().frame(height: 40)

                Text("Create your profile")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)

                Text("You can change this later")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                avatarPicker

                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Your name", text: $viewModel.name)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Bio").font(.caption).foregroundStyle(.secondary)
                    TextField("A short bio", text: $viewModel.about, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.roundedBorder)
                }

                relayStatus

                Spacer(minLength: 24)

                Button {
                    Task {
                        await viewModel.finishProfileStep()
                        onNext()
                    }
                } label: {
                    if viewModel.publishingProfile {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Continue").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.wispPrimary)
                .controlSize(.large)
                .disabled(!continueEnabled)

                Spacer().frame(height: 32)
            }
            .padding(.horizontal, 32)
        }
    }

    private var continueEnabled: Bool {
        let phaseReady = viewModel.relayPhase == .ready || viewModel.relayPhase == .failed
        return phaseReady && !viewModel.publishingProfile && !viewModel.uploading
    }

    private var avatarPicker: some View {
        PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
            ZStack {
                Circle()
                    .fill(Color.wispSurfaceVariant)
                    .frame(width: 120, height: 120)

                if let image = pickedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 120, height: 120)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "camera.fill")
                        .font(.title)
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                }

                if viewModel.uploading {
                    Circle()
                        .fill(Color.black.opacity(0.4))
                        .frame(width: 120, height: 120)
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
        HStack(spacing: 10) {
            switch phase {
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Found \(viewModel.discoveredRelays.count) relays")
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text(phase.displayText).foregroundStyle(.secondary)
            default:
                ProgressView().controlSize(.small)
                Text(phase.displayText).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

// MARK: - Step 2: suggested follows

private struct SuggestionsStep: View {
    @Bindable var viewModel: SignUpViewModel
    var onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Spacer().frame(height: 24)

                    Text("Find your people")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Follow a few accounts to fill your feed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    suggestionSection(.creators, suggestions: viewModel.creators)
                    suggestionSection(.activeNow, suggestions: viewModel.activeNow)
                    suggestionSection(.news, suggestions: viewModel.news)

                    Spacer().frame(height: 16)
                }
                .padding(.horizontal, 16)
            }

            Button {
                // Fire-and-forget: kind-3 publish takes up to ~6s waiting on
                // relay acks. Advancing immediately keeps the flow snappy;
                // the Task captures `viewModel`, so it survives the view's
                // unmount and finishes in the background.
                Task { await viewModel.finishFollowsStep() }
                onNext()
            } label: {
                Text("Continue (\(viewModel.selectedFollows.count) selected)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.wispPrimary)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .disabled(viewModel.selectedFollows.isEmpty)
        }
    }

    @ViewBuilder
    private func suggestionSection(_ section: SignUpViewModel.SuggestionSection,
                                   suggestions: SignUpViewModel.Suggestions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(section.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                if !suggestions.profiles.isEmpty {
                    Button("Follow all") { viewModel.toggleFollowAll(section) }
                        .font(.caption)
                        .foregroundStyle(Color.wispPrimary)
                }
            }

            if suggestions.loading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading\u{2026}").font(.caption).foregroundStyle(.secondary)
                }
                .frame(height: 60)
            } else if suggestions.profiles.isEmpty {
                Text("No suggestions right now")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 60)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(suggestions.profiles, id: \.pubkey) { profile in
                            SuggestedAccountCell(
                                profile: profile,
                                selected: viewModel.selectedFollows.contains(profile.pubkey),
                                onToggle: { viewModel.togglePubkey(profile.pubkey) }
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct SuggestedAccountCell: View {
    let profile: ProfileData
    let selected: Bool
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    AsyncImage(url: profile.picture.flatMap(URL.init(string:))) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Circle().fill(Color.wispSurfaceVariant)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())

                    Spacer()

                    Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.wispPrimary : Color.secondary)
                }

                Text(profile.displayString)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(profile.about ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .padding(12)
            .frame(width: 200, height: 150, alignment: .topLeading)
            .background(Color.wispSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color.wispPrimary : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 3: hashtags

private struct HashtagsStep: View {
    @Bindable var viewModel: SignUpViewModel
    var onNext: () -> Void
    var onSkip: () -> Void

    @State private var customInput = ""

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Spacer().frame(height: 24)

                    Text("Pick your interests")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Hashtags you follow appear as feeds in your sidebar")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(SignUpViewModel.popularHashtags, id: \.self) { tag in
                            chip(for: tag)
                        }
                        ForEach(customTags, id: \.self) { tag in
                            chip(for: tag)
                        }
                    }

                    HStack {
                        TextField("Add a hashtag", text: $customInput)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Add") {
                            viewModel.toggleHashtag(customInput)
                            customInput = ""
                        }
                        .disabled(customInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.horizontal, 32)
            }

            HStack(spacing: 12) {
                Button("Skip", action: onSkip)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                Button {
                    viewModel.finishHashtagsStep()
                    onNext()
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.wispPrimary)
                .controlSize(.large)
                .disabled(viewModel.selectedHashtags.isEmpty)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
    }

    private var customTags: [String] {
        let popular = Set(SignUpViewModel.popularHashtags)
        return viewModel.selectedHashtags.subtracting(popular).sorted()
    }

    @ViewBuilder
    private func chip(for tag: String) -> some View {
        let selected = viewModel.selectedHashtags.contains(tag)
        Button {
            viewModel.toggleHashtag(tag)
        } label: {
            Text("#\(tag)")
                .font(.subheadline)
                .foregroundStyle(selected ? Color.white : Color.wispOnSurface)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selected ? Color.wispPrimary : Color.wispSurface,
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 4: introduction note

private struct IntroNoteStep: View {
    @Bindable var viewModel: SignUpViewModel
    var onPost: () -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 24)

            Text("Say hello")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)

            Text("Introduce yourself with #introductions and people in the network can find you")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            TextEditor(text: $viewModel.introContent)
                .frame(minHeight: 220)
                .padding(8)
                .background(Color.wispSurface, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .scrollContentBackground(.hidden)

            Spacer()

            HStack(spacing: 12) {
                Button("Skip", action: onSkip)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                Button(action: onPost) {
                    if viewModel.publishingIntro {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Post").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.wispPrimary)
                .controlSize(.large)
                .disabled(viewModel.publishingIntro || introIsEmpty)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
    }

    private var introIsEmpty: Bool {
        let trimmed = viewModel.introContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.lowercased() == "#introductions"
    }
}
