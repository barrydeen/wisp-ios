import Foundation
import CryptoKit

/// AES-256-GCM file encryption for NIP-17 kind-15 encrypted file messages.
/// Interoperable with Android wisp / Amethyst.
///
/// Wire format: the Blossom-hosted blob is `ciphertext || tag` — the 16-byte GCM auth
/// tag is appended to the ciphertext, and the 12-byte nonce travels SEPARATELY in the
/// `decryption-nonce` rumor tag (it is NOT prepended to the blob). This matches Android's
/// `Cipher.doFinal` output, so we must build the blob from `sealedBox.ciphertext +
/// sealedBox.tag` (NOT `sealedBox.combined`, which prepends the nonce).
enum EncryptedMedia {
    static let algorithm = "aes-gcm"
    private static let tagByteCount = 16

    struct EncryptedFileResult {
        let encryptedBytes: Data
        let keyHex: String
        let nonceHex: String
        let originalSha256Hex: String
        let encryptedSha256Hex: String
    }

    enum CryptoError: Error { case badKey, badNonce, badCiphertext }

    static func encryptFile(_ plain: Data) throws -> EncryptedFileResult {
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()  // random 96-bit
        let sealed = try AES.GCM.seal(plain, using: key, nonce: nonce)
        let blob = sealed.ciphertext + sealed.tag
        let keyData = key.withUnsafeBytes { Data($0) }
        let nonceData = Data(nonce)
        return EncryptedFileResult(
            encryptedBytes: blob,
            keyHex: Hex.encode(keyData),
            nonceHex: Hex.encode(nonceData),
            originalSha256Hex: Hex.encode(Data(SHA256.hash(data: plain))),
            encryptedSha256Hex: Hex.encode(Data(SHA256.hash(data: blob)))
        )
    }

    static func decryptFile(_ encrypted: Data, keyHex: String, nonceHex: String) throws -> Data {
        guard let keyData = Hex.decode(keyHex), keyData.count == 32 else { throw CryptoError.badKey }
        guard let nonceData = Hex.decode(nonceHex) else { throw CryptoError.badNonce }
        guard encrypted.count >= tagByteCount else { throw CryptoError.badCiphertext }
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let cipherText = encrypted.prefix(encrypted.count - tagByteCount)
        let tag = encrypted.suffix(tagByteCount)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherText, tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: keyData))
    }

    static func buildKind15Tags(
        mimeType: String,
        keyHex: String,
        nonceHex: String,
        encryptedHash: String,
        originalHash: String,
        size: Int,
        dimensions: String? = nil
    ) -> [[String]] {
        var tags: [[String]] = [
            ["file-type", mimeType],
            ["encryption-algorithm", algorithm],
            ["decryption-key", keyHex],
            ["decryption-nonce", nonceHex],
            ["x", encryptedHash],
            ["ox", originalHash],
            ["size", String(size)]
        ]
        if let d = dimensions { tags.append(["dim", d]) }
        return tags
    }

    static func parseKind15Tags(_ tags: [[String]], fileUrl: String) -> EncryptedFileMetadata? {
        var map: [String: String] = [:]
        for t in tags where t.count >= 2 { map[t[0]] = t[1] }
        guard let mime = map["file-type"], let algo = map["encryption-algorithm"],
              let keyHex = map["decryption-key"], let nonceHex = map["decryption-nonce"] else { return nil }
        return EncryptedFileMetadata(
            fileUrl: fileUrl,
            mimeType: mime,
            algorithm: algo,
            keyHex: keyHex,
            nonceHex: nonceHex,
            encryptedHash: map["x"],
            originalHash: map["ox"],
            size: map["size"].flatMap { Int($0) },
            dimensions: map["dim"],
            blurhash: map["blurhash"]
        )
    }
}
