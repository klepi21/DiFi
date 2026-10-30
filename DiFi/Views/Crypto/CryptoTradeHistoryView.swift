import SwiftUI

/// Trade-by-trade buy/sell history for one crypto asset, derived from Kraken's ledger.
struct CryptoTradeHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let asset: String
    let trades: [CryptoTrade]

    var body: some View {
        NavigationStack {
            List(trades) { trade in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trade.isBuy ? "Buy" : "Sell")
                            .font(.caption.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background((trade.isBuy ? Color.green : Color.red).opacity(0.15), in: Capsule())
                            .foregroundStyle(trade.isBuy ? Color.green : Color.red)
                        Text(trade.time.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(trade.assetAmount.coinFormatted) \(asset)").font(.subheadline)
                        Text("\(trade.eurAmount.euroFormatted) @ \(trade.priceEUR.euroFormatted)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if trade.feeEUR > 0 {
                            Text("fee \(trade.feeEUR.euroFormatted)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .navigationTitle("\(asset) Trade History")
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            #else
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
        .frame(minWidth: 360, minHeight: 420)
    }
}
