import SwiftUI

/// A single row in a wallet transaction list. Used by both the dashboard
/// recent-strip and the full TransactionHistoryView.
struct WalletTransactionRow: View {
    let tx: WalletTransaction
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let isIncoming = tx.type == .incoming
        // Counterparty resolution: prefer whatever the wallet backend
        // surfaced (none currently set this), then fall back to the
        // direction-appropriate paymentHash → pubkey map. Outgoing zaps
        // are recorded by ZapSender at zap time; incoming zaps are
        // recorded by NotificationsViewModel as kind-9735 receipts arrive
        // for the active user.
        let counterpartyPubkey = tx.counterpartyPubkey
            ?? (isIncoming
                ? ZapSender.sender(forPaymentHash: tx.paymentHash)
                : ZapSender.recipient(forPaymentHash: tx.paymentHash))
        let profile = counterpartyPubkey.flatMap { ProfileRepository.shared.get($0) }
        let amountColor: Color = isIncoming ? Color.wispRepostColor : .red.opacity(0.85)
        let sats = abs(tx.amountMsats) / 1000
        let feeSats = tx.feeMsats / 1000
        let sign = isIncoming ? "+" : "-"
        // Use fiat formatting only when the rate cache has actually loaded —
        // otherwise `CurrencyFormatter.full` falls back to a "X sats" string
        // and the layout would render that inline next to a stale "sats"
        // suffix label. Checking the cache directly keeps the two-Text
        // sats layout intact while the rate is in flight.
        let fiatAmount: String? = settings.fiatModeEnabled
            ? ExchangeRateCache.shared.satsToFiat(sats, currency: settings.fiatCurrency)
                .map { _ in CurrencyFormatter.full(sats: sats) }
            : nil
        let fiatFee: String? = (settings.fiatModeEnabled && feeSats > 0)
            ? ExchangeRateCache.shared.satsToFiat(feeSats, currency: settings.fiatCurrency)
                .map { _ in CurrencyFormatter.full(sats: feeSats) }
            : nil

        HStack(alignment: .center, spacing: 12) {
            ZStack {
                if let profile {
                    CachedAvatarView(url: profile.picture, size: 40)
                } else {
                    Circle()
                        .fill((isIncoming ? Color.wispRepostColor : Color.red).opacity(0.18))
                        .frame(width: 40, height: 40)
                    Image(systemName: isIncoming ? "arrow.down" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(amountColor)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.displayString ?? (tx.description?.isEmpty == false ? tx.description! : (isIncoming ? "Received" : "Sent")))
                    .font(.subheadline.weight(profile != nil ? .semibold : .regular))
                    .lineLimit(1)
                Text(relativeTime(from: Int(tx.settledAt ?? tx.createdAt)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let fiatAmount {
                    Text("\(sign)\(fiatAmount)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(amountColor)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(sign)\(CurrencyFormatter.formatNumber(sats))")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(amountColor)
                        Text("sats")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !isIncoming, feeSats > 0 {
                    if let fiatFee {
                        Text("Fee: \(fiatFee)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Fee: \(CurrencyFormatter.formatNumber(feeSats)) sats")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
    }
}
