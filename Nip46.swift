import Foundation

/// NIP-46 ("Nostr Connect" / remote signing) — protocol layer.
///
/// Spec: https://github.com/nostr-protocol/nips/blob/master/46.md
///
/// Wire format: kind-24133 events whose `content` is a NIP-44 v2–encrypted JSON
/// envelope `{"id":..., "method":..., "params":[...]}` (request) or
/// `{"id":..., "result":..., "error":...}` (response). The recipient is named
/// via a single `p` tag.
///
/// We deliberately ship our own RPC transport rather than depend on a bundled
/// NIP-46 library — the same trade-off `deadcat` makes — because:
///   1. some signers (Primal iOS) refuse NIP-04 inbound, others (older Amber,
///      Clave's older builds) emit NIP-04 outbound responses, so the transport
///      must accept both directions opportunistically;
///   2. compliant signers (Clave, Primal, Amber) return the URI's `secret`
///      echoed back from `connect` rather than the literal string `"ack"`,
///      and rust/Swift parsers that strictly require `"ack"` (rust-nostr's
///      `to_ack()`) cannot complete the handshake — we accept both.
enum Nip46 {

    /// Kind for NIP-46 RPC events.
    static let kind: Int = 24133

    /// Per-RPC default timeout (sign_event, nip44_encrypt, get_public_key, …).
    static let rpcTimeoutSeconds: TimeInterval = 60

    /// Longer timeout for the user-driven `nostrconnect://` handshake — the
    /// signer device may need to be unlocked, switched to, and the URI scanned.
    static let nostrconnectHandshakeTimeoutSeconds: TimeInterval = 180

    // MARK: - Methods

    enum Method {
        static let connect = "connect"
        static let getPublicKey = "get_public_key"
        static let signEvent = "sign_event"
        static let nip04Encrypt = "nip04_encrypt"
        static let nip04Decrypt = "nip04_decrypt"
        static let nip44Encrypt = "nip44_encrypt"
        static let nip44Decrypt = "nip44_decrypt"
        static let ping = "ping"
    }

    // MARK: - Errors

    enum NipError: Swift.Error, CustomStringConvertible {
        case invalidBunkerUri(String)
        case invalidNostrconnectUri(String)
        case malformedResponse
        case rpcError(String)
        case timeout(method: String)
        case noRelays
        case decryptFailed
        case alreadyConnected
        case notConnected
        case invalidKey

        var description: String {
            switch self {
            case .invalidBunkerUri(let s): return "Invalid bunker URI: \(s)"
            case .invalidNostrconnectUri(let s): return "Invalid nostrconnect URI: \(s)"
            case .malformedResponse: return "Malformed signer response"
            case .rpcError(let s): return s
            case .timeout(let m): return "\(m) timed out"
            case .noRelays: return "No relays specified"
            case .decryptFailed: return "Could not decrypt signer response"
            case .alreadyConnected: return "Already connected to a remote signer"
            case .notConnected: return "Not connected to a remote signer"
            case .invalidKey: return "Invalid key"
            }
        }
    }

    // MARK: - bunker:// parsing

    /// Parsed `bunker://<pubkey>?relay=...&relay=...&secret=...` URI.
    struct BunkerUri: Equatable {
        let signerPubkey: String       // hex
        let relays: [String]
        let secret: String?
    }

