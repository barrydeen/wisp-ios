import Foundation
import CryptoKit

/// Minimal BIP-39 mnemonic generator and validator. Wordlist resource
/// `bip39-english.txt` is bundled under `wisp/Resources/`.
enum Bip39 {

    enum Error: Swift.Error {
        case missingWordlist
        case invalidWordCount
        case unknownWord(String)
        case invalidChecksum
    }

    /// Lazy-loaded English wordlist (2048 entries). The Breez SDK validates the mnemonic on
    /// connect anyway, but we duplicate the check up-front so we can show errors before
    /// the user commits to creating a wallet directory.
    static let wordlist: [String] = {
        guard let url = Bundle.main.url(forResource: "bip39-english", withExtension: "txt"),
              let data = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return data
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }()

    static var isWordlistAvailable: Bool { wordlist.count == 2048 }

    /// Generate a fresh 12-word mnemonic from 16 bytes of secure entropy.
    static func newMnemonic() throws -> String {
        guard isWordlistAvailable else { throw Error.missingWordlist }
        var entropy = [UInt8](repeating: 0, count: 16)
        let r = SecRandomCopyBytes(kSecRandomDefault, 16, &entropy)
        guard r == errSecSuccess else { throw Error.missingWordlist }
        return entropyToMnemonic(Data(entropy))
    }

    /// Deterministic BIP-39 mnemonic from caller-supplied entropy. Used for
    /// nsec-derived default Spark wallets so the same key always produces the
    /// same recoverable wallet. Mirrors Android `SparkRepository.entropyToMnemonic`.
    static func mnemonic(fromEntropy entropy: Data) throws -> String {
        guard isWordlistAvailable else { throw Error.missingWordlist }
        return entropyToMnemonic(entropy)
    }

    /// Validate: word count ∈ {12, 15, 18, 21, 24}, all words present in wordlist,
    /// SHA-256 checksum matches. Returns nil on success, error message string on failure.
    static func validate(_ mnemonic: String) -> String? {
        let words = Nip78Backup.normalizeMnemonic(mnemonic).split(separator: " ").map(String.init)
        if ![12, 15, 18, 21, 24].contains(words.count) {
            return "Recovery phrase must be 12, 15, 18, 21, or 24 words"
        }
        guard isWordlistAvailable else { return nil } // can't validate without wordlist
        let invalid = words.filter { !wordlist.contains($0) }
        if !invalid.isEmpty {
            return "Invalid word\(invalid.count > 1 ? "s" : ""): \(invalid.prefix(3).joined(separator: ", "))"
        }
        // Reconstruct entropy + checksum bits, recompute checksum, compare.
        let indices = words.compactMap { wordlist.firstIndex(of: $0) }
        var bits = ""
        for idx in indices {
            bits += String(idx, radix: 2).padLeft(to: 11, with: "0")
        }
        let totalBits = words.count * 11
        let checksumBits = totalBits / 33
        let entropyBits = totalBits - checksumBits
        let entropyBytesCount = entropyBits / 8

        var entropy = [UInt8]()
        for i in 0..<entropyBytesCount {
            let start = bits.index(bits.startIndex, offsetBy: i * 8)
            let end = bits.index(start, offsetBy: 8)
            guard let byte = UInt8(bits[start..<end], radix: 2) else { return "Invalid recovery phrase" }
            entropy.append(byte)
        }
        let hashBytes = Array(SHA256.hash(data: Data(entropy)))
        let firstByte = hashBytes.first ?? 0
        let hashBits = String(firstByte, radix: 2).padLeft(to: 8, with: "0")
        let expectedChecksum = String(hashBits.prefix(checksumBits))
        let actualChecksum = String(bits.suffix(checksumBits))
        if expectedChecksum != actualChecksum {
            return "Invalid recovery phrase (checksum mismatch)"
        }
        return nil
    }

    private static func entropyToMnemonic(_ entropy: Data) -> String {
        let hashBytes = Array(SHA256.hash(data: entropy))
        let checksumBits = entropy.count / 4

        var bits = ""
        for byte in entropy {
            bits += String(byte, radix: 2).padLeft(to: 8, with: "0")
        }
        let hashBits = String((hashBytes.first ?? 0), radix: 2).padLeft(to: 8, with: "0")
        bits += String(hashBits.prefix(checksumBits))

        var words: [String] = []
        var i = bits.startIndex
        while i < bits.endIndex {
            let next = bits.index(i, offsetBy: 11, limitedBy: bits.endIndex) ?? bits.endIndex
            if let idx = Int(bits[i..<next], radix: 2), idx < wordlist.count {
                words.append(wordlist[idx])
            }
            i = next
        }
        return words.joined(separator: " ")
    }
}

private extension String {
    func padLeft(to length: Int, with pad: Character) -> String {
        if count >= length { return self }
        return String(repeating: pad, count: length - count) + self
    }
}
