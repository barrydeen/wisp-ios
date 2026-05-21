import Foundation
import UIKit
import GoogleSignIn

/// Two-step Google sign-in mirroring the Android `GoogleSignInManager`:
///   1. `GIDSignIn.signIn` returns a `GIDGoogleUser`. We pull the `sub` claim
///      out of its signed ID token — that's the stable Google account ID
///      (`profile.email` can change for workspace renames). The SDK has
///      already validated the JWT, so we only decode it; we don't re-verify
///      the signature.
///   2. The same call also requests an OAuth access token with the
///      `drive.appdata` scope as an `additionalScope`, so we get both tokens
///      from one consent screen.
///
/// `serverClientID` is set to the Android-side Web OAuth client so the ID
/// token's `aud` matches across platforms — without this, the `sub` claim a
/// user sees on iOS would differ from Android, and backups wouldn't decrypt
/// across platforms.
@MainActor
final class GoogleSignInManager {
    static let driveAppdataScope = "https://www.googleapis.com/auth/drive.appdata"

    struct AuthResult {
        let sub: String
        let accessToken: String
    }

    enum SignInError: LocalizedError {
        case notConfigured
        case cancelled
        case notSignedIn
        case missingIdToken
        case malformedIdToken
        case missingSubClaim
        case missingAccessToken
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Google sign-in is not configured."
            case .cancelled: return "Google sign-in cancelled."
            case .notSignedIn: return "Not signed in to Google."
            case .missingIdToken: return "Google did not return an ID token."
            case .malformedIdToken: return "Google ID token is malformed."
            case .missingSubClaim: return "Google ID token is missing the sub claim."
            case .missingAccessToken: return "Google did not return a Drive access token."
            case .underlying(let e): return e.localizedDescription
            }
        }
    }

    private let iosClientId: String
    private let webClientId: String

    init(iosClientId: String = GoogleAuthConfig.iosClientId,
         webClientId: String = GoogleAuthConfig.webClientId) {
        self.iosClientId = iosClientId
        self.webClientId = webClientId
    }

    /// Drives the consent UI to completion and returns both the stable Google
    /// `sub` (for the per-account backup salt) and a fresh `drive.appdata`
    /// access token (for Drive REST calls).
    func signIn(presenting: UIViewController) async throws -> AuthResult {
        guard !iosClientId.isEmpty, !webClientId.isEmpty else {
            throw SignInError.notConfigured
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: iosClientId,
            serverClientID: webClientId
        )

        let result: GIDSignInResult
        do {
            result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenting,
                hint: nil,
                additionalScopes: [Self.driveAppdataScope]
            )
        } catch let err as NSError {
            if err.domain == kGIDSignInErrorDomain,
               err.code == GIDSignInError.canceled.rawValue {
                throw SignInError.cancelled
            }
            throw SignInError.underlying(err)
        }

        return try extractAuthResult(from: result.user)
    }

    /// Drives `restorePreviousSignIn` + `refreshTokensIfNeeded`. Used after a
    /// Drive call comes back 401 — typically because the user revoked Wisp's
    /// authorization in their Google account settings. Mirrors Android's
    /// `GoogleAuthUtil.clearToken` + re-authorize path; the iOS SDK handles
    /// the token cache invalidation for us.
    func refreshDriveAccessToken() async throws -> String {
        let user: GIDGoogleUser
        if let current = GIDSignIn.sharedInstance.currentUser {
            user = current
        } else {
            do {
                user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            } catch {
                throw SignInError.notSignedIn
            }
        }

        do {
            let refreshed = try await user.refreshTokensIfNeeded()
            let token = refreshed.accessToken.tokenString
            if token.isEmpty { throw SignInError.missingAccessToken }
            return token
        } catch let signInError as SignInError {
            throw signInError
        } catch {
            throw SignInError.underlying(error)
        }
    }

    private func extractAuthResult(from user: GIDGoogleUser) throws -> AuthResult {
        guard let idTokenString = user.idToken?.tokenString else {
            throw SignInError.missingIdToken
        }
        let sub = try extractSubClaim(idTokenString)
        let accessToken = user.accessToken.tokenString
        guard !accessToken.isEmpty else { throw SignInError.missingAccessToken }
        return AuthResult(sub: sub, accessToken: accessToken)
    }

    /// JWT payload extraction, defensive against malformed tokens. We don't
    /// re-verify the signature — Google's SDK already did that — we only
    /// need the `sub` field to derive the per-account encryption salt.
    private func extractSubClaim(_ jwt: String) throws -> String {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { throw SignInError.malformedIdToken }
        let payloadSegment = String(parts[1])
        guard let payloadData = Self.decodeBase64URL(payloadSegment) else {
            throw SignInError.malformedIdToken
        }
        guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw SignInError.malformedIdToken
        }
        guard let sub = json["sub"] as? String, !sub.isEmpty else {
            throw SignInError.missingSubClaim
        }
        return sub
    }

    private static func decodeBase64URL(_ segment: String) -> Data? {
        var s = segment.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - s.count % 4) % 4
        if pad > 0 { s.append(String(repeating: "=", count: pad)) }
        return Data(base64Encoded: s)
    }
}
