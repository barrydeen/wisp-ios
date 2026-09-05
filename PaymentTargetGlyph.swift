import SwiftUI

/// Monochrome marks for NIP-A3 payment target types.
///
/// Crypto marks come from spothq/cryptocurrency-icons (CC0-1.0), vendored into
/// `Assets.xcassets` as tintable single-colour SVGs (template rendering intent).
/// Payment apps (PayPal, Venmo, Revolut, Cash App) are deliberately absent: their
/// logos are trademarks, not open assets, so those types fall back to a plain
/// lettermark instead.
///
/// Ported from Dark Wisp Android's `PaymentTargetGlyph`.
struct PaymentTargetGlyph: View {
    let type: String
    var size: CGFloat = 18
    var tint: Color = .secondary

    var body: some View {
        if let asset = Self.assetName(for: type) {
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(tint)
                .accessibilityLabel(NipA3.displayName(type))
        } else if let symbol = Self.symbolName(for: type) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.9))
                .frame(width: size, height: size)
                .foregroundStyle(tint)
                .accessibilityLabel(NipA3.displayName(type))
        } else {
            Text(Self.letters(for: type))
                .font(.system(size: size * 0.55, weight: .semibold))
                .frame(width: size, height: size)
                .minimumScaleFactor(0.6)
                .foregroundStyle(tint)
                .accessibilityLabel(NipA3.displayName(type))
        }
    }

    /// Asset-catalog name of the vendored mark, or nil when there is none.
    static func assetName(for type: String) -> String? {
        switch type {
        case "bitcoin": return "PtBitcoin"
        case "bitcoincash": return "PtBitcoinCash"
        case "dash": return "PtDash"
        case "ethereum": return "PtEthereum"
        case "litecoin": return "PtLitecoin"
        case "monero": return "PtMonero"
        case "nano": return "PtNano"
        case "solana": return "PtSolana"
        case "zcash": return "PtZcash"
        // BIP-352 (silent payments) and BIP-353 (DNS payment instructions) are
        // Bitcoin address formats, so they carry the Bitcoin mark; the label
        // disambiguates them.
        case "bip352", "bip353": return "PtBitcoin"
        default: return nil
        }
    }

    /// SF Symbol fallback for types the vendored set doesn't cover but the system
    /// font does. Lightning reuses the bolt so it matches the zap affordances
    /// elsewhere in the app.
    static func symbolName(for type: String) -> String? {
        type == "lightning" ? "bolt.fill" : nil
    }

    /// Short lettermark for types with no redistributable icon.
    static func letters(for type: String) -> String {
        let name = NipA3.displayName(type)
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).filter { !$0.isEmpty }
        if words.count >= 2 {
            return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased()
        }
        if name.count >= 2 {
            return name.prefix(1).uppercased() + String(name.dropFirst().prefix(1))
        }
        return name.prefix(1).uppercased()
    }
}