    static func parseBunker(_ uri: String) -> BunkerUri? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bunker://") else { return nil }
        let rest = String(trimmed.dropFirst("bunker://".count))
        let (pubkeyPart, queryPart): (String, String) = {
            if let i = rest.firstIndex(of: "?") {
                return (String(rest[..<i]), String(rest[rest.index(after: i)...]))
            } else {
                return (rest, "")
            }
        }()
        let pubkey = pubkeyPart.lowercased()
        guard pubkey.count == 64,
              Hex.decode(pubkey) != nil else { return nil }
        var relays: [String] = []
        var secret: String?
        for pair in queryPart.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let value = percentDecode(parts[1])
            if key == "relay", !value.isEmpty {
                relays.append(value)
            } else if key == "secret", !value.isEmpty {
                secret = value
            }
        }
        return BunkerUri(signerPubkey: pubkey, relays: relays, secret: secret)
    }

    // MARK: - nostrconnect:// building

    /// Build a `nostrconnect://<app_pubkey>?relay=...&secret=...&name=...&url=...&perms=...` URI.
    ///
    /// Notes for compatibility:
    ///  - `secret` is REQUIRED by Primal iOS. Without it the signer never publishes
    ///    its `connect` response and the client times out.
    ///  - relay query params are repeated (`relay=A&relay=B`), not joined.
    ///  - relay URLs are stripped of any trailing `/` before encoding to match the
    ///    byte-for-byte URI shape that nostr-tools' `createNostrConnectURI` produces;
    ///    strict signer-side parsers reject mismatched normalization.
    static func buildNostrconnectURI(
        appPubkey: String,
        relays: [String],
        secret: String,
        name: String,
        appURL: String? = nil,
        perms: [String] = []
    ) -> String {
        var out = "nostrconnect://\(appPubkey.lowercased())"
        var params: [String] = []
        for r in relays {
            let trimmed = r.hasSuffix("/") ? String(r.dropLast()) : r
            params.append("relay=\(percentEncode(trimmed))")
        }
        params.append("secret=\(percentEncode(secret))")
        params.append("name=\(percentEncode(name))")
        if let appURL { params.append("url=\(percentEncode(appURL))") }
        if !perms.isEmpty {
            params.append("perms=\(percentEncode(perms.joined(separator: ",")))")
        }
        if !params.isEmpty {
            out += "?" + params.joined(separator: "&")
        }
        return out
    }

    /// Build a `bunker://` URI from a completed nostrconnect handshake — the
    /// signer's pubkey is now known, and the relays + secret are the same set
    /// the user-side URI advertised.
    static func buildBunkerURI(signerPubkey: String, relays: [String], secret: String? = nil) -> String {
        var out = "bunker://\(signerPubkey.lowercased())"
        var params: [String] = []
        for r in relays {
            let trimmed = r.hasSuffix("/") ? String(r.dropLast()) : r
            params.append("relay=\(percentEncode(trimmed))")
        }
        if let secret { params.append("secret=\(percentEncode(secret))") }
        if !params.isEmpty { out += "?" + params.joined(separator: "&") }
        return out
    }

    // MARK: - Random secret

    /// 16-hex-char (8 random bytes) secret. Matches the format `nostr-tools`
    /// emits for `nostrconnect://` URIs and that signer-side parsers expect.
    static func randomSecret16Hex() -> String {
        var raw = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, 8, &raw)
        return raw.map { String(format: "%02x", $0) }.joined()
    }

    static func randomRequestId() -> String {
        var raw = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, 8, &raw)
        return raw.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Encryption helpers

    /// Encrypt `plaintext` to `signerPubkey` using NIP-44 v2. We always send
    /// NIP-44 outbound — modern signers (Primal iOS, Clave, recent Amber) speak
    /// NIP-44 and at least one of them (Primal) refuses NIP-04 inbound entirely.
    static func encryptToSigner(plaintext: String, appPriv32: Data, signerPubkeyHex: String) throws -> String {
        guard let peer = Hex.decode(signerPubkeyHex.lowercased()), peer.count == 32 else {
            throw NipError.invalidKey
        }
        let convo = try Nip44.getConversationKey(privkey32: appPriv32, peerXonlyPubkey32: peer)
        return try Nip44.encrypt(plaintext: plaintext, conversationKey: convo)
    }

    /// Decrypt `payload` from `signerPubkey`. We accept BOTH NIP-04 and NIP-44
    /// inbound: some older Amber builds, and any client built on the legacy
    /// `nostr-connect` Rust crate, still send NIP-04 responses. NIP-04 payloads
    /// always contain `?iv=`; NIP-44 base64 never does.
    static func decryptFromSigner(payload: String, appPriv32: Data, signerPubkeyHex: String) throws -> String {
        guard let peer = Hex.decode(signerPubkeyHex.lowercased()), peer.count == 32 else {
            throw NipError.invalidKey
        }
        if payload.contains("?iv=") {
            let shared = try Schnorr.ecdhRawX(privkey32: appPriv32, xonlyPubkey32: peer)
            return try Nip04.decrypt(payload, sharedSecret: shared)
        }
        let convo = try Nip44.getConversationKey(privkey32: appPriv32, peerXonlyPubkey32: peer)
        return try Nip44.decrypt(payload: payload, conversationKey: convo)
    }

    // MARK: - JSON envelope

    /// Build the JSON request body `{"id":...,"method":...,"params":[...]}`.
    static func makeRequestJSON(id: String, method: String, params: [String]) -> String {
        var paramsJSON = "["
        for (i, p) in params.enumerated() {
            if i > 0 { paramsJSON.append(",") }
            paramsJSON.append("\"")
            paramsJSON.append(escape(p))
            paramsJSON.append("\"")
        }
        paramsJSON.append("]")
        return "{\"id\":\"\(escape(id))\",\"method\":\"\(escape(method))\",\"params\":\(paramsJSON)}"
    }

    /// Decoded NIP-46 response. Either `result` is non-nil OR `error` is
    /// non-nil; both being present is treated as an error.
    struct DecodedResponse {
        let id: String
        let result: String?
        let error: String?
    }

    static func decodeResponse(_ json: String) -> DecodedResponse? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else {
            return nil
        }
        let err = (obj["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // result can be a string OR a JSON-stringified object (sign_event).
        // Some signers return `result: null` on errors.
        let resultStr: String?
        if let s = obj["result"] as? String { resultStr = s.isEmpty ? nil : s }
        else { resultStr = nil }
        return DecodedResponse(id: id, result: resultStr, error: err)
    }

    // MARK: - URL encoding

    /// `application/x-www-form-urlencoded` percent encoding (space -> '+',
    /// unreserved set kept), matching JS `URLSearchParams.toString()`.
    /// Signer-side URI parsers (Primal iOS) reject encodings that don't match
    /// the byte shape `nostr-tools` emits.
    static func percentEncode(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count * 3)
        for byte in s.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39,
                 0x2D, 0x5F, 0x2E, 0x7E, 0x2A:
                out.append(Character(UnicodeScalar(byte)))
            case 0x20:
                out.append("+")
            default:
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }

    static func percentDecode(_ s: String) -> String {
        var out = [UInt8]()
        out.reserveCapacity(s.utf8.count)
        let bytes = Array(s.utf8)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x25, i + 2 < bytes.count {
                let hi = bytes[i + 1]
                let lo = bytes[i + 2]
                if let v = hexPairValue(hi: hi, lo: lo) {
                    out.append(v)
                    i += 3
                    continue
                }
            }
            if b == 0x2B { // '+'
                out.append(0x20)
            } else {
                out.append(b)
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexPairValue(hi: UInt8, lo: UInt8) -> UInt8? {
        guard let h = hexNibble(hi), let l = hexNibble(lo) else { return nil }
        return (h << 4) | l
    }

    private static func hexNibble(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if scalar.value < 0x20 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
