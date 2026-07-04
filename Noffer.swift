import Foundation

/// CLINK Offers (`noffer1…`) — a Nostr-native successor to LNURL-pay.
///
/// Spec: https://github.com/shocknet/CLINK/blob/main/specs/clink-offers.md
///
/// A `noffer1…` bech32 string carries TLVs describing a static payment offer:
///
///   TLV 0 — 32-byte service pubkey (hex)
///   TLV 1 — recommended relay URL (utf-8) where the service listens
///   TLV 2 — opaque offer identifier (utf-8)
///   TLV 3 — (opt) pricing type: 0=Fixed, 1=Variable, 2=Spontaneous (default)
///   TLV 4 — (opt) price in sats (big-endian integer)
///   TLV 5 — (opt) currency code (utf-8; only meaningful with Variable)
///
/// The payer NIP-44 encrypts a kind-21001 request to the service pubkey and the
/// service replies with an encrypted kind-21001 carrying a bolt11 invoice —
/// see `NofferClient`.
enum NofferPricing: Hashable {
    case fixed
    case variable
    case spontaneous

    /// TLV 3 byte → pricing type. Matches the CLINK spec and the zap.cooking
    /// reference decoder: 0=Fixed, 1=Variable, anything else (incl. 2) =
    /// Spontaneous. Absent TLV 3 also defaults to Spontaneous.
    static func from(byte: UInt8) -> NofferPricing {
        switch byte {
        case 0: return .fixed
        case 1: return .variable
        default: return .spontaneous
        }
    }
}

struct NofferData: Hashable, Identifiable {
    /// 32-byte service pubkey, hex-encoded lowercase. (TLV 0)
    let pubkey: String
    /// Recommended relay URL where the service listens. (TLV 1)
    let relay: String
    /// Opaque offer identifier the service uses to look up the offer. (TLV 2)
    let offerId: String
    /// Pricing type — defaults to `.spontaneous` when TLV 3 is absent.
    let pricing: NofferPricing
    /// Price in sats. (TLV 4) Present for Fixed offers and as a hint for Variable.
    let price: Int64?
    /// Currency code (TLV 5) — only meaningful when `pricing == .variable`.
    let currency: String?
    /// The bare `noffer1…` string (no `nostr:` prefix) this was decoded from.
    /// Kept so callers can re-display / QR-encode the offer verbatim — the spec
    /// requires QR payloads to be exactly the bech32 string.
    let raw: String

    var id: String { raw }

    /// True when the payer must (or may) supply an amount: Spontaneous always
    /// needs one; Variable lets the payer hint at one (the service decides);
    /// Fixed bakes the amount into the offer.
    var acceptsAmount: Bool {
        switch pricing {
        case .fixed: return false
        case .variable, .spontaneous: return true
        }
    }
}

/// Typed failure surfaced by the CLINK service (or the client on timeout /
/// transport failure). `code` follows the spec's error table; `code == 0`
/// marks a local/transport failure with no service code.
struct NofferError: Error, LocalizedError {
    let code: Int
    let message: String
    let range: (min: Int64, max: Int64)?
    let latest: String?

    init(code: Int, message: String, range: (min: Int64, max: Int64)? = nil, latest: String? = nil) {
        self.code = code
        self.message = message
        self.range = range
        self.latest = latest
    }

    var errorDescription: String? { message }
}

/// Decrypted payload of a kind-21001 response event.
struct NofferResponse {
    let bolt11: String?
    let error: String?
    let code: Int?
    let range: (min: Int64, max: Int64)?
    let latest: String?

