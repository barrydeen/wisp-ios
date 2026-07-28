import Foundation

// MARK: - Input type

/// Lightweight, SDK-agnostic representation of LNURL-pay info.
struct ResolvedLnurlInfo {
    let minSats: Int64
    let maxSats: Int64
    /// Display label (lightning address or domain)
    let label: String
}

enum WalletInputType {
    case unknown
    case bolt11(amountSats: Int64?)
    /// Spark SDK has already parsed this — payRequest is an opaque box that
    /// WalletStore unpacks when calling the SDK.
    case sparkLnurl(info: ResolvedLnurlInfo)
    /// NWC (or fallback) path: resolve LNURL manually from the address string.
    case lightningAddressNeedsResolve(String, info: ResolvedLnurlInfo?)

    var needsAmountEntry: Bool {
        switch self {
        case .bolt11(let amt): return amt == nil
        case .sparkLnurl, .lightningAddressNeedsResolve: return true
        case .unknown: return false
        }
    }

    var isPayable: Bool {
        switch self {
        case .bolt11(let amt): return amt != nil
        default: return false
        }
    }

    var resolvedInfo: ResolvedLnurlInfo? {
        switch self {
        case .sparkLnurl(let i): return i
        case .lightningAddressNeedsResolve(_, let i): return i
        default: return nil
        }
    }
}

// MARK: - LNURL resolver (NWC fallback path)

enum LnurlResolver {
    /// Returns true when the string looks like `user@domain.tld`.
    static func isLightningAddress(_ s: String) -> Bool {
        let parts = s.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return false }
        let user = String(parts[0])
        let domain = String(parts[1])
        return !user.isEmpty && domain.contains(".") && !domain.hasSuffix(".")
    }

    /// Manually resolve a lightning address or lnurl: URI and fetch a bolt11 invoice.
    static func resolve(_ input: String, amountMsats: Int64) async -> Result<String, WalletError> {
        do {
            // Derive the LNURL-pay URL.
            let payUrl: URL
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if trimmed.hasPrefix("lnurl1") {
                // Bech32-encoded LNURL: decode to the underlying HTTPS URL.
                guard let (hrp, data) = Bech32.decode(trimmed),
                      hrp == "lnurl",
                      let decodedUrl = String(data: data, encoding: .utf8),
                      let url = URL(string: decodedUrl) else {
                    return .failure(.other("Invalid LNURL encoding"))
                }
                payUrl = url
            } else if isLightningAddress(trimmed) {
                let parts = trimmed.split(separator: "@", maxSplits: 1)
                let user = String(parts[0])
                let domain = String(parts[1])
                guard let url = URL(string: "https://\(domain)/.well-known/lnurlp/\(user)") else {
                    return .failure(.other("Invalid lightning address"))
                }
                payUrl = url
            } else {
                return .failure(.other("Unrecognised payment input"))
            }

            // Step 1: Fetch LNURL-pay metadata.
            let (metaData, metaResponse) = try await URLSession.shared.data(from: payUrl)
            guard let http = metaResponse as? HTTPURLResponse, http.statusCode == 200,
                  let meta = try? JSONDecoder().decode(LnurlPayMeta.self, from: metaData) else {
                return .failure(.other("Could not reach lightning address provider"))
            }
            guard meta.tag == "payRequest" else {
                return .failure(.other("Not a LNURL-pay endpoint"))
            }
            let clampedMsats = max(Int64(meta.minSendable), min(amountMsats, Int64(meta.maxSendable)))
            guard var callbackUrl = URLComponents(string: meta.callback) else {
                return .failure(.other("Invalid LNURL callback"))
            }
            var params = callbackUrl.queryItems ?? []
            params.append(URLQueryItem(name: "amount", value: "\(clampedMsats)"))
            callbackUrl.queryItems = params
            guard let cbUrl = callbackUrl.url else {
                return .failure(.other("Could not build callback URL"))
            }

            // Step 2: Fetch the invoice.
            let (invData, invResponse) = try await URLSession.shared.data(from: cbUrl)
            guard let http2 = invResponse as? HTTPURLResponse, http2.statusCode == 200,
                  let inv = try? JSONDecoder().decode(LnurlInvoice.self, from: invData),
                  let bolt11 = inv.pr else {
                return .failure(.other("Could not fetch invoice from provider"))
            }
            return .success(bolt11)
        } catch {
            return .failure(.other(error.localizedDescription))
        }
    }

    // Codable helpers for LNURL-pay JSON.
    private struct LnurlPayMeta: Decodable {
        let tag: String
        let callback: String
        let minSendable: Int64
        let maxSendable: Int64
    }
    private struct LnurlInvoice: Decodable {
        let pr: String?
    }
}
