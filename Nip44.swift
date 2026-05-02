import Foundation
import CryptoKit

/// NIP-44 v2 versioned encryption.
/// Spec: https://github.com/nostr-protocol/nips/blob/master/44.md
/// Payload layout (base64): version(1) || nonce(32) || ciphertext || mac(32)
nonisolated enum Nip44 {

    enum Error: Swift.Error {
        case invalidPayload
        case invalidVersion
        case macMismatch
        case invalidPlaintextLength
        case invalidPadding
    }

    static let version: UInt8 = 0x02

    // MARK: - Conversation key

    /// HKDF-Extract(salt: "nip44-v2", ikm: ECDH(privkey, pubkey)) → 32 bytes.
    static func getConversationKey(privkey32: Data, peerXonlyPubkey32: Data) throws -> Data {
        let sharedX = try Schnorr.ecdhRawX(privkey32: privkey32, xonlyPubkey32: peerXonlyPubkey32)
        // HKDF-Extract = HMAC(salt, ikm)
        let salt = "nip44-v2".data(using: .utf8)!
        let prk = HMAC<SHA256>.authenticationCode(for: sharedX, using: SymmetricKey(data: salt))
        return Data(prk)
    }

    // MARK: - Encrypt

    static func encrypt(plaintext: String, conversationKey: Data, nonce: Data? = nil) throws -> String {
        guard let utf8 = plaintext.data(using: .utf8), !utf8.isEmpty, utf8.count <= 65535 else {
            throw Error.invalidPlaintextLength
        }
        let nonce32: Data = {
            if let nonce { return nonce }
            var b = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, &b)
            return Data(b)
        }()
        let (chachaKey, chachaNonce, hmacKey) = try messageKeys(conversationKey: conversationKey, nonce: nonce32)
        let padded = pad(utf8)
        let cipher = ChaCha20.apply(key: chachaKey, nonce: chachaNonce, counter: 0, input: padded)
        let mac = hmac(key: hmacKey, message: nonce32 + cipher)

        var payload = Data()
        payload.append(version)
        payload.append(nonce32)
        payload.append(cipher)
        payload.append(mac)
        return payload.base64EncodedString()
    }

    // MARK: - Decrypt

    static func decrypt(payload: String, conversationKey: Data) throws -> String {
        if payload.first == "#" { throw Error.invalidVersion }
        guard let raw = Data(base64Encoded: payload), raw.count >= 99 else { throw Error.invalidPayload }
        guard raw[0] == version else { throw Error.invalidVersion }

        let nonce32 = raw.subdata(in: 1..<33)
        let macStart = raw.count - 32
        let cipher = raw.subdata(in: 33..<macStart)
        let mac = raw.subdata(in: macStart..<raw.count)

        let (chachaKey, chachaNonce, hmacKey) = try messageKeys(conversationKey: conversationKey, nonce: nonce32)
        let expected = hmac(key: hmacKey, message: nonce32 + cipher)
        guard constantTimeEquals(expected, mac) else { throw Error.macMismatch }

        let padded = ChaCha20.apply(key: chachaKey, nonce: chachaNonce, counter: 0, input: cipher)
        return try unpad(padded)
    }

    // MARK: - Message keys

    private static func messageKeys(conversationKey: Data, nonce: Data) throws -> (chachaKey: Data, chachaNonce: Data, hmacKey: Data) {
        guard conversationKey.count == 32, nonce.count == 32 else { throw Error.invalidPayload }
        let prk = SymmetricKey(data: conversationKey)
        let okm = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: nonce, outputByteCount: 76)
        let bytes = okm.withUnsafeBytes { Data($0) }
        return (bytes.subdata(in: 0..<32),
                bytes.subdata(in: 32..<44),
                bytes.subdata(in: 44..<76))
    }

    // MARK: - Padding

    static func calcPaddedLen(_ unpaddedLen: Int) -> Int {
        if unpaddedLen <= 32 { return 32 }
        // next power of 2 >= unpaddedLen
        var nextPow: Int = 1
        while nextPow < unpaddedLen { nextPow <<= 1 }
        let chunk = nextPow <= 256 ? 32 : nextPow / 8
        return ((unpaddedLen - 1) / chunk + 1) * chunk
    }

    private static func pad(_ utf8: Data) -> Data {
        let unpaddedLen = utf8.count
        let paddedLen = calcPaddedLen(unpaddedLen)
        var out = Data(capacity: 2 + paddedLen)
        out.append(UInt8(truncatingIfNeeded: unpaddedLen >> 8))
        out.append(UInt8(truncatingIfNeeded: unpaddedLen))
        out.append(utf8)
        if paddedLen > unpaddedLen {
            out.append(Data(repeating: 0, count: paddedLen - unpaddedLen))
        }
        return out
    }

    private static func unpad(_ padded: Data) throws -> String {
        guard padded.count >= 2 else { throw Error.invalidPadding }
        let unpaddedLen = (Int(padded[0]) << 8) | Int(padded[1])
        guard unpaddedLen >= 1, unpaddedLen <= 65535,
              padded.count == 2 + calcPaddedLen(unpaddedLen) else {
            throw Error.invalidPadding
        }
        let plaintext = padded.subdata(in: 2..<(2 + unpaddedLen))
        guard let s = String(data: plaintext, encoding: .utf8) else { throw Error.invalidPadding }
        return s
    }

    // MARK: - Helpers

    private static func hmac(key: Data, message: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(mac)
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
