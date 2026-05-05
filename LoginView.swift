import SwiftUI

struct LoginView: View {
    var onLogin: (Keypair) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nsecInput = ""
    @State private var error: String?
    @State private var isSecure = true
    @State private var isLoading = false
    @State private var showRemoteSigner = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

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
                }
                .onChange(of: nsecInput) { error = nil }

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
            .background(Color.wispBackground)
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
        }
        .presentationDetents([.medium, .large])
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
