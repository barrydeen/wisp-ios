import Foundation
import CommonCrypto

/// NIP-04 encrypted DMs (legacy). Used as a fallback for older NWC wallet services
/// that haven't moved to NIP-44 v2. Spec: AES-256-CBC, raw 32-byte ECDH x-coordinate
/// as the AES key (no SHA256), random IV, payload format `<base64-ct>?iv=<base64-iv>`.
nonisolated enum Nip04 {

    enum Error: Swift.Error {
        case malformedContent
        case decryptFailed
    }

    /// Shared secret = raw 32-byte X coordinate of `privkey × pubkey` (no SHA256).
    /// Identical to `Schnorr.ecdhRawX`, exposed here for clarity at call sites.
    static func sharedSecret(privkey32: Data, peerXonlyPubkey32: Data) throws -> Data {
        try Schnorr.ecdhRawX(privkey32: privkey32, xonlyPubkey32: peerXonlyPubkey32)
    }

    static func encrypt(_ plaintext: String, sharedSecret: Data) throws -> String {
        guard sharedSecret.count == 32 else { throw Error.malformedContent }
        var iv = Data(count: 16)
        let result = iv.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 16, ptr.baseAddress!)
        }
        guard result == errSecSuccess else { throw Error.decryptFailed }

        let plain = Data(plaintext.utf8)
        let cipher = try aesCbc(operation: CCOperation(kCCEncrypt), key: sharedSecret, iv: iv, input: plain)
        return "\(cipher.base64EncodedString())?iv=\(iv.base64EncodedString())"
    }

    static func decrypt(_ content: String, sharedSecret: Data) throws -> String {
        guard let range = content.range(of: "?iv=") else { throw Error.malformedContent }
        let ctB64 = String(content[..<range.lowerBound])
        let ivB64 = String(content[range.upperBound...])
        guard let cipher = Data(base64Encoded: ctB64),
              let iv = Data(base64Encoded: ivB64),
              iv.count == 16,
              sharedSecret.count == 32 else {
            throw Error.malformedContent
        }
        let plain = try aesCbc(operation: CCOperation(kCCDecrypt), key: sharedSecret, iv: iv, input: cipher)
        guard let s = String(data: plain, encoding: .utf8) else { throw Error.decryptFailed }
        return s
    }

    /// Raw-byte variant of `encrypt` — returns the AES ciphertext + IV directly
    /// without the `<base64>?iv=<base64>` envelope. Used by DIP-03 to pack
    /// (ciphertext, IV) into a bech32-encoded `anon` tag rather than the
    /// NIP-04 wire format. Caller is responsible for re-encoding the returned
    /// Data into whatever transport format the use case calls for.
    static func encryptRaw(_ plaintext: String, sharedSecret: Data) throws -> (ciphertext: Data, iv: Data) {
        guard sharedSecret.count == 32 else { throw Error.malformedContent }
        var iv = Data(count: 16)
        let result = iv.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, 16, ptr.baseAddress!)
        }
        guard result == errSecSuccess else { throw Error.decryptFailed }
        let plain = Data(plaintext.utf8)
        let cipher = try aesCbc(operation: CCOperation(kCCEncrypt), key: sharedSecret, iv: iv, input: plain)
        return (cipher, iv)
    }

    /// Raw-byte variant of `decrypt` — takes the AES ciphertext and IV bytes
    /// directly. Pairs with `encryptRaw` for DIP-03 anon-tag decoding.
    static func decryptRaw(ciphertext: Data, iv: Data, sharedSecret: Data) throws -> String {
        guard iv.count == 16, sharedSecret.count == 32 else { throw Error.malformedContent }
        let plain = try aesCbc(operation: CCOperation(kCCDecrypt), key: sharedSecret, iv: iv, input: ciphertext)
        guard let s = String(data: plain, encoding: .utf8) else { throw Error.decryptFailed }
        return s
    }

    private static func aesCbc(operation: CCOperation, key: Data, iv: Data, input: Data) throws -> Data {
        let outCapacity = input.count + kCCBlockSizeAES128
        var out = Data(count: outCapacity)
        var moved: size_t = 0
        let status = out.withUnsafeMutableBytes { outPtr -> CCCryptorStatus in
            input.withUnsafeBytes { inPtr in
                iv.withUnsafeBytes { ivPtr in
                    key.withUnsafeBytes { keyPtr in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, input.count,
                            outPtr.baseAddress, outCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Error.decryptFailed }
        out.count = moved
        return out
    }
}
