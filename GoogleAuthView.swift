import SwiftUI
import UIKit

/// SwiftUI screen mirroring the Android `GoogleAuthScreen`. Drives the
/// view-model state machine through sign-in → check Drive → (set/enter PIN)
/// → choose/restore/create → done.
struct GoogleAuthView: View {
    @State var viewModel = GoogleAuthViewModel()
    var onCancel: () -> Void
    var onDone: (_ isNewAccount: Bool, _ keypair: Keypair) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.wispBackground.ignoresSafeArea()

            // Back arrow — Android equivalent: IconButton at TopStart.
            Button {
                viewModel.reset()
                onCancel()
            } label: {
                Image(systemName: "arrow.backward")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(12)
            }
            .padding(.top, 4)

            VStack(spacing: 0) {
                Spacer()
                Header()
                Spacer().frame(height: 32)
                contentBlock
                    .padding(.horizontal, 32)
                Spacer()
            }
        }
        .onAppear {
            if case .idle = viewModel.state {
                if let presenter = topMostViewController() {
                    viewModel.beginSignIn(presenting: presenter)
                } else {
                    onCancel()
                }
            }
        }
        .onChange(of: stateKey) { _, _ in
            if case .done(let isNew, let kp) = viewModel.state {
                onDone(isNew, kp)
                viewModel.reset()
            }
        }
    }

    /// `State` isn't `Equatable` (associated values include a `Keypair`), so
    /// give `onChange` something cheap and stable to diff against. Any state
    /// transition flips this key.
    private var stateKey: String {
        switch viewModel.state {
        case .idle: return "idle"
        case .signingIn: return "signingIn"
        case .checkingDrive: return "checkingDrive"
        case .enterPinForRestore(let failed): return "enterPin:\(failed)"
        case .setupPin(let step, let mismatch): return "setupPin:\(step):\(mismatch)"
        case .choose(let backups): return "choose:\(backups.map { $0.npub }.joined(separator: ","))"
        case .working: return "working"
        case .done(let isNew, _): return "done:\(isNew)"
        case .error(let msg): return "error:\(msg)"
        }
    }

    @ViewBuilder
    private var contentBlock: some View {
        switch viewModel.state {
        case .idle, .signingIn, .checkingDrive, .working, .done:
            let label: String = {
                switch viewModel.state {
                case .signingIn: return "Signing in with Google\u{2026}"
                case .checkingDrive: return "Checking your Google Drive backup\u{2026}"
                case .working, .done: return "Almost there\u{2026}"
                default: return "Starting\u{2026}"
                }
            }()
            LoadingBlock(label: label)

        case .setupPin(let step, let mismatch):
            SetupPinBlock(
                isEntry: step == .enter,
                mismatch: mismatch,
                onSubmitEntry: { viewModel.submitSetupPinEntry($0) },
                onSubmitConfirm: { viewModel.submitSetupPinConfirm($0) },
                onBackToEntry: { viewModel.backToSetupEntry() }
            )

        case .enterPinForRestore(let attemptFailed):
            RestorePinBlock(
                attemptFailed: attemptFailed,
                onSubmit: { viewModel.submitRestorePin($0) }
            )

        case .choose(let backups):
            ChooseBlock(
                backups: backups,
                onRestore: { viewModel.restoreAccount(fileId: $0.fileId) },
                onCreate: { viewModel.createAnotherAccount() }
            )

        case .error(let msg):
            ErrorBlock(message: msg, onRetry: { viewModel.reset() }, onCancel: onCancel)
        }
    }
}

// MARK: - Subviews

private struct Header: View {
    var body: some View {
        VStack(spacing: 0) {
            Image("WispLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
            Text("wisp")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.white)
        }
    }
}

