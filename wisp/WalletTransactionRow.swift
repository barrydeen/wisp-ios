import SwiftUI

/// A single row in a wallet transaction list. Used by both the dashboard
/// recent-strip and the full TransactionHistoryView.
struct WalletTransactionRow: View {
    let tx: WalletTransaction

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
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(isIncoming ? "+" : "-")\(CurrencyFormatter.formatNumber(sats))")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(amountColor)
                    Text("sats")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !isIncoming, feeSats > 0 {
                    Text("Fee: \(CurrencyFormatter.formatNumber(feeSats)) sats")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
    }
}
