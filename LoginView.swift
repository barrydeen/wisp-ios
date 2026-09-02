import SwiftUI

struct LoginView: View {
    var onLogin: (Keypair) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nsecInput = ""
    @State private var error: String?
    @State private var isSecure = true
    @State private var isLoading = false
    @State private var showQRScanner = false
    @State private var showSignUp = false

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
                    .foregroundStyle(Color.wispOnSurface)

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
                .onChange(of: nsecInput) { _, _ in error = nil }

                NsecIdentityPreview(nsecInput: nsecInput)

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
                    showSignUp = true
                } label: {
                    Label("Create a new account", systemImage: "person.badge.plus")
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
            // Pinned to the top-leading corner so it stays clear of the
            // Log In button and of the keyboard. At .bottom with a fixed
            // 120pt inset it overlapped the action buttons, and
            // white-on-15%-white read as scenery rather than a button.
            .overlay(alignment: .topLeading) {
                Button(action: { dismiss() }) {
                    Text("Cancel")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.92), in: Capsule())
                }
                .padding(.leading, 16)
                .padding(.top, 16)
            }
            .fullScreenCover(isPresented: $showQRScanner) {
                QRCodeScannerView(
                    onScanned: { value in handleScanned(value) },
                    onCancel: { showQRScanner = false }
                )
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showSignUp) {
                SignUpFlowView { kp in
                    showSignUp = false
                    onLogin(kp)
                }
            }
        }
        .presentationDetents([.large])
        // Paint the sheet's container background so the wisp color is in
        // place from frame one — without this the sheet renders the system
        // default behind the still-laying-out VStack and the buttons appear
        // to jump as the background settles in around them.
        .presentationBackground(Color.wispBackground)
        .onAppear { nsecPasteAllowed = true }
        .onDisappear { nsecPasteAllowed = false }
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
        // Onboarding still runs (in its watch-only variant) so the user's kind-10002
        // gets ingested and the relay scoreboard is built — otherwise the feed is empty.
        if let uriData = Nip19.decodeNostrUri(trimmed),
           case .profileRef(let pubkeyHex, _) = uriData {
            NostrKey.saveWatchOnly(pubkey: pubkeyHex)
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
                error = "Couldn't read that key. Paste an nsec (\"nsec1…\") or a 64-character hex private key."
                return
            }
            NostrKey.save(keypair)
            onLogin(keypair)
        }
    }
}