private struct LoadingBlock: View {
    let label: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.wispPrimary)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SetupPinBlock: View {
    let isEntry: Bool
    let mismatch: Bool
    let onSubmitEntry: (String) -> Void
    let onSubmitConfirm: (String) -> Void
    let onBackToEntry: () -> Void

    @State private var pin: String = ""

    var body: some View {
        VStack(spacing: 12) {
            Text(isEntry ? "Set a recovery PIN" : "Confirm your PIN")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text(isEntry
                 ? "Pick a 4\u{2013}8 digit PIN. You\u{2019}ll need it to restore your account on a new device."
                 : "Enter your PIN again to make sure you remember it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if isEntry {
                Text("If you forget this PIN, your Nostr key is lost forever \u{2014} there is no reset.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }

            PinField(
                pin: $pin,
                errorText: isEntry && mismatch ? "PINs didn\u{2019}t match. Try again." : nil,
                onSubmit: { submit() }
            )
            .padding(.top, 8)

            Button(action: submit) {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.wispPrimary)
            .controlSize(.large)
            .disabled(pin.count < 4 || pin.count > 8)
            .padding(.top, 8)

            if !isEntry {
                Button("Back", action: onBackToEntry)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .onChange(of: isEntry) { _, _ in pin = "" }
    }

    private func submit() {
        if isEntry { onSubmitEntry(pin) } else { onSubmitConfirm(pin) }
    }
}

private struct RestorePinBlock: View {
    let attemptFailed: Bool
    let onSubmit: (String) -> Void

    @State private var pin: String = ""

    var body: some View {
        VStack(spacing: 12) {
            Text("Enter your recovery PIN")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text("This is the PIN you set when you first signed in to Wisp with this Google account.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            PinField(
                pin: $pin,
                errorText: attemptFailed ? "Incorrect PIN. Try again." : nil,
                onSubmit: { onSubmit(pin) }
            )
            .padding(.top, 8)

            Button {
                onSubmit(pin)
            } label: {
                Text("Unlock").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.wispPrimary)
            .controlSize(.large)
            .disabled(pin.count < 4 || pin.count > 8)
            .padding(.top, 8)
        }
    }
}

private struct PinField: View {
    @Binding var pin: String
    let errorText: String?
    let onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField("PIN", text: $pin)
                .focused($focused)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .submitLabel(.done)
                .onSubmit { onSubmit() }
                .onChange(of: pin) { _, newValue in
                    let filtered = String(newValue.filter { $0.isASCII && $0.isNumber }.prefix(8))
                    if filtered != newValue { pin = filtered }
                }
                .padding(12)
                .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(errorText != nil ? Color.red : Color.wispOutline.opacity(0.4), lineWidth: 1)
                )

            Text(errorText ?? "Use 4\u{2013}8 digits")
                .font(.caption)
                .foregroundStyle(errorText != nil ? .red : .secondary)
                .padding(.leading, 4)
        }
        .onAppear { focused = true }
    }
}

private struct ChooseBlock: View {
    let backups: [GoogleAuthViewModel.BackupSummary]
    let onRestore: (GoogleAuthViewModel.BackupSummary) -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Your backed-up accounts")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text("Tap an account to restore it, or create a new one. New accounts are encrypted and added to your Google Drive backup.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(backups) { backup in
                        BackupRow(backup: backup, onTap: { onRestore(backup) })
                    }
                }
                .padding(.top, 8)
            }
            .frame(maxHeight: 280)

            Divider().background(Color.wispOutline)

            Button(action: onCreate) {
                Text("Create another account").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.wispPrimary)
            .controlSize(.large)
        }
    }
}

private struct BackupRow: View {
    let backup: GoogleAuthViewModel.BackupSummary
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                CachedAvatarView(url: backup.picture, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(backup.displayName?.nonEmpty ?? Self.formatShortNpub(backup.npub))
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private static func formatShortNpub(_ npub: String) -> String {
        guard npub.count > 18 else { return npub }
        return "\(npub.prefix(12))\u{2026}\(npub.suffix(6))"
    }
}

private struct ErrorBlock: View {
    let message: String
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)

            Button(action: onRetry) {
                Text("Retry").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.wispPrimary)
            .controlSize(.large)

            Button(action: onCancel) {
                Text("Cancel").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.wispPrimary)
            .controlSize(.large)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Walks the active foreground scene to find the top-most presented view
/// controller. GoogleSignIn-iOS needs an actual `UIViewController` to anchor
/// its consent sheet; SwiftUI doesn't hand us one directly.
@MainActor
private func topMostViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first(where: { $0.activationState == .foregroundActive })
        ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        ?? scene?.windows.first?.rootViewController else { return nil }
    var top = root
    while let presented = top.presentedViewController {
        top = presented
    }
    return top
}
