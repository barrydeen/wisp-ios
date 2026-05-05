import Foundation

enum NostrUriData {
    case noteRef(eventId: String, relays: [String], author: String?)
    case profileRef(pubkey: String, relays: [String])
    case addressRef(dTag: String, relays: [String], author: String?, kind: Int?)
}

nonisolated enum Nip19 {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let charsetRev: [Int] = {
        var arr = Array(repeating: -1, count: 128)
        for (i, c) in charset.enumerated() {
            arr[Int(c.asciiValue!)] = i
        }
        return arr
    }()

    static func decodeNostrUri(_ uri: String) -> NostrUriData? {
        let bech32 = uri.hasPrefix("nostr:") ? String(uri.dropFirst(6)) : uri
        let lower = bech32.lowercased()
        do {
            if lower.hasPrefix("note1") {
                let bytes = try noteDecode(lower)
                return .noteRef(eventId: Hex.encode(Data(bytes)), relays: [], author: nil)
            } else if lower.hasPrefix("nevent1") {
                return try neventDecode(lower)
            } else if lower.hasPrefix("npub1") {
                let bytes = try npubDecode(lower)
                return .profileRef(pubkey: Hex.encode(Data(bytes)), relays: [])
            } else if lower.hasPrefix("nprofile1") {
                return try nprofileDecode(lower)
            } else if lower.hasPrefix("naddr1") {
                return try naddrDecode(lower)
            }
            return nil
        } catch {
            return nil
        }
    }

    static func npubDecode(_ str: String) throws -> [UInt8] {
        let (hrp, data) = try bech32Decode(str)
        guard hrp == "npub", data.count == 32 else { throw Bech32Error.invalid }
        return data
    }

    static func noteDecode(_ str: String) throws -> [UInt8] {
        let (hrp, data) = try bech32Decode(str)
        guard hrp == "note", data.count == 32 else { throw Bech32Error.invalid }
        return data
    }

    static func neventDecode(_ str: String) throws -> NostrUriData {
        let (hrp, data) = try bech32Decode(str)
        guard hrp == "nevent" else { throw Bech32Error.invalid }
        return parseTlvNote(data)
    }

    static func nprofileDecode(_ str: String) throws -> NostrUriData {
        let (hrp, data) = try bech32Decode(str)
        guard hrp == "nprofile" else { throw Bech32Error.invalid }
        return parseTlvProfile(data)
    }

    static func naddrDecode(_ str: String) throws -> NostrUriData {
        let (hrp, data) = try bech32Decode(str)
        guard hrp == "naddr" else { throw Bech32Error.invalid }
        return parseTlvAddress(data)
    }

    static func npubEncode(pubkey: [UInt8]) -> String? {
        return try? bech32Encode(hrp: "npub", data: pubkey)
    }

    /// Cache the bech32 encode + truncate so each visible row pays the
    /// per-event cost once instead of every layout pass.
    private static let shortNpubCache = NSCache<NSString, NSString>()

    /// Display-only short form of a hex pubkey: `npub1abcd…wxyz`.
    /// Used everywhere the UI would otherwise fall back to truncated
    /// hex — never expose hex pubkeys directly to the user.
    /// Falls back to a hex prefix only when the input isn't a valid
    /// 32-byte hex pubkey, which shouldn't happen in practice.
    static func shortNpub(hex: String) -> String {
        let key = hex as NSString
        if let cached = shortNpubCache.object(forKey: key) {
            return cached as String
        }
        guard let data = Hex.decode(hex), data.count == 32,
              let full = npubEncode(pubkey: Array(data)) else {
            return String(hex.prefix(8)) + "\u{2026}"
        }
        let prefix = full.prefix(9)
        let suffix = full.suffix(4)
        let result = "\(prefix)\u{2026}\(suffix)"
        shortNpubCache.setObject(result as NSString, forKey: key)
        return result
    }

    static func nsecEncode(privkey: [UInt8]) -> String? {
        return try? bech32Encode(hrp: "nsec", data: privkey)
    }

    static func noteEncode(eventId: [UInt8]) -> String? {
        return try? bech32Encode(hrp: "note", data: eventId)
    }

    /// Encode `nevent1...` with optional relay hints and author pubkey.
    /// `eventId32` and `author32` are raw 32-byte values (not hex).
    static func neventEncode(eventId32: [UInt8], relays: [String] = [], author32: [UInt8]? = nil) -> String? {
        guard eventId32.count == 32 else { return nil }
        if let author32, author32.count != 32 { return nil }
        var tlv: [UInt8] = []
        appendTlv(&tlv, type: 0x00, value: eventId32)
        for relay in relays {
            appendTlv(&tlv, type: 0x01, value: Array(relay.utf8))
        }
        if let author32 {
            appendTlv(&tlv, type: 0x02, value: author32)
        }
        return try? bech32Encode(hrp: "nevent", data: tlv)
    }

    /// Encode `nprofile1...` with optional relay hints. `pubkey32` is raw 32-byte.
    static func nprofileEncode(pubkey32: [UInt8], relays: [String] = []) -> String? {
        guard pubkey32.count == 32 else { return nil }
        var tlv: [UInt8] = []
        appendTlv(&tlv, type: 0x00, value: pubkey32)
        for relay in relays {
            appendTlv(&tlv, type: 0x01, value: Array(relay.utf8))
        }
        return try? bech32Encode(hrp: "nprofile", data: tlv)
    }

    private static func appendTlv(_ buf: inout [UInt8], type: UInt8, value: [UInt8]) {
        guard value.count <= 255 else { return }
        buf.append(type)
        buf.append(UInt8(value.count))
        buf.append(contentsOf: value)
    }

    // MARK: - TLV parsing

    private static func parseTlvNote(_ data: [UInt8]) -> NostrUriData {
        var eventId: String?
        var relays: [String] = []
        var author: String?
        var i = 0
        while i + 1 < data.count {
            let type = Int(data[i])
            let length = Int(data[i + 1])
            i += 2
            if i + length > data.count { break }
            let value = Array(data[i..<(i + length)])
            switch type {
            case 0x00 where value.count == 32:
                eventId = Hex.encode(Data(value))
            case 0x01:
                if let s = String(bytes: value, encoding: .utf8) { relays.append(s) }
            case 0x02 where value.count == 32:
                author = Hex.encode(Data(value))
            default: break
            }
            i += length
        }
        return .noteRef(eventId: eventId ?? "", relays: relays, author: author)
    }

    private static func parseTlvProfile(_ data: [UInt8]) -> NostrUriData {
        var pubkey: String?
        var relays: [String] = []
        var i = 0
        while i + 1 < data.count {
            let type = Int(data[i])
            let length = Int(data[i + 1])
            i += 2
            if i + length > data.count { break }
            let value = Array(data[i..<(i + length)])
            switch type {
            case 0x00 where value.count == 32:
                pubkey = Hex.encode(Data(value))
            case 0x01:
                if let s = String(bytes: value, encoding: .utf8) { relays.append(s) }
            default: break
            }
            i += length
        }
        return .profileRef(pubkey: pubkey ?? "", relays: relays)
    }

    private static func parseTlvAddress(_ data: [UInt8]) -> NostrUriData {
        var dTag: String?
        var relays: [String] = []
        var author: String?
        var kind: Int?
        var i = 0
        while i + 1 < data.count {
            let type = Int(data[i])
            let length = Int(data[i + 1])
            i += 2
            if i + length > data.count { break }
            let value = Array(data[i..<(i + length)])
            switch type {
            case 0x00:
                dTag = String(bytes: value, encoding: .utf8)
            case 0x01:
                if let s = String(bytes: value, encoding: .utf8) { relays.append(s) }
            case 0x02 where value.count == 32:
                author = Hex.encode(Data(value))
            case 0x03 where value.count == 4:
                kind = (Int(value[0]) << 24) | (Int(value[1]) << 16) | (Int(value[2]) << 8) | Int(value[3])
            default: break
            }
            i += length
        }
        return .addressRef(dTag: dTag ?? "", relays: relays, author: author, kind: kind)
    }

    // MARK: - Bech32 codec

    enum Bech32Error: Error { case invalid }

    private static func bech32Decode(_ str: String) throws -> (hrp: String, data: [UInt8]) {
        let lower = str.lowercased()
        guard let pos = lower.lastIndex(of: "1"), pos > lower.startIndex else { throw Bech32Error.invalid }
        let hrp = String(lower[..<pos])
        let dataStr = String(lower[lower.index(after: pos)...])
        guard dataStr.count >= 6 else { throw Bech32Error.invalid }
        var values = [Int]()
        values.reserveCapacity(dataStr.count)
        for c in dataStr {
            guard let scalar = c.asciiValue, Int(scalar) < charsetRev.count else { throw Bech32Error.invalid }
            let v = charsetRev[Int(scalar)]
            if v < 0 { throw Bech32Error.invalid }
            values.append(v)
        }
        guard verifyChecksum(hrp: hrp, values: values) else { throw Bech32Error.invalid }
        let payload = Array(values.dropLast(6))
        let bytes = convertBits5to8(payload)
        return (hrp, bytes)
    }

    private static func bech32Encode(hrp: String, data: [UInt8]) throws -> String {
        let values = convertBits8to5(data)
        let checksum = bech32Checksum(hrp: hrp, values: values)
        var out = hrp + "1"
        out.reserveCapacity(out.count + values.count + 6)
        for v in values { out.append(charset[v]) }
        for v in checksum { out.append(charset[v]) }
        return out
    }

    private static func convertBits5to8(_ data: [Int]) -> [UInt8] {
        var acc = 0
        var bits = 0
        var ret = [UInt8]()
        for v in data {
            acc = (acc << 5) | (v & 0x1F)
            bits += 5
            while bits >= 8 {
                bits -= 8
                ret.append(UInt8((acc >> bits) & 0xFF))
            }
        }
        return ret
    }

    private static func convertBits8to5(_ data: [UInt8]) -> [Int] {
        var acc = 0
        var bits = 0
        var ret = [Int]()
        for v in data {
            acc = (acc << 8) | Int(v)
            bits += 8
            while bits >= 5 {
                bits -= 5
                ret.append((acc >> bits) & 0x1F)
            }
        }
        if bits > 0 { ret.append((acc << (5 - bits)) & 0x1F) }
        return ret
    }

    private static func polymod(_ values: [Int]) -> Int {
        let gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk = 1
        for v in values {
            let b = chk >> 25
            chk = ((chk & 0x1ffffff) << 5) ^ v
            for i in 0..<5 {
                if ((b >> i) & 1) == 1 { chk ^= gen[i] }
            }
        }
        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [Int] {
        var ret = [Int]()
        ret.reserveCapacity(hrp.count * 2 + 1)
        for c in hrp.unicodeScalars { ret.append(Int(c.value) >> 5) }
        ret.append(0)
        for c in hrp.unicodeScalars { ret.append(Int(c.value) & 31) }
        return ret
    }

    private static func verifyChecksum(hrp: String, values: [Int]) -> Bool {
        polymod(hrpExpand(hrp) + values) == 1
    }

    private static func bech32Checksum(hrp: String, values: [Int]) -> [Int] {
        let combined = hrpExpand(hrp) + values + [0, 0, 0, 0, 0, 0]
        let pm = polymod(combined) ^ 1
        return (0..<6).map { (pm >> (5 * (5 - $0))) & 31 }
    }
}
