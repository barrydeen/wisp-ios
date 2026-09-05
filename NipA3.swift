import Foundation

/// NIP-A3: `payto:` Payment Targets (RFC-8905).
///
/// Kind 10133 is a replaceable event whose `["payto", "<type>", "<authority>"]` tags
/// declare payment addresses (bitcoin, monero, venmo, …) for the author. Clients
/// assemble `payto://<type>/<authority>` URIs from each tag.
///
/// Ported from Dark Wisp Android's `NipA3`.
nonisolated enum NipA3 {
    static let kind = 10133
    static let tagName = "payto"

    struct PaymentTarget: Hashable, Identifiable, Sendable {
        let type: String
        let authority: String

        var id: String { "\(type)|\(authority)" }
    }

    struct TargetStyle: Sendable {
        let displayName: String
        let ticker: String?

        init(_ displayName: String, _ ticker: String? = nil) {
            self.displayName = displayName
            self.ticker = ticker
        }
    }

    /// Types the UI styles and offers as quick-pick entries, in menu order. The first
    /// group is the NIP-A3 "Commonly Used Tags" list; the second is our own additions,
    /// which the spec allows since unrecognized types stay valid and fall back to
    /// `payto://`. Display names and tickers are ours — the spec prescribes no
    /// stylization. Visual marks live in `PaymentTargetGlyph`, not here: the protocol
    /// layer stays UI-free.
    ///
    /// Kept as an ordered array (not just the dictionary) because Swift dictionaries
    /// have no stable order and the picker must present these in a fixed sequence.
    static let recognizedOrder: [String] = [
        "lightning",
        "bitcoin",
        "bip352",
        "bip353",
        "monero",
        "ethereum",
        "solana",
        "litecoin",
        "zcash",
        "bitcoincash",
        "dash",
        "nano",
        "cashme",
        "paypal",
        "revolut",
        "venmo"
    ]

    static let recognized: [String: TargetStyle] = [
        "lightning": TargetStyle("Lightning", "LBTC"),
        "bitcoin": TargetStyle("Bitcoin", "BTC"),
        "bip352": TargetStyle("Silent Payments"),
        "bip353": TargetStyle("DNS Address"),
        "monero": TargetStyle("Monero", "XMR"),
        "ethereum": TargetStyle("Ethereum", "ETH"),
        "solana": TargetStyle("Solana", "SOL"),
        "litecoin": TargetStyle("Litecoin", "LTC"),
        "zcash": TargetStyle("Zcash", "ZEC"),
        "bitcoincash": TargetStyle("Bitcoin Cash", "BCH"),
        "dash": TargetStyle("Dash", "DASH"),
        "nano": TargetStyle("Nano", "XNO"),
        "cashme": TargetStyle("Cash App"),
        "paypal": TargetStyle("PayPal"),
        "revolut": TargetStyle("Revolut"),
        "venmo": TargetStyle("Venmo")
    ]

    /// Types with a widely supported native URI scheme; preferred over `payto://`,
    /// which essentially no wallet app registers a handler for.
    private static let nativeSchemes: [String: String] = [
        "bitcoin": "bitcoin:",
        "bitcoincash": "bitcoincash:",
        "dash": "dash:",
        "ethereum": "ethereum:",
        "lightning": "lightning:",
        "litecoin": "litecoin:",
        "monero": "monero:",
        "nano": "nano:",
        "solana": "solana:",
        "zcash": "zcash:"
    ]

    /// Lowercased, trimmed type, or nil if it isn't a valid payto type.
    static func normalizeType(_ raw: String) -> String? {
        let type = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !type.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard type.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return type
    }

    static func isValidAuthority(_ authority: String) -> Bool {
        guard !authority.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !authority.unicodeScalars.contains { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
        }
    }

    static func parse(_ event: NostrEvent) -> [PaymentTarget] {
        guard event.kind == kind else { return [] }
        var seen = Set<PaymentTarget>()
        var out: [PaymentTarget] = []
        for tag in event.tags {
            // Elements past index 2 are reserved for future RFC-8905 features; ignore them.
            guard tag.count >= 3, tag[0] == tagName else { continue }
            guard let type = normalizeType(tag[1]) else { continue }
            let authority = tag[2]
            guard isValidAuthority(authority) else { continue }
            let target = PaymentTarget(type: type, authority: authority)
            if seen.insert(target).inserted { out.append(target) }
        }
        return out
    }

    static func buildTags(_ targets: [PaymentTarget]) -> [[String]] {
        targets.map { [tagName, $0.type, $0.authority] }
    }

    static func assemblePaytoUri(_ target: PaymentTarget) -> String {
        // Mirrors Java's `URLEncoder.encode(…, "UTF-8")` with `+` rewritten to `%20`:
        // alphanumerics plus `.`, `-`, `*` and `_` pass through, everything else is
        // percent-encoded.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: ".-*_")
        let encoded = target.authority.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? target.authority
        return "payto://\(target.type)/\(encoded)"
    }

    /// URI for launching a wallet app: native scheme (`bitcoin:`, `monero:`, …) for
    /// recognized types since almost no wallet handles `payto://`, else `payto://`.
    static func nativeUri(_ target: PaymentTarget) -> String {
        if let scheme = nativeSchemes[target.type] { return scheme + target.authority }
        return assemblePaytoUri(target)
    }

    static func displayName(_ type: String) -> String {
        if let style = recognized[type] { return style.displayName }
        guard let first = type.first else { return type }
        return first.uppercased() + String(type.dropFirst())
    }

    static func ticker(_ type: String) -> String? { recognized[type]?.ticker }

    // MARK: - QR scanning

    /// Result of decoding a scanned QR payload. `type` is nil when the payload carried
    /// no scheme, in which case only the address could be recovered.
    struct ScanResult: Sendable {
        let type: String?
        let authority: String
    }

    /// scheme (without ":") → payto type, derived from `nativeSchemes`.
    private static let schemeToType: [String: String] = {
        var out: [String: String] = [:]
        for (type, scheme) in nativeSchemes {
            out[String(scheme.dropLast())] = type
        }
        return out
    }()

    /// Schemes that are never payment types. Scanning a website or profile QR by
    /// mistake should surface the raw payload, not invent an "https"/"nostr" type.
    private static let nonPaymentSchemes: Set<String> = [
        "http", "https", "nostr", "mailto", "tel", "sms", "geo"
    ]

    private static let bech32Charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    /// A silent payments address is bech32m over two 33-byte keys, so it runs ~110
    /// characters of bech32 charset. Checking shape and length — not just the "sp1"
    /// prefix — keeps a base58 address from another chain that happens to begin
    /// "sp1" from being misread as one.
    private static func isSilentPaymentAddress(_ authority: String) -> Bool {
        let lower = authority.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let body: Substring
        if lower.hasPrefix("tsp1") {
            body = lower.dropFirst(4)
        } else if lower.hasPrefix("sp1") {
            body = lower.dropFirst(3)
        } else {
            return false
        }
        return body.count >= 60 && body.allSatisfy { bech32Charset.contains($0) }
    }

    /// Bitcoin has several address formats that all travel under the `bitcoin:`
    /// scheme (or bare), so the scheme alone can't tell them apart. Recognize the
    /// ones with unambiguous shapes:
    ///  - BIP-352 silent payments are bech32m with an `sp` HRP (`tsp` on testnet)
    ///  - BIP-353 DNS instructions are a ₿-prefixed name, e.g. ₿alice@example.com
    private static func bitcoinFormat(for authority: String) -> String? {
        let a = authority.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSilentPaymentAddress(a) { return "bip352" }
        if a.hasPrefix("\u{20BF}") && a.contains("@") { return "bip353" }
        return nil
    }

    /// BOLT11 invoices expire and LNURL is a callback, not an address, so neither
    /// belongs in a replaceable target list. A BIP-21 unified QR carries an invoice
    /// alongside the on-chain address, which makes this easy to scan by accident.
    static func isReusableLightningTarget(_ authority: String) -> Bool {
        let a = authority.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !a.hasPrefix("lnbc") && !a.hasPrefix("lntb")
            && !a.hasPrefix("lnbcrt") && !a.hasPrefix("lnurl")
    }

    /// Only overrides an unset or plain-bitcoin type; an explicit type is respected.
    private static func refineType(_ type: String?, authority: String) -> String? {
        guard type == nil || type == "bitcoin" else { return type }
        return bitcoinFormat(for: authority) ?? type
    }

    /// Decode a scanned QR payload into a type + address.
    ///
    /// Handles `payto://<type>/<address>` (RFC-8905), native wallet schemes
    /// (`bitcoin:`, `monero:`, …) and bare addresses. Query strings such as
    /// `?amount=` are dropped, since a payment target stores only the address.
    static func parseScannedUri(_ raw: String) -> ScanResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ScanResult(type: nil, authority: "") }

        let paytoPrefix = "payto://"
        if trimmed.lowercased().hasPrefix(paytoPrefix) {
            let stripped = prefixBefore(prefixBefore(String(trimmed.dropFirst(paytoPrefix.count)), "?"), "#")
            let type = normalizeType(prefixBefore(stripped, "/"))
            let rawAuthority = suffixAfter(stripped, "/") ?? ""
            let authority = rawAuthority.removingPercentEncoding ?? rawAuthority
            return ScanResult(type: refineType(type, authority: authority), authority: authority)
        }

        if let (scheme, remainder) = splitScheme(trimmed) {
            // Strip an authority-style "//" prefix, then any query/fragment.
            var body = remainder
            if body.hasPrefix("//") { body = String(body.dropFirst(2)) }
            body = prefixBefore(prefixBefore(body, "?"), "#")
            if nonPaymentSchemes.contains(scheme) {
                return ScanResult(type: nil, authority: trimmed)
            }
            let type = schemeToType[scheme] ?? normalizeType(scheme)
            return ScanResult(type: refineType(type, authority: body), authority: body)
        }

        // Bare address — the caller keeps whichever type is already selected,
        // unless the address shape itself identifies a Bitcoin format.
        let bare = prefixBefore(trimmed, "?")
        return ScanResult(type: refineType(nil, authority: bare), authority: bare)
    }

    /// Everything in `s` before the first `separator`, or all of `s` when it
    /// doesn't occur. Kotlin's `substringBefore` by another name. Lives here
    /// rather than in a `String` extension because the project defaults new
    /// declarations to `@MainActor`, and this file is `nonisolated`.
    private static func prefixBefore(_ s: String, _ separator: Character) -> String {
        guard let idx = s.firstIndex(of: separator) else { return s }
        return String(s[s.startIndex..<idx])
    }

    /// Everything in `s` after the first `separator`, or nil when absent.
    private static func suffixAfter(_ s: String, _ separator: Character) -> String? {
        guard let idx = s.firstIndex(of: separator) else { return nil }
        return String(s[s.index(after: idx)...])
    }

    /// Splits `scheme:rest` when the leading token is a syntactically valid URI
    /// scheme (`[a-zA-Z][a-zA-Z0-9+.-]*`). Returns the lowercased scheme.
    private static func splitScheme(_ s: String) -> (scheme: String, rest: String)? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let scheme = String(s[s.startIndex..<colon])
        guard let first = scheme.first, first.isLetter else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+.-"))
        guard scheme.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return (scheme.lowercased(), String(s[s.index(after: colon)...]))
    }
}
