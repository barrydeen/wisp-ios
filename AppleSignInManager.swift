import Foundation
import UIKit
import AuthenticationServices

/// Sign in with Apple wrapper, parallel to `GoogleSignInManager`. Returns
/// the team-scoped, opaque `ASAuthorizationAppleIDCredential.user`
/// identifier — the Apple analogue of Google's JWT `sub` claim. Used as
/// the per-account salt input for `BackupCrypto.deriveBackupKey(appleUserID:pin:)`.
///
/// `ASAuthorizationController` is a UIKit-style delegate-based API, so we
/// bridge to async/await with a strongly-retained `NSObject` coordinator.
/// Without the strong retain Apple's framework deallocates the delegate
/// mid-flow and the callbacks never fire (or crash on a dangling pointer).
@MainActor
final class AppleSignInManager {
    struct AuthResult {
        let userID: String
    }

    enum SignInError: LocalizedError {
        case notAvailable
        case cancelled
        case credentialRevoked
        case credentialNotFound
        case missingUserIdentifier
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .notAvailable:
                return "Sign in to iCloud in Settings to use Continue with Apple."
            case .cancelled:
                return "Apple sign-in cancelled."
            case .credentialRevoked:
                return "Your Apple sign-in for Wisp was revoked. Sign in again."
            case .credentialNotFound:
                return "Apple sign-in credential not found."
            case .missingUserIdentifier:
                return "Apple did not return a user identifier."
            case .underlying(let e):
                return e.localizedDescription
            }
        }
    }

    /// Strongly retained until the continuation resumes. Clearing this on
    /// the main actor after `continuation.resume` is what lets `ARC` release
    /// the controller + delegate chain.
    private var activeCoordinator: Coordinator?

    /// Drives the Sign in with Apple system sheet to completion and returns
    /// the stable opaque user identifier. Throws `.notAvailable` without
    /// presenting any UI if iCloud is not signed in.
    func signIn(presenting: UIViewController) async throws -> AuthResult {
        if AppleAuthConfig.cachedIsAvailable == false {
            throw SignInError.notAvailable
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AuthResult, Error>) in
            let request = ASAuthorizationAppleIDProvider().createRequest()
            // `.fullName` / `.email` are only populated on the very first
            // consent for a given (team, Apple ID) — we don't use them, but
            // requesting them is the conventional shape and keeps the
            // consent sheet copy familiar to users.
            request.requestedScopes = [.fullName, .email]

            let controller = ASAuthorizationController(authorizationRequests: [request])
            let coordinator = Coordinator(
                presenting: presenting,
                continuation: continuation,
                cleanup: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.activeCoordinator = nil
                    }
                }
            )
            self.activeCoordinator = coordinator
            controller.delegate = coordinator
            controller.presentationContextProvider = coordinator
            controller.performRequests()
        }
    }

    /// Forward-looking helper: lets a future revision short-circuit the
    /// consent sheet if we ever persist `userID` across launches. Not used
    /// in v1.
    func verifyExistingCredential(userID: String) async throws {
        let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: userID)
        switch state {
        case .authorized: return
        case .revoked: throw SignInError.credentialRevoked
        case .notFound: throw SignInError.credentialNotFound
        case .transferred: throw SignInError.credentialNotFound
        @unknown default: throw SignInError.credentialNotFound
        }
    }

    // MARK: - Coordinator

    private final class Coordinator: NSObject,
                                     ASAuthorizationControllerDelegate,
                                     ASAuthorizationControllerPresentationContextProviding {
        private weak var presenting: UIViewController?
        private var continuation: CheckedContinuation<AuthResult, Error>?
        private let cleanup: () -> Void

        init(presenting: UIViewController,
             continuation: CheckedContinuation<AuthResult, Error>,
             cleanup: @escaping () -> Void) {
            self.presenting = presenting
            self.continuation = continuation
            self.cleanup = cleanup
        }

        func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
            if let window = presenting?.view.window {
                return window
            }
            // Mid-presentation animations can briefly null `view.window`.
            // Fall back to the foreground scene's key window.
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
            let foreground = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
            if let win = foreground?.windows.first(where: { $0.isKeyWindow }) ?? foreground?.windows.first {
                return win
            }
            return ASPresentationAnchor()
        }

        func authorizationController(controller: ASAuthorizationController,
                                     didCompleteWithAuthorization authorization: ASAuthorization) {
            defer { cleanup() }
            guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential else {
                resume(with: .failure(SignInError.missingUserIdentifier))
                return
            }
            let user = cred.user
            guard !user.isEmpty else {
                resume(with: .failure(SignInError.missingUserIdentifier))
                return
            }
            resume(with: .success(AuthResult(userID: user)))
        }

        func authorizationController(controller: ASAuthorizationController,
                                     didCompleteWithError error: Error) {
            defer { cleanup() }
            if let asErr = error as? ASAuthorizationError, asErr.code == .canceled {
                resume(with: .failure(SignInError.cancelled))
            } else {
                resume(with: .failure(SignInError.underlying(error)))
            }
        }

        private func resume(with result: Result<AuthResult, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            switch result {
            case .success(let value): continuation.resume(returning: value)
            case .failure(let err): continuation.resume(throwing: err)
            }
        }
    }
}
