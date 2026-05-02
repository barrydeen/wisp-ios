import Foundation

nonisolated enum Bolt11 {
    private static let bech32Charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let hrpAmountRegex = try! NSRegularExpression(pattern: #"ln\w+?(\d+)([munp]?)$"#)

    struct DecodedInvoice {
        let amountSats: Int64?
        let paymentHash: String?
        let description: String?
        let expiry: Int64
        let timestamp: Int64

        var isExpired: Bool {
            let now = Int64(Date().timeIntervalSince1970)
            return now > timestamp + expiry
        }
    }

    static func decode(_ invoice: String) -> DecodedInvoice? {
        var lower = invoice.lowercased()
        if lower.hasPrefix("lightning:") { lower = String(lower.dropFirst("lightning:".count)) }
        guard let pos = lower.lastIndex(of: "1"), pos > lower.startIndex else { return nil }
        let hrp = String(lower[..<pos])
        let dataStr = String(lower[lower.index(after: pos)...])
        guard dataStr.count >= 7 + 104 else { return nil }

        var data5 = [Int]()
        data5.reserveCapacity(dataStr.count)
        for c in dataStr {
            guard let idx = bech32Charset.firstIndex(of: c) else { return nil }
            data5.append(idx)
        }

        let dataLen = data5.count - 6
        if dataLen < 7 + 104 { return nil }

        let amountSats = parseHrpAmount(hrp)

        var timestamp: Int64 = 0
        for i in 0..<7 {
            timestamp = (timestamp << 5) | Int64(data5[i])
        }

        let sigStart = dataLen - 104
        var offset = 7
        var paymentHash: String?
        var description: String?
        var expiry: Int64 = 3600

        while offset < sigStart {
            if offset + 3 > sigStart { break }
            let tag = data5[offset]
            let dataLength = (data5[offset + 1] << 5) | data5[offset + 2]
            offset += 3
            if offset + dataLength > sigStart { break }

            switch tag {
            case 1:
                if dataLength == 52, let bytes = convert5to8(data5, offset: offset, length: dataLength) {
                    paymentHash = Hex.encode(Data(bytes))
                }
            case 13:
                if let bytes = convert5to8(data5, offset: offset, length: dataLength) {
                    description = String(bytes: bytes, encoding: .utf8)
                }
            case 6:
                var exp: Int64 = 0
                for i in 0..<dataLength {
                    exp = (exp << 5) | Int64(data5[offset + i])
                }
                expiry = exp
            default: break
            }
            offset += dataLength
        }

        return DecodedInvoice(
            amountSats: amountSats,
            paymentHash: paymentHash,
            description: description,
            expiry: expiry,
            timestamp: timestamp
        )
    }

    private static func parseHrpAmount(_ hrp: String) -> Int64? {
        let ns = hrp as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = hrpAmountRegex.firstMatch(in: hrp, range: range), m.numberOfRanges >= 3 else { return nil }
        let amountStr = ns.substring(with: m.range(at: 1))
        let mult = ns.substring(with: m.range(at: 2))
        guard let amount = Int64(amountStr) else { return nil }
        switch mult {
        case "m": return amount * 100_000
        case "u": return amount * 100
        case "n": return amount / 10
        case "p": return amount / 10_000
        case "":  return amount * 100_000_000
        default:  return nil
        }
    }

    private static func convert5to8(_ data: [Int], offset: Int, length: Int) -> [UInt8]? {
        var acc = 0
        var bits = 0
        var result = [UInt8]()
        for i in 0..<length {
            acc = (acc << 5) | data[offset + i]
            bits += 5
            while bits >= 8 {
                bits -= 8
                result.append(UInt8((acc >> bits) & 0xFF))
            }
        }
        return result
    }
}
