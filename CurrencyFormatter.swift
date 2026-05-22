import Foundation

@MainActor
enum CurrencyFormatter {
    /// Compact representation used inline (e.g. zap counts on a post action bar).
    /// Returns "21k", "1.2M" for sats; "$12.34" for fiat.
    static func short(sats: Int64) -> String {
        if let fiat = fiatRendered(sats: sats) {
            return fiat
        }
        return formatSatsShort(sats)
    }

    /// Full representation used in detailed surfaces (invoice screen, wallet balance).
    /// Returns "21,000 sats" or e.g. "$12.34".
    static func full(sats: Int64) -> String {
        if let fiat = fiatRendered(sats: sats) {
            return fiat
        }
        return formatSatsFull(sats)
    }

    // MARK: - Sats helpers

    static func formatSatsShort(_ n: Int64) -> String {
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 {
            let v = Double(n) / 1_000.0
            return v >= 10 ? "\(Int(v))k" : String(format: "%.1fk", v)
        }
        if n < 1_000_000_000 {
            let v = Double(n) / 1_000_000.0
            return v >= 10 ? "\(Int(v))M" : String(format: "%.1fM", v)
        }
        let v = Double(n) / 1_000_000_000.0
        return v >= 10 ? "\(Int(v))B" : String(format: "%.1fB", v)
    }

    static func formatSatsFull(_ n: Int64) -> String {
        return "\(formatNumber(n)) sats"
    }

    /// Just the grouped number, no unit suffix. Used when "sats" is rendered
    /// as a separate UI label so callers don't duplicate it.
    static func formatNumber(_ n: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - Fiat helpers

    /// Returns nil when fiat mode is off OR there is no cached rate available yet.
    private static func fiatRendered(sats: Int64) -> String? {
        let settings = AppSettings.shared
        guard settings.fiatModeEnabled else { return nil }
        guard let amount = ExchangeRateCache.shared.satsToFiat(sats, currency: settings.fiatCurrency) else {
            return nil
        }
        let currency = ExchangeRateService.currency(for: settings.fiatCurrency)
        return render(amount: amount, currency: currency)
    }

    /// Renders `sats` as a fiat string for the wallet screen's own fiat mode,
    /// independent of the app-wide `fiatModeEnabled` setting. Returns nil when
    /// no exchange rate is cached for the selected currency yet.
    static func walletFiat(sats: Int64) -> String? {
        let settings = AppSettings.shared
        guard let amount = ExchangeRateCache.shared.satsToFiat(sats, currency: settings.fiatCurrency) else {
            return nil
        }
        return render(amount: amount, currency: ExchangeRateService.currency(for: settings.fiatCurrency))
    }

    private static func render(amount: Double, currency: FiatCurrency) -> String {
        let abs = Swift.abs(amount)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        // Sub-dollar amounts use a `min = 0` floor so trailing zeros drop —
        // "$0.84" instead of "$0.840", "$0.8" instead of "$0.800". The cap
        // grows as the value shrinks so we don't lose precision on tiny
        // amounts. Whole-dollar amounts keep two decimal places (the
        // expected retail convention: "$1.00", not "$1").
        if abs == 0 {
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
        } else if abs < 0.001 {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 6
        } else if abs < 0.01 {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 4
        } else if abs < 1.0 {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 3
        } else if abs >= 1000.0 {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 0
        } else {
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
        }
        let body = formatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
        return "\(currency.symbol)\(body)"
    }
}

/// Synchronous main-actor wrapper around `ExchangeRateService` for formatter call sites
/// that can't easily await an actor (e.g. inside view bodies). Mirrors the actor's last
/// snapshot; refreshed on app launch and whenever the actor finishes a refresh cycle.
@MainActor
final class ExchangeRateCache {
    static let shared = ExchangeRateCache()
    private(set) var rates: [String: Double] = [:]
    private(set) var updatedAt: Date? = nil

    private init() {}

    func satsToFiat(_ sats: Int64, currency code: String) -> Double? {
        guard let btcPrice = rates[code.uppercased()] else { return nil }
        return Double(sats) / 100_000_000.0 * btcPrice
    }

    /// Inverse of `satsToFiat` — convert a fiat amount in the currency's
    /// major unit (dollars, euros, etc.) into sats. Returns nil when no
    /// rate is cached. Used by the zap sheet's custom amount input in fiat
    /// mode where the user types `1.50` for a $1.50 zap.
    func fiatToSats(_ majorAmount: Double, currency code: String) -> Int64? {
        guard let btcPrice = rates[code.uppercased()] else { return nil }
        return Int64((majorAmount / btcPrice * 100_000_000.0).rounded())
    }

    func updateFromService() async {
        let snap = await ExchangeRateService.shared.snapshot()
        self.rates = snap.rates
        self.updatedAt = snap.updatedAt
    }
}
