import SwiftUI

struct LoginView: View {
    var onLogin: (Keypair) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nsecInput = ""
    @State private var error: String?
    @State private var isSecure = true
    @State private var isLoading = false
    @State private var showRemoteSigner = false
    @State private var showQRScanner = false
    /// Pubkey derived from the current input. Used to look up + display the
    /// matching profile so the user can sanity-check that the key they
    /// pasted is the one they meant. Cleared when input goes invalid.
    @State private var previewPubkey: String?
    @State private var previewProfile: ProfileData?
    @State private var isLookingUpProfile = false
    /// Bumped on each input change so a stale debounced lookup can detect
    /// it's been superseded and bail without overwriting newer state.
    @State private var lookupGeneration: Int = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Bounded top spacer — keeps content anchored to a stable
                // top offset. A flexible Spacer() here would redistribute
                // every time the home indicator's safe-area inset changes
                // during sheet presentation, jumping every form element.
                Spacer().frame(maxHeight: 60)

                Image("WispLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)

                Text("Log In")
                    .font(.title.bold())
                    .foregroundStyle(.white)

                Text("Enter your nsec key")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Group {
                        if isSecure {
                            SecureField("nsec1...", text: $nsecInput)
                        } else {
                            TextField("nsec1...", text: $nsecInput)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                    Button {
                        isSecure.toggle()
                    } label: {
                        Image(systemName: isSecure ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showQRScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .onChange(of: nsecInput) { _, newValue in
                    error = nil
                    handleInputChange(newValue)
                }

                identityPreview

                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Button {
                    login()
                } label: {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Log In")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.wispPrimary)
                .controlSize(.large)
                .disabled(nsecInput.isEmpty || isLoading)

                HStack(spacing: 8) {
                    Rectangle().fill(.tertiary).frame(height: 1)
                    Text("OR").font(.caption.bold()).foregroundStyle(.tertiary)
                    Rectangle().fill(.tertiary).frame(height: 1)
                }
                .padding(.vertical, 4)

                Button {
                    showRemoteSigner = true
                } label: {
                    Label("Use a remote signer", systemImage: "link.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.wispPrimary)
                .controlSize(.large)

                Spacer()
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.wispBackground)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $showRemoteSigner) {
                Nip46LoginView { kp in
                    showRemoteSigner = false
                    onLogin(kp)
                }
            }
            .fullScreenCover(isPresented: $showQRScanner) {
                QRCodeScannerView(
                    onScanned: { value in handleScanned(value) },
                    onCancel: { showQRScanner = false }
                )
                .ignoresSafeArea()
            }
        }
        .presentationDetents([.large])
        // Paint the sheet's container background so the wisp color is in
        // place from frame one — without this the sheet renders the system
        // default behind the still-laying-out VStack and the buttons appear
        // to jump as the background settles in around them.
        .presentationBackground(Color.wispBackground)
    }

    /// Avatar + name pulled from the pubkey the user is typing. Renders a
    /// fixed-height slot so the layout doesn't jump when the preview
    /// appears mid-typing.
    @ViewBuilder
    private var identityPreview: some View {
        if let pubkey = previewPubkey {
            HStack(spacing: 12) {
                CachedAvatarView(url: previewProfile?.picture, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(previewProfile?.displayString ?? shortNpub(hex: pubkey))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let nip05 = previewProfile?.nip05, !nip05.isEmpty {
                        Text(nip05)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if isLookingUpProfile {
                        Text("Looking up profile…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if previewProfile == nil {
                        Text("No profile published")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.wispSurfaceVariant.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 12))
            .transition(.opacity)
        } else {
            // Reserve the slot so the layout doesn't shift when the
            // preview pops in. Same height as the populated card above.
            Color.clear.frame(height: 64)
        }
    }

    private func handleInputChange(_ newValue: String) {
        // Resolve the pubkey synchronously — parse is cheap.
        let parsed = NostrKey.parseNsec(newValue)
        if let kp = parsed {
            // Reset only when the pubkey actually changes; otherwise we'd
            // erase the in-flight profile and re-fetch on every keystroke.
            if previewPubkey != kp.pubkey {
                previewPubkey = kp.pubkey
                previewProfile = ProfileRepository.shared.get(kp.pubkey)
                isLookingUpProfile = previewProfile == nil
                lookupGeneration += 1
                debouncedProfileLookup(pubkey: kp.pubkey, generation: lookupGeneration)
            }
        } else {
            previewPubkey = nil
            previewProfile = nil
            isLookingUpProfile = false
        }
    }

    private func debouncedProfileLookup(pubkey: String, generation: Int) {
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard generation == lookupGeneration, previewPubkey == pubkey else { return }

            // Already cached locally → done.
            if let cached = ProfileRepository.shared.get(pubkey) {
                previewProfile = cached
                isLookingUpProfile = false
                return
            }

            isLookingUpProfile = true
            let results = await RelayPool.query(
                relays: RelayDefaults.indexers,
                filter: NostrFilter(kinds: [0], authors: [pubkey], limit: 5),
                timeout: 6
            )
            guard generation == lookupGeneration, previewPubkey == pubkey else { return }
            isLookingUpProfile = false
            if let best = results.filter({ $0.kind == 0 }).max(by: { $0.createdAt < $1.createdAt }),
               let updated = ProfileRepository.shared.updateFromEvent(best) {
                previewProfile = updated
            }
        }
    }

    /// Local npub-short fallback (`npub1abcd…wxyz`) so the preview never
    /// surfaces a raw hex pubkey while the profile is still loading.
    /// Mirrors the helper introduced on PR #63; inlined here to keep this
    /// branch independent.
    private func shortNpub(hex: String) -> String {
        guard let data = Hex.decode(hex), data.count == 32,
              let full = Nip19.npubEncode(pubkey: Array(data)) else {
            return String(hex.prefix(8)) + "\u{2026}"
        }
        return "\(full.prefix(9))\u{2026}\(full.suffix(4))"
    }

    private func handleScanned(_ value: String) {
        showQRScanner = false
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        // nsec1… or 64-char hex private key — reuse existing parse + save path.
        if let keypair = NostrKey.parseNsec(trimmed) {
            NostrKey.save(keypair)
            onLogin(keypair)
            return
        }

        // npub1, nprofile1 — watch-only account (browse without signing).
        // decodeNostrUri lowercases internally so case in the QR payload doesn't matter.
        if let uriData = Nip19.decodeNostrUri(trimmed),
           case .profileRef(let pubkeyHex, _) = uriData {
            NostrKey.saveRemote(pubkey: pubkeyHex)
            onLogin(Keypair(privkey: "", pubkey: pubkeyHex))
            return
        }

        error = "Unrecognized format. Scan an nsec, npub, nprofile, or hex private key."
    }

    private func login() {
        error = nil
        isLoading = true
        let input = nsecInput
        Task {
            let result = NostrKey.parseNsec(input)
            isLoading = false
            guard let keypair = result else {
                error = "Invalid key. Enter an nsec or hex private key."
                return
            }
            NostrKey.save(keypair)
            onLogin(keypair)
        }
    }
}
