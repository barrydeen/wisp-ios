import SwiftUI
import UIKit

/// Shared UI building blocks for the cloud-backup auth flows (Google +
/// Apple). Lifted from `GoogleAuthView.swift` so both flows render the same
/// PIN entry, account chooser, error, and loading screens. Provider-specific
/// copy (e.g. "Google" vs "Apple", "Google Drive" vs "iCloud") is passed in
/// as a `providerName` parameter where it appears in user-facing text.

/// One backup entry rendered in the account chooser. Provider-agnostic: the
/// `backupID` is opaque (Drive file ID or iCloud Keychain account) and round
/// trips back to the originating view-model when the user taps a row.
struct AuthBackupSummary: Identifiable, Equatable {
    let backupID: String
    let npub: String
    let pubkeyHex: String
    var displayName: String?
    var picture: String?
    var id: String { npub }
}

// MARK: - Header

struct AuthFlowHeader: View {
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

// MARK: - Loading

struct AuthFlowLoadingBlock: View {
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

// MARK: - PIN setup (enter + confirm)

struct AuthFlowSetupPinBlock: View {
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

            AuthFlowPinField(
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

// MARK: - PIN restore

struct AuthFlowRestorePinBlock: View {
    let providerName: String
    let attemptFailed: Bool
    let onSubmit: (String) -> Void

    @State private var pin: String = ""

    var body: some View {
        VStack(spacing: 12) {
            Text("Enter your recovery PIN")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text("This is the PIN you set when you first signed in to Wisp with this \(providerName) account.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            AuthFlowPinField(
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

// MARK: - PIN field

struct AuthFlowPinField: View {
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

// MARK: - Account chooser

struct AuthFlowChooseBlock: View {
    let providerStorageName: String
    let backups: [AuthBackupSummary]
    let onRestore: (AuthBackupSummary) -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Your backed-up accounts")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text("Tap an account to restore it, or create a new one. New accounts are encrypted and added to your \(providerStorageName) backup.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(backups) { backup in
                        AuthFlowBackupRow(backup: backup, onTap: { onRestore(backup) })
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

struct AuthFlowBackupRow: View {
    let backup: AuthBackupSummary
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                CachedAvatarView(url: backup.picture, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(backup.displayName?.authFlowNonEmpty ?? Self.formatShortNpub(backup.npub))
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

// MARK: - Error block

struct AuthFlowErrorBlock: View {
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

extension String {
    var authFlowNonEmpty: String? { isEmpty ? nil : self }
}

/// Walks the active foreground scene to find the top-most presented view
/// controller. Google's SDK and Apple's `ASAuthorizationController` both
/// need a real `UIViewController` to anchor their consent UI; SwiftUI
/// doesn't hand us one directly.
@MainActor
func authFlowTopMostViewController() -> UIViewController? {
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
