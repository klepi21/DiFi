import SwiftUI
import SwiftData
import Charts

/// Live Kraken portfolio view — no manual entry. "Sync" pulls balances, prices, and
/// open orders directly from the Kraken API and caches the result as CryptoHolding
/// rows so the dashboard/reports have something to read between syncs.
struct CryptoView: View {
    @Environment(\.modelContext) private var context
    @Query(
        filter: #Predicate<CryptoHolding> { $0.source == "kraken" },
        sort: \CryptoHolding.valueEUR, order: .reverse
    ) private var holdings: [CryptoHolding]

    // Non-custodial ERC-20 wallet, watched read-only alongside the Kraken account — no keys,
    // just the public address. Only tokens worth more than $1 are shown to keep dust out.
    // Persisted as CryptoHolding rows (source == "wallet") so the Dashboard's portfolio total
    // and the Allocation chart pick them up the same way Kraken holdings do.
    @Query(
        filter: #Predicate<CryptoHolding> { $0.source == "wallet" },
        sort: \CryptoHolding.valueEUR, order: .reverse
    ) private var walletHoldings: [CryptoHolding]
    // Public address to watch, set in Settings. Empty means wallet sync is skipped.
    @AppStorage(WalletSettingsKey.address) private var watchedWalletAddress: String = ""

    @State private var openOrders: [KrakenOpenOrder] = []
    @State private var isSyncing = false
    @State private var syncError: String?
    @State private var lastSynced: Date?
    @State private var costBasisError: String?
    @State private var tradeHistory: [String: [CryptoTrade]] = [:]
    @State private var historySelection: HistorySelection?

    @State private var isWalletSyncing = false
    @State private var walletSyncError: String?
    @State private var walletLastSynced: Date?

    private var totalValue: Double {
        let krakenTotal = holdings.reduce(0) { $0 + $1.valueEUR }
        let walletTotal = walletHoldings.reduce(0) { $0 + $1.valueEUR }
        return krakenTotal + walletTotal
    }

    /// One entry per asset across both sources (Kraken + watched wallet), merged by symbol so a
    /// token held in both places shows as a single allocation slice instead of two.
    private var allocation: [AllocationEntry] {
        var bySymbol: [String: Double] = [:]
        for h in holdings { bySymbol[h.displayName, default: 0] += h.valueEUR }
        for t in walletHoldings { bySymbol[t.displayName, default: 0] += t.valueEUR }
        return bySymbol.map { AllocationEntry(symbol: $0.key, valueEUR: $0.value) }
            .sorted { $0.valueEUR > $1.valueEUR }
    }

    private struct AllocationEntry: Identifiable {
        let symbol: String
        let valueEUR: Double
        var id: String { symbol }
    }

