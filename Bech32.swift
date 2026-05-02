import Foundation

nonisolated enum Bech32 {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    static func decode(_ str: String) -> (hrp: String, data: Data)? {
        let lower = str.lowercased()
        guard let sepIndex = lower.lastIndex(of: "1") else { return nil }
        let hrp = String(lower[lower.startIndex..<sepIndex])
        let dataPartStart = lower.index(after: sepIndex)
        let dataPart = lower[dataPartStart...]
        guard dataPart.count >= 6 else { return nil }

        var values = [UInt8]()
        for char in dataPart {
            guard let idx = charset.firstIndex(of: char) else { return nil }
            values.append(UInt8(charset.distance(from: charset.startIndex, to: idx)))
        }

        guard verifyChecksum(hrp: hrp, values: values) else { return nil }
        let dataValues = Array(values.dropLast(6))
        guard let converted = convertBits(data: dataValues, fromBits: 5, toBits: 8, pad: false) else { return nil }
        return (hrp, Data(converted))
    }

    private static func verifyChecksum(hrp: String, values: [UInt8]) -> Bool {
        polymod(hrpExpand(hrp) + values) == 1
    }

    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        var ret = [UInt8]()
        for c in hrp.unicodeScalars { ret.append(UInt8(c.value >> 5)) }
        ret.append(0)
        for c in hrp.unicodeScalars { ret.append(UInt8(c.value & 31)) }
        return ret
    }

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let gen: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk: UInt32 = 1
        for v in values {
            let b = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ UInt32(v)
            for i in 0..<5 {
                if ((b >> i) & 1) == 1 { chk ^= gen[i] }
            }
        }
        return chk
    }

    private static func convertBits(data: [UInt8], fromBits: Int, toBits: Int, pad: Bool) -> [UInt8]? {
        var acc: UInt32 = 0
        var bits = 0
        var ret = [UInt8]()
        let maxv: UInt32 = (1 << toBits) - 1
        for value in data {
            if value >= (1 << fromBits) { return nil }
            acc = (acc << fromBits) | UInt32(value)
            bits += fromBits
            while bits >= toBits {
                bits -= toBits
                ret.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits > 0 { ret.append(UInt8((acc << (toBits - bits)) & maxv)) }
        } else {
            if bits >= fromBits { return nil }
            if (acc << (toBits - bits)) & maxv != 0 { return nil }
        }
        return ret
    }
}
