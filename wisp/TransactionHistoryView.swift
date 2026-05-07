import SwiftUI

struct TransactionHistoryView: View {
    @Bindable var store: WalletStore
    @State private var isLoadingMore = false

    var body: some View {
        Group {
            if store.transactions.isEmpty {
                emptyState
            } else {
                transactionList
            }
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .navigationTitle("Transactions")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .task { await store.refreshTransactions() }
    }

    private var transactionList: some View {
        List {
            ForEach(store.transactions) { tx in
                WalletTransactionRow(tx: tx)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.wispBackground)
                    .listRowSeparatorTint(Color.wispSurfaceVariant.opacity(0.4))
            }

            if store.hasMoreTransactions {
                HStack {
                    Spacer()
                    Button {
                        Task { await loadMore() }
                    } label: {
                        Group {
                            if isLoadingMore {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Text("Load more")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.wispZapColor)
                            }
                        }
                        .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingMore)
                    Spacer()
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(Color.wispBackground)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable {
            await store.refreshTransactions()
        }
    }

    private func loadMore() async {
        isLoadingMore = true
        defer { isLoadingMore = false }
        await store.loadMoreTransactions()
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: store.lastTransactionError == nil ? "bolt.slash" : "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(store.lastTransactionError == nil ? Color.secondary.opacity(0.5) : .orange)
                if let err = store.lastTransactionError {
                    Text("Couldn't load transactions")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("Try again") {
                        Task { await store.refreshTransactions() }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.wispZapColor)
                    .padding(.top, 4)
                } else {
                    Text("No transactions yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 80)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store.refreshTransactions() }
    }
}