    /// Sum of cost basis across holdings that have one — holdings with no trade history (e.g.
    /// deposited coins) are excluded from both sides so they don't silently distort the total %.
    /// Wallet holdings never have a cost basis (no trade history for a non-custodial address), so
    /// this deliberately only looks at Kraken holdings.
    private var totalCostBasis: Double? {
        let known = holdings.compactMap(\.costBasisEUR)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    private var totalCostedValue: Double {
        holdings.filter { $0.costBasisEUR != nil }.reduce(0) { $0 + $1.valueEUR }
    }

    private var totalChangeEUR: Double? {
        totalCostBasis.map { totalCostedValue - $0 }
    }

    private var totalChangePercent: Double? {
        guard let totalCostBasis, totalCostBasis > 0 else { return nil }
        return (totalCostedValue - totalCostBasis) / totalCostBasis * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Crypto")
                    .font(.largeTitle.bold())
                Spacer()
                if let lastSynced {
                    Text("Synced \(lastSynced.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await sync() }
                } label: {
                    if isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Sync from Kraken", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSyncing)
            }
            .padding()

            if let syncError {
                Text(syncError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            HStack(spacing: 16) {
                SummaryCard(title: "Total Value", value: totalValue.euroFormatted, color: .teal, icon: "chart.pie.fill")
                if let totalChangePercent, let totalChangeEUR {
                    SummaryCard(
                        title: "Total P&L",
                        value: totalChangePercent.signedPercentFormatted,
                        subtitle: "\(totalChangeEUR >= 0 ? "+" : "")\(totalChangeEUR.euroFormatted)",
                        color: totalChangeEUR >= 0 ? .green : .red,
                        icon: totalChangeEUR >= 0 ? "arrow.up.right" : "arrow.down.right"
                    )
                } else {
                    SummaryCard(title: "Total P&L", value: "—", subtitle: costBasisError ?? "No trade history", color: .secondary, icon: "arrow.up.arrow.down")
                }
                SummaryCard(title: "Assets", value: "\(holdings.count + walletHoldings.count)", color: .blue, icon: "bitcoinsign.circle.fill")
                SummaryCard(title: "Open Orders", value: "\(openOrders.count)", color: .orange, icon: "clock.fill")
            }
            .padding(.horizontal)

            if !allocation.isEmpty {
                DisclosureGroup(isExpanded: .constant(true)) {
                    HStack(alignment: .top, spacing: 20) {
                        Chart(allocation) { entry in
                            SectorMark(angle: .value("Value", entry.valueEUR), innerRadius: .ratio(0.55))
                                .foregroundStyle(by: .value("Asset", entry.symbol))
                        }
                        .frame(width: 140, height: 140)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(allocation) { entry in
                                HStack(spacing: 8) {
                                    CryptoLogoView(symbol: entry.symbol, size: 18)
                                    Text(entry.symbol).font(.caption)
                                    Spacer()
                                    Text(totalValue > 0 ? "\(String(format: "%.1f", entry.valueEUR / totalValue * 100))%" : "—")
                                        .font(.caption.bold())
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Allocation").font(.headline)
                }
                .padding()
            }

            Divider()

            if holdings.isEmpty && walletHoldings.isEmpty {
                VStack {
                    Spacer()
                    ContentUnavailableView(
                        "No synced balances yet",
                        systemImage: "bitcoinsign.circle",
                        description: Text("Add your Kraken API key in Settings, then tap Sync from Kraken.")
                    )
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    if !holdings.isEmpty {
                        Section("Balances") {
                        ForEach(holdings) { h in
                            HStack(spacing: 12) {
                                CryptoLogoView(symbol: h.displayName, size: 40)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.displayName).font(.headline)
                                    Text("\(h.amount.coinFormatted) \(h.displayName)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(h.valueEUR.euroFormatted).font(.headline)
                                        if let changePercent = h.changePercent {
                                            Text(changePercent.signedPercentFormatted)
                                                .font(.caption.bold())
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background((changePercent >= 0 ? Color.green : Color.red).opacity(0.15), in: Capsule())
                                                .foregroundStyle(changePercent >= 0 ? Color.green : Color.red)
                                        }
                                    }
                                    HStack(spacing: 4) {
                                        Text("@ \(h.priceEUR.euroFormatted)")
                                        if totalValue > 0 {
                                            Text("· \(String(format: "%.1f", h.valueEUR / totalValue * 100))%")
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    if let changeEUR = h.changeEUR {
                                        Text("\(changeEUR >= 0 ? "+" : "")\(changeEUR.euroFormatted) unrealized")
                                            .font(.caption2)
                                            .foregroundStyle(changeEUR >= 0 ? Color.green : Color.red)
                                    }
                                }

                                if tradeHistory[h.displayName]?.isEmpty == false {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard tradeHistory[h.displayName]?.isEmpty == false else { return }
                                historySelection = HistorySelection(asset: h.displayName)
                            }
                        }
                        }
                    }

                    Section {
                        if let walletSyncError {
                            Text(walletSyncError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else if walletHoldings.isEmpty {
                            Text("No tokens over $1 found.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(walletHoldings) { t in
                            HStack(spacing: 12) {
                                CryptoLogoView(symbol: t.displayName, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.displayName).font(.headline)
                                    Text(t.amount.coinFormatted)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(t.valueEUR.euroFormatted).font(.headline)
                                    HStack(spacing: 4) {
                                        Text("@ \(t.priceEUR.euroFormatted)")
                                        if totalValue > 0 {
                                            Text("· \(String(format: "%.1f", t.valueEUR / totalValue * 100))%")
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        HStack {
                            Text("Wallet (ERC-20)")
                            Spacer()
                            if let walletLastSynced {
                                Text("Synced \(walletLastSynced.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption2)
                            }
                            Button {
                                Task { await syncWallet() }
                            } label: {
                                if isWalletSyncing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(isWalletSyncing)
                        }
                    }

                    if !openOrders.isEmpty {
                        Section("Open Orders") {
                            ForEach(openOrders) { order in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(order.pair).font(.headline)
                                            Text(order.type.uppercased())
                                                .font(.caption2).padding(.horizontal, 5).padding(.vertical, 2)
                                                .background((order.type == "buy" ? Color.green : Color.red).opacity(0.2), in: Capsule())
                                                .foregroundStyle(order.type == "buy" ? Color.green : Color.red)
                                        }
                                        Text("\(order.orderType) · vol \(order.volume)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(order.price.isEmpty ? "market" : order.price)
                                        .font(.subheadline)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await sync() }
        .task { await syncWallet() }
        .sheet(item: $historySelection) { selection in
            CryptoTradeHistoryView(asset: selection.asset, trades: tradeHistory[selection.asset] ?? [])
        }
    }

    private struct HistorySelection: Identifiable {
        let asset: String
        var id: String { asset }
    }

    private func sync() async {
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }

        do {
            let balances = try await KrakenService.shared.fetchBalances()
            let prices = try await KrakenService.shared.fetchPricesEUR(for: balances.map(\.rawAsset))

            // Cost basis needs the "Query closed orders & trades" API permission, which not every
            // key grants — degrade gracefully to no P&L data rather than failing the whole sync,
            // but keep the reason around so the UI can explain the empty "—" instead of just showing it.
            var costBasis: [String: CryptoCostBasis] = [:]
            do {
                let ledger = try await KrakenService.shared.fetchLedgers()
                costBasis = KrakenService.shared.costBasisByAsset(fromLedger: ledger)
                tradeHistory = KrakenService.shared.tradeHistoryByAsset(fromLedger: ledger)
                if costBasis.isEmpty {
                    // Debug breadcrumb: summarize what we actually saw so a mismatched ledger
                    // "type" or asset code (Kraken varies these) shows up directly instead of a bare "—".
                    let byType = Dictionary(grouping: ledger, by: \.type).mapValues { $0.count }
                    let typesSummary = byType.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: ", ")
                    let assetsSummary = Set(ledger.map(\.rawAsset)).sorted().joined(separator: ", ")
                    costBasisError = "No EUR trade history matched (\(ledger.count) entries). Types: [\(typesSummary)]. Assets: [\(assetsSummary)]"
                } else {
                    costBasisError = nil
                }
            } catch {
                costBasisError = error.localizedDescription
                tradeHistory = [:]
            }

            // Replace cached holdings wholesale with the fresh snapshot.
            for existing in holdings { context.delete(existing) }
            for balance in balances {
                let price = balance.displayName == "EUR" ? 1.0 : (prices[balance.rawAsset] ?? 0)
                context.insert(CryptoHolding(
                    rawAsset: balance.rawAsset,
                    displayName: balance.displayName,
                    amount: balance.amount,
                    priceEUR: price,
                    costBasisEUR: costBasis[balance.displayName]?.costEUR
                ))
            }
            try? context.save()

            openOrders = try await KrakenService.shared.fetchOpenOrders()
            lastSynced = .now
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func syncWallet() async {
        let address = watchedWalletAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        isWalletSyncing = true
        walletSyncError = nil
        defer { isWalletSyncing = false }

        do {
            let result = try await EthWalletService.shared.fetchHoldings(address: address)

            // Merge rather than wholesale-replace: CoinGecko's key-less API is rate-limited
            // enough that any single token's price can fail to load on a given pass (this bit us
            // once already — a rate-limited PORK lookup silently vanished the cached row). A
            // cached row is only removed once we're sure it should go: either its contract is no
            // longer held on-chain at all, or this round successfully repriced it below the
            // threshold. If we simply couldn't price it this round, the stale cached value is
            // kept rather than dropped.
            for existing in walletHoldings {
                let stillOnChain = existing.rawAsset == "ETH" ? result.hasEthBalance : result.onChainContracts.contains(existing.rawAsset.lowercased())
                guard !stillOnChain else {
                    let pricedThisRound = existing.rawAsset == "ETH" ? result.ethPriced : result.pricedContracts.contains(existing.rawAsset.lowercased())
                    if pricedThisRound, !result.holdings.contains(where: { ($0.contractAddress ?? "ETH").lowercased() == existing.rawAsset.lowercased() }) {
                        context.delete(existing) // priced this round, now below the threshold
                    }
                    continue
                }
                context.delete(existing) // no longer held on-chain at all
            }

            for token in result.holdings {
                let key = token.contractAddress ?? "ETH"
                if let existingRow = walletHoldings.first(where: { $0.rawAsset.lowercased() == key.lowercased() }) {
                    existingRow.amount = token.amount
                    existingRow.priceEUR = token.priceEUR
                    existingRow.valueEUR = token.amount * token.priceEUR
                    existingRow.lastSyncedAt = .now
                } else {
                    context.insert(CryptoHolding(
                        rawAsset: key,
                        displayName: token.symbol,
                        amount: token.amount,
                        priceEUR: token.priceEUR,
                        source: "wallet"
                    ))
                }
            }
            try? context.save()

            walletLastSynced = .now
        } catch {
            walletSyncError = error.localizedDescription
        }
    }
}
