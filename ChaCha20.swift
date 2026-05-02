import Foundation

nonisolated enum ChaCha20 {

    /// IETF ChaCha20 (RFC 7539) stream cipher.
    /// - key: 32 bytes
    /// - nonce: 12 bytes
    /// - counter: initial block counter (NIP-44 uses 0)
    /// - input: plaintext or ciphertext (XOR is symmetric)
    static func apply(key: Data, nonce: Data, counter: UInt32 = 0, input: Data) -> Data {
        precondition(key.count == 32, "ChaCha20 key must be 32 bytes")
        precondition(nonce.count == 12, "ChaCha20 nonce must be 12 bytes")

        let keyWords = readWords(key)        // 8 × UInt32
        let nonceWords = readWords(nonce)    // 3 × UInt32
        var output = Data(count: input.count)

        var blockCounter = counter
        var offset = 0
        let inputBytes = [UInt8](input)

        output.withUnsafeMutableBytes { outRaw in
            let outBuf = outRaw.bindMemory(to: UInt8.self)
            while offset < inputBytes.count {
                let block = chachaBlock(key: keyWords, counter: blockCounter, nonce: nonceWords)
                let take = min(64, inputBytes.count - offset)
                for i in 0..<take {
                    outBuf[offset + i] = inputBytes[offset + i] ^ block[i]
                }
                offset += take
                blockCounter &+= 1
            }
        }
        return output
    }

    private static func readWords(_ data: Data) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(data.count / 4)
        let bytes = [UInt8](data)
        var i = 0
        while i + 4 <= bytes.count {
            let w = UInt32(bytes[i]) | (UInt32(bytes[i+1]) << 8) | (UInt32(bytes[i+2]) << 16) | (UInt32(bytes[i+3]) << 24)
            out.append(w)
            i += 4
        }
        return out
    }

    private static func chachaBlock(key: [UInt32], counter: UInt32, nonce: [UInt32]) -> [UInt8] {
        // Constants "expand 32-byte k"
        let c0: UInt32 = 0x61707865
        let c1: UInt32 = 0x3320646e
        let c2: UInt32 = 0x79622d32
        let c3: UInt32 = 0x6b206574

        var state: [UInt32] = [
            c0, c1, c2, c3,
            key[0], key[1], key[2], key[3],
            key[4], key[5], key[6], key[7],
            counter, nonce[0], nonce[1], nonce[2]
        ]
        let initial = state

        for _ in 0..<10 {
            // Column rounds
            qr(&state, 0, 4, 8, 12)
            qr(&state, 1, 5, 9, 13)
            qr(&state, 2, 6, 10, 14)
            qr(&state, 3, 7, 11, 15)
            // Diagonal rounds
            qr(&state, 0, 5, 10, 15)
            qr(&state, 1, 6, 11, 12)
            qr(&state, 2, 7, 8, 13)
            qr(&state, 3, 4, 9, 14)
        }

        var out = [UInt8](repeating: 0, count: 64)
        for i in 0..<16 {
            let w = state[i] &+ initial[i]
            out[i*4 + 0] = UInt8(truncatingIfNeeded: w)
            out[i*4 + 1] = UInt8(truncatingIfNeeded: w >> 8)
            out[i*4 + 2] = UInt8(truncatingIfNeeded: w >> 16)
            out[i*4 + 3] = UInt8(truncatingIfNeeded: w >> 24)
        }
        return out
    }

    @inline(__always)
    private static func qr(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 16)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 12)
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 8)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 7)
    }

    @inline(__always)
    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }
}
