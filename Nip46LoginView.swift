import SwiftUI

/// Remote-signer login screen. Reachable from `LoginView` via the "Use a remote
/// signer" link. Two equally-prominent paths share one screen:
///   1. **Paste a bunker URI** — for users who already have one in their signer
///      app's "Export bunker URL" / "Connect" UI (Clave, Primal, Amber).
///   2. **Show a nostrconnect QR** — for users who'd rather scan from the
///      signer end (Clave, Primal mobile, Amber from "Add account").
struct Nip46LoginView: View {
    var onLogin: (Keypair) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var vm = Nip46LoginViewModel()
    @State private var copiedAcknowledgement = false

    var body: some View {
        // `@Observable` view models can't be bound via `$` from a child
        // computed property, so the few inputs in this view use explicit
        // `Binding(get:set:)` constructions instead.
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.wispPrimary)
                        .padding(.top, 8)

                    Text("Remote Signer")
                        .font(.title2.bold())

                    Text("Sign in with a NIP-46 signer (Clave, Primal, Amber). Your private key never leaves the signer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Picker("Mode", selection: modeBinding) {
                        ForEach(Nip46LoginViewModel.Mode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(vm.isWorking)

                    Group {
                        switch vm.mode {
                        case .bunker: bunkerSection
                        case .nostrconnect: nostrConnectSection
                        }
                    }

                    if let err = vm.displayError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    if case .connecting(let msg) = vm.status {
                        ProgressView(msg)
                    }
                }
                .padding()
            }
            .background(Color.wispBackground)
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        vm.cancelPendingHandshake()
                        dismiss()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .onChange(of: vm.status) { _, status in
                if case .connected(let pubkey) = status {
                    onLogin(Keypair(privkey: "", pubkey: pubkey))
                }
            }
            .onChange(of: vm.mode) { _, _ in
                vm.cancelPendingHandshake()
                vm.status = .idle
            }
            .onDisappear {
                vm.cancelPendingHandshake()
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Bindings

    private var modeBinding: Binding<Nip46LoginViewModel.Mode> {
        Binding(get: { vm.mode }, set: { vm.mode = $0 })
    }

    private var bunkerInputBinding: Binding<String> {
        Binding(get: { vm.bunkerURIInput }, set: { vm.bunkerURIInput = $0 })
    }

    // MARK: - Bunker section

    @ViewBuilder
    private var bunkerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste a bunker:// URI from your signer.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: bunkerInputBinding)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(alignment: .topLeading) {
                    if vm.bunkerURIInput.isEmpty {
                        Text("bunker://abc123...?relay=wss://...&secret=...")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(14)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(vm.isWorking)

            HStack {
                Button {
                    if let s = pasteboardString() { vm.bunkerURIInput = s }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
                .tint(.wispPrimary)
                .disabled(vm.isWorking)

                Spacer()

                Button {
                    Task { await vm.submitBunker() }
                } label: {
                    if vm.isWorking {
                        ProgressView()
                    } else {
                        Text("Connect").bold()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.wispPrimary)
                .disabled(vm.isWorking || vm.bunkerURIInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("Where do I find this?", systemImage: "info.circle")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text("Open your signer app and look for **Export Bunker URL**, **Add Account**, or **Connect**. Clave and Primal expose this directly. The URI starts with `bunker://`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Nostrconnect section

    @ViewBuilder
    private var nostrConnectSection: some View {
        VStack(spacing: 14) {
            if let uri = vm.pendingURI {
                Text("Open your signer and add a new account by scanning this code, or paste the URI.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                QRCodeImage(payload: uri, sideLength: 240, correctionLevel: "M")
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 12).fill(.white)
                    )

                Button {
                    vm.copyURIToPasteboard()
                    copiedAcknowledgement = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.4))
                        copiedAcknowledgement = false
                    }
                } label: {
                    Label(copiedAcknowledgement ? "Copied" : "Copy URI",
                          systemImage: copiedAcknowledgement ? "checkmark" : "doc.on.doc")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
                .tint(.wispPrimary)

                Text(uri)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal)

                ProgressView("Waiting for signer to approve…")
                    .padding(.top, 4)
            } else {
                Text("We'll show you a QR code that your signer (Clave, Primal, Amber, …) can scan to connect.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button {
                    vm.startNostrConnect()
                } label: {
                    Text("Generate QR Code").bold().frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.wispPrimary)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Helpers

    private func pasteboardString() -> String? {
        #if canImport(UIKit)
        return UIPasteboard.general.string
        #else
        return nil
        #endif
    }
}
