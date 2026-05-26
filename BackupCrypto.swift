import Foundation
import CryptoKit
import CommonCrypto

/// Backup encryption for the cloud-stored nsec backup blob. Mirrors the
/// Android implementation byte-for-byte for the Google variant so a backup
/// written on either platform can be restored on the other.
///
/// Two factors gate decryption:
///   1. A stable per-account identifier (Google JWT `sub` claim, or Apple
///      `appleIDCredential.user`) — used only to derive a per-account salt.
///      By itself not a secret; we assume the provider can see it.
///   2. A 4–8 digit numeric PIN the user sets at first sign-in. PBKDF2 with
///      600k iterations stretches it. ~26 bits of raw PIN entropy is not
///      enough on its own, but combined with cloud access control and the
///      slow KDF an attacker needs ~weeks of compute *after* compromising
///      the cloud account.
///
/// The encrypted payload is NIP-44 v2 over the hex-encoded nsec, with the
/// PBKDF2 output in place of the usual ECDH conversation key.
///
/// Google and Apple backups use different salt context strings so the same
/// `(accountID, PIN)` pair can never cross-decrypt between providers.
nonisolated enum BackupCrypto {
    private static let googleSalt = "wisp-google-backup"
    private static let appleSalt = "wisp-apple-backup"
    private static let pbkdf2Iterations: UInt32 = 600_000
    private static let keyBytes = 32

    enum Error: Swift.Error {
        case invalidPin
        case invalidSub
        case invalidNsecLength
        case invalidKeyLength
        case kdfFailed
        case decryptedPayloadMalformed
    }

    static func isValidPin(_ pin: String) -> Bool {
        pin.count >= 4 && pin.count <= 8 && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func deriveBackupKey(sub: String, pin: String) throws -> Data {
        guard !sub.isEmpty else { throw Error.invalidSub }
        guard isValidPin(pin) else { throw Error.invalidPin }

        let saltBytes = perAccountSalt(context: googleSalt, accountID: sub)
        return try pbkdf2(password: pin, salt: saltBytes, iterations: pbkdf2Iterations, keyLength: keyBytes)
    }

    /// PBKDF2 key derived from the team-scoped Apple user identifier
    /// (`ASAuthorizationAppleIDCredential.user`) and the user's PIN. Uses a
    /// distinct salt context from `deriveBackupKey(sub:pin:)` so the same
    /// `(accountID, PIN)` pair cannot cross-decrypt between providers — a
    /// CloudKit blob cannot accidentally decrypt with a Drive-derived key
    /// (or vice versa).
    static func deriveBackupKey(appleUserID: String, pin: String) throws -> Data {
        guard !appleUserID.isEmpty else { throw Error.invalidSub }
        guard isValidPin(pin) else { throw Error.invalidPin }

        let saltBytes = perAccountSalt(context: appleSalt, accountID: appleUserID)
        return try pbkdf2(password: pin, salt: saltBytes, iterations: pbkdf2Iterations, keyLength: keyBytes)
    }

    static func encryptNsec(nsec32: Data, key32: Data) throws -> String {
        guard nsec32.count == 32 else { throw Error.invalidNsecLength }
        guard key32.count == 32 else { throw Error.invalidKeyLength }
        return try Nip44.encrypt(plaintext: Hex.encode(nsec32), conversationKey: key32)
    }

    static func decryptNsec(payload: String, key32: Data) throws -> Data {
        guard key32.count == 32 else { throw Error.invalidKeyLength }
        let hex = try Nip44.decrypt(payload: payload, conversationKey: key32)
        guard hex.count == 64, let bytes = Hex.decode(hex), bytes.count == 32 else {
            throw Error.decryptedPayloadMalformed
        }
        return bytes
    }

    private static func perAccountSalt(context: String, accountID: String) -> Data {
        let saltKey = SymmetricKey(data: Data(context.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(accountID.utf8), using: saltKey)
        return Data(mac)
    }

    private static func pbkdf2(password: String, salt: Data, iterations: UInt32, keyLength: Int) throws -> Data {
        let pwBytes = Array(password.utf8)
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { derivedPtr -> Int32 in
            salt.withUnsafeBytes { saltPtr -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwBytes, pwBytes.count,
                    saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    derivedPtr.bindMemory(to: UInt8.self).baseAddress, keyLength
                )
            }
        }
        guard status == kCCSuccess else { throw Error.kdfFailed }
        return derived
    }
}