    static func parse(_ json: String) -> NofferResponse? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var range: (min: Int64, max: Int64)?
        if let r = obj["range"] as? [String: Any] {
            let lo = (r["min"] as? Int64) ?? Int64((r["min"] as? Int) ?? 0)
            let hi = (r["max"] as? Int64) ?? Int64((r["max"] as? Int) ?? 0)
            range = (lo, hi)
        }
        let code = (obj["code"] as? Int) ?? (obj["code"] as? Int64).map(Int.init)
        return NofferResponse(
            bolt11: (obj["bolt11"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            error: obj["error"] as? String,
            code: code,
            range: range,
            latest: obj["latest"] as? String
        )
    }
}

nonisolated enum Noffer {

    enum DecodeError: Error { case notNoffer, malformed }

    private static let nofferRegex = try! NSRegularExpression(
        pattern: #"^(nostr:)?noffer1[023456789acdefghjklmnpqrstuvwxyz]{20,}$"#,
        options: [.caseInsensitive]
    )

    /// Lightweight detector — checks shape only, does not decode TLVs. Use this
    /// in segment / paste parsers where you just need "is this noffer-shaped";
    /// call `decode` and let it throw for real use.
    static func isNofferString(_ s: String?) -> Bool {
        guard let s else { return false }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        return nofferRegex.firstMatch(in: trimmed, range: range) != nil
    }

    /// Strip a leading `nostr:` prefix (and surrounding whitespace) and return
    /// the bare `noffer1…` token. Use before building a QR payload — the spec
    /// requires the QR to be exactly the bech32 string with no scheme prefix.
    static func stripNostrPrefix(_ noffer: String) -> String {
        let trimmed = noffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("nostr:") {
            return String(trimmed.dropFirst("nostr:".count))
        }
        return trimmed
    }

    /// Decode a `noffer1…` (or `nostr:noffer1…`) string into its TLV fields.
    /// Throws on wrong HRP, non-bech32 input, truncated TLVs, or a missing /
    /// wrong-length required TLV (0/1/2).
    static func decode(_ input: String) throws -> NofferData {
        let cleaned = stripNostrPrefix(input)
        guard cleaned.lowercased().hasPrefix("noffer1") else { throw DecodeError.notNoffer }
        guard let (hrp, data) = Bech32.decode(cleaned), hrp == "noffer" else {
            throw DecodeError.malformed
        }

        let bytes = [UInt8](data)
        let tlvs = try parseTlvs(bytes)

        guard let pubkeyTlv = tlvs.first(where: { $0.type == 0 }), pubkeyTlv.value.count == 32 else {
            throw DecodeError.malformed
        }
        guard let relayTlv = tlvs.first(where: { $0.type == 1 }),
              let relay = String(bytes: relayTlv.value, encoding: .utf8), !relay.isEmpty else {
            throw DecodeError.malformed
        }
        guard let offerTlv = tlvs.first(where: { $0.type == 2 }),
              let offerId = String(bytes: offerTlv.value, encoding: .utf8) else {
            throw DecodeError.malformed
        }

        let pricing: NofferPricing
        if let typeTlv = tlvs.first(where: { $0.type == 3 }), let first = typeTlv.value.first {
            pricing = NofferPricing.from(byte: first)
        } else {
            pricing = .spontaneous
        }

        var price: Int64?
        if let priceTlv = tlvs.first(where: { $0.type == 4 }), !priceTlv.value.isEmpty {
            price = bigEndianInt(priceTlv.value)
        }

        var currency: String?
        if let currencyTlv = tlvs.first(where: { $0.type == 5 }), !currencyTlv.value.isEmpty {
            currency = String(bytes: currencyTlv.value, encoding: .utf8)
        }

        return NofferData(
            pubkey: Hex.encode(Data(pubkeyTlv.value)),
            relay: relay,
            offerId: offerId,
            pricing: pricing,
            price: price,
            currency: currency,
            raw: cleaned
        )
    }

    // MARK: - TLV parsing

    private struct Tlv { let type: Int; let value: [UInt8] }

    private static func parseTlvs(_ bytes: [UInt8]) throws -> [Tlv] {
        var tlvs: [Tlv] = []
        var i = 0
        while i < bytes.count {
            guard i + 2 <= bytes.count else { throw DecodeError.malformed }
            let type = Int(bytes[i])
            let length = Int(bytes[i + 1])
            guard i + 2 + length <= bytes.count else { throw DecodeError.malformed }
            let value = Array(bytes[(i + 2)..<(i + 2 + length)])
            tlvs.append(Tlv(type: type, value: value))
            i += 2 + length
        }
        return tlvs
    }

    private static func bigEndianInt(_ bytes: [UInt8]) -> Int64 {
        var n: Int64 = 0
        for b in bytes { n = n &* 256 &+ Int64(b) }
        return n
    }
}
