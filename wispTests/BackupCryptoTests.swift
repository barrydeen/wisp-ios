import Foundation
import Testing
@testable import wisp

struct BackupCryptoTests {

    // The Apple and Google variants differ only in the HMAC salt context
    // string fed into PBKDF2. Same (accountID, PIN) under each must yield
    // distinct 32-byte outputs — otherwise an iCloud Keychain item and a
    // Drive blob could cross-decrypt, breaking the per-provider isolation
    // we promise.
    @Test func appleAndGoogleSaltsProduceDifferentKeys() throws {
        let accountID = "shared-account-id-123"
        let pin = "1234"

        let googleKey = try BackupCrypto.deriveBackupKey(sub: accountID, pin: pin)
        let appleKey = try BackupCrypto.deriveBackupKey(appleUserID: accountID, pin: pin)

        #expect(googleKey.count == 32)
        #expect(appleKey.count == 32)
        #expect(googleKey != appleKey)
    }

    @Test func appleEncryptDecryptRoundtrip() throws {
        let appleUserID = "001234.abcdef.5678"  // SIWA-shaped opaque ID
        let pin = "42424242"
        let key = try BackupCrypto.deriveBackupKey(appleUserID: appleUserID, pin: pin)

        let priv = Schnorr.randomPrivkey()
        let payload = try BackupCrypto.encryptNsec(nsec32: priv, key32: key)
        let recovered = try BackupCrypto.decryptNsec(payload: payload, key32: key)

        #expect(recovered == priv)
    }

    @Test func wrongPinFailsDecryption() throws {
        let appleUserID = "001234.abcdef.5678"
        let rightKey = try BackupCrypto.deriveBackupKey(appleUserID: appleUserID, pin: "1234")
        let wrongKey = try BackupCrypto.deriveBackupKey(appleUserID: appleUserID, pin: "5678")

        let priv = Schnorr.randomPrivkey()
        let payload = try BackupCrypto.encryptNsec(nsec32: priv, key32: rightKey)

        #expect(throws: (any Error).self) {
            _ = try BackupCrypto.decryptNsec(payload: payload, key32: wrongKey)
        }
    }

    @Test func appleEmptyUserIDRejected() {
        #expect(throws: BackupCrypto.Error.self) {
            _ = try BackupCrypto.deriveBackupKey(appleUserID: "", pin: "1234")
        }
    }

    @Test func appleInvalidPinRejected() {
        // Too short
        #expect(throws: BackupCrypto.Error.self) {
            _ = try BackupCrypto.deriveBackupKey(appleUserID: "abc", pin: "12")
        }
        // Too long
        #expect(throws: BackupCrypto.Error.self) {
            _ = try BackupCrypto.deriveBackupKey(appleUserID: "abc", pin: "123456789")
        }
        // Non-numeric
        #expect(throws: BackupCrypto.Error.self) {
            _ = try BackupCrypto.deriveBackupKey(appleUserID: "abc", pin: "12ab")
        }
    }
}
