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
                AuthFlowHeader()
                Spacer().frame(height: 32)
                contentBlock
                    .padding(.horizontal, 32)
                Spacer()
            }
        }
        .onAppear {
            if case .idle = viewModel.state {
                if let presenter = authFlowTopMostViewController() {
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
            AuthFlowLoadingBlock(label: label)

        case .setupPin(let step, let mismatch):
            AuthFlowSetupPinBlock(
                isEntry: step == .enter,
                mismatch: mismatch,
                onSubmitEntry: { viewModel.submitSetupPinEntry($0) },
                onSubmitConfirm: { viewModel.submitSetupPinConfirm($0) },
                onBackToEntry: { viewModel.backToSetupEntry() }
            )

        case .enterPinForRestore(let attemptFailed):
            AuthFlowRestorePinBlock(
                providerName: "Google",
                attemptFailed: attemptFailed,
                onSubmit: { viewModel.submitRestorePin($0) }
            )

        case .choose(let backups):
            AuthFlowChooseBlock(
                providerStorageName: "Google Drive",
                backups: backups,
                onRestore: { viewModel.restoreAccount(backupID: $0.backupID) },
                onCreate: { viewModel.createAnotherAccount() }
            )

        case .error(let msg):
            AuthFlowErrorBlock(message: msg, onRetry: { viewModel.reset() }, onCancel: onCancel)
        }
    }
}
