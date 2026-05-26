import SwiftUI
import UIKit

/// SwiftUI screen for the "Continue with Apple" flow. Direct port of
/// `GoogleAuthView`: same state machine, same shared subviews, only the
/// provider-name copy and the underlying view-model differ.
struct AppleAuthView: View {
    @State var viewModel = AppleAuthViewModel()
    var onCancel: () -> Void
    var onDone: (_ isNewAccount: Bool, _ keypair: Keypair) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.wispBackground.ignoresSafeArea()

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
    /// give `onChange` something cheap and stable to diff against.
    private var stateKey: String {
        switch viewModel.state {
        case .idle: return "idle"
        case .signingIn: return "signingIn"
        case .checkingICloud: return "checkingICloud"
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
        case .idle, .signingIn, .checkingICloud, .working, .done:
            let label: String = {
                switch viewModel.state {
                case .signingIn: return "Signing in with Apple\u{2026}"
                case .checkingICloud: return "Checking your iCloud backup\u{2026}"
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
                providerName: "Apple",
                attemptFailed: attemptFailed,
                onSubmit: { viewModel.submitRestorePin($0) }
            )

        case .choose(let backups):
            AuthFlowChooseBlock(
                providerStorageName: "iCloud",
                backups: backups,
                onRestore: { viewModel.restoreAccount(backupID: $0.backupID) },
                onCreate: { viewModel.createAnotherAccount() }
            )

        case .error(let msg):
            AuthFlowErrorBlock(message: msg, onRetry: { viewModel.reset() }, onCancel: onCancel)
        }
    }
}
