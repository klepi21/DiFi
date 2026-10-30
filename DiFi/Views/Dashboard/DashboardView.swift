import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Query private var incomes: [IncomeEntry]
    @Query private var expenses: [ExpenseEntry]
    @Query private var debts: [Debt]
    @Query private var cryptoHoldings: [CryptoHolding]
    @Query private var settingsQuery: [AppSettings]

    @State private var selectedMonth: Date = Calendar.current.startOfMonth(for: .now)

    private var settings: AppSettings { settingsQuery.first ?? AppSettings() }
    private var calendar: Calendar { .current }
    private var currentMonth: Date { selectedMonth }

    private var monthIncomes: [IncomeEntry] {
        incomes.filter { calendar.isDate($0.date, equalTo: currentMonth, toGranularity: .month) }
    }

    // Net income entered — VAT lives entirely on its own in the VAT tab (tracked automatically
    // from each income entry's vatRate) and is intentionally kept out of this breakdown.
    private var monthIncome: Double { monthIncomes.reduce(0) { $0 + $1.amount } }

    // Live projected tax-reserve rate — extrapolates YTD income to a full-year run-rate and
    // runs it through the real progressive brackets. Recalculates every time income is added.
    private var projectedRatePct: Double {
        projectedTaxReservePct(incomes: incomes, efkaMonthly: settings.efkaMonthly)
    }

    // Tax reserve this month — calculated on NET income (VAT was never part of taxable revenue)
    private var monthTaxReserve: Double { monthIncome * projectedRatePct / 100 }

    // ΕΦΚΑ this month
    private var monthEfka: Double { settings.efkaMonthly }

    // Total to set aside = tax reserve + ΕΦΚΑ (VAT excluded — it's tracked on its own VAT tab)
    private var monthSetAside: Double { monthTaxReserve + monthEfka }

    // What's actually yours = net income minus tax reserve and ΕΦΚΑ
    private var monthActuallyYours: Double { monthIncome - monthSetAside }

    // Only counts expenses actually logged this month (one-time entries, plus recurring
    // expenses once they've been marked paid — which logs its own ExpenseEntry). Recurring
    // expenses that haven't been marked paid yet are intentionally excluded.
    private var monthExpenses: Double {
        expenses
            .filter { calendar.isDate($0.date, equalTo: currentMonth, toGranularity: .month) }
            .reduce(0) { $0 + $1.amount }
    }

    private var surplus: Double { monthActuallyYours - monthExpenses }

    private var totalTaxReserve: Double {
        incomes.reduce(0) { $0 + $1.amount * projectedRatePct / 100 }
    }

    // Split the reserve into its two components: the total obligation is always
    // tax + 55% of tax (tax × 1.55), so the ratio between the two is fixed regardless
    // of the blended rate used to compute totalTaxReserve.
    private var totalTaxOnlyPortion: Double { totalTaxReserve / 1.55 }
    private var totalPrepaymentPortion: Double { totalTaxReserve - totalTaxOnlyPortion }

    private var portfolioValue: Double { cryptoHoldings.reduce(0) { $0 + $1.valueEUR } }
    private var totalDebt: Double { debts.reduce(0) { $0 + $1.currentBalance } }

    // Prior-year tax obligation that hasn't been closed out into Debts yet
    private var previousYear: Int { calendar.component(.year, from: .now) - 1 }
    private var previousYearHasIncome: Bool {
        incomes.contains { calendar.component(.year, from: $0.date) == previousYear }
    }
    private var previousYearDebtName: String { "Income Tax – \(previousYear)" }
    private var previousYearClosed: Bool { debts.contains { $0.name == previousYearDebtName } }
    private var previousYearObligation: Double {
        annualTaxObligation(incomes: incomes, efkaMonthly: settings.efkaMonthly, year: previousYear)
    }

    private var cashFlowData: [(month: String, income: Double, expenses: Double)] {
        (0..<6).reversed().compactMap { offset -> (String, Double, Double)? in
            guard let date = calendar.date(byAdding: .month, value: -offset, to: currentMonth) else { return nil }
            let monthInc = incomes.filter { calendar.isDate($0.date, equalTo: date, toGranularity: .month) }.reduce(0) { $0 + $1.amount }
            let monthExp = expenses.filter { calendar.isDate($0.date, equalTo: date, toGranularity: .month) }.reduce(0) { $0 + $1.amount }
            return (date.formatted(.dateTime.month(.abbreviated)), monthInc, monthExp)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Dashboard")
                        .font(.largeTitle.bold())
                    Spacer()
                    MonthPicker(selected: $selectedMonth)
                }

                // Prior-year tax obligation not yet moved to Debts
                if previousYearHasIncome && !previousYearClosed && previousYearObligation > 0 {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("\(String(previousYear)) tax obligation (\(previousYearObligation.euroFormatted)) hasn't been moved to Debts yet.")
                            .font(.subheadline)
                        Spacer()
                        Text("Close it in Reports")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.red.opacity(0.3), lineWidth: 1))
                }

                // "What's actually yours" — the most important card, full width on top
                MonthlyBreakdownCard(
                    monthLabel: (calendar.isDate(selectedMonth, equalTo: .now, toGranularity: .month) ? "This Month — " : "") + selectedMonth.formatted(.dateTime.month(.wide).year()),
                    netIncome: monthIncome,
                    taxReserve: monthTaxReserve,
                    taxReservePct: projectedRatePct,
                    efka: monthEfka,
                    actuallyYours: monthActuallyYours,
                    expenses: monthExpenses,
                    surplus: surplus
                )

                // Standard summary cards
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
                    SummaryCard(
                        title: "Tax Reserve",
                        value: totalTaxReserve.euroFormatted,
                        subtitle: "Tax \(totalTaxOnlyPortion.euroFormatted) · Prepay 55% \(totalPrepaymentPortion.euroFormatted)",
                        color: .purple,
                        icon: "building.columns.fill"
                    )
                    SummaryCard(title: "Portfolio", value: portfolioValue.euroFormatted, subtitle: "Current value", color: .teal, icon: "chart.line.uptrend.xyaxis")
                    SummaryCard(title: "Total Debt", value: totalDebt.euroFormatted, subtitle: "Remaining", color: .orange, icon: "creditcard.fill")
                }

                // Cash flow chart
                GroupBox("Monthly Cash Flow — Last 6 Months") {
                    Chart {
                        ForEach(cashFlowData, id: \.month) { d in
                            BarMark(x: .value("Month", d.month), y: .value("Income", d.income))
                                .foregroundStyle(.green.opacity(0.8))
                                .position(by: .value("Type", "Income"))
                            BarMark(x: .value("Month", d.month), y: .value("Expenses", d.expenses))
                                .foregroundStyle(.red.opacity(0.8))
                                .position(by: .value("Type", "Expenses"))
                        }
                    }
                    .chartLegend(.visible)
                    .frame(height: 200)
                    .padding(.top, 8)
                }

                // Live annual tax estimation — recalculates immediately as income is added
                AnnualTaxEstimationView(allIncomes: incomes, settings: settings)
            }
            .padding(24)
        }
    }
}

// MARK: - Monthly Breakdown Card

struct MonthlyBreakdownCard: View {
    let monthLabel: String
    let netIncome: Double
    let taxReserve: Double
    let taxReservePct: Double
    let efka: Double
    let actuallyYours: Double
    let expenses: Double
    let surplus: Double

    private var totalSetAside: Double { taxReserve + efka }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(monthLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("What's Actually Yours")
                        .font(.title2.bold())
                }
                Spacer()
                // Big "actually yours" number
                VStack(alignment: .trailing, spacing: 2) {
                    Text(actuallyYours.euroFormatted)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(actuallyYours >= 0 ? .green : .red)
                    Text("after tax obligations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()

            Divider()

            // Breakdown rows
            VStack(spacing: 0) {
                BreakdownRow(label: "Net Income", value: netIncome, color: .green, icon: "arrow.down.circle.fill", isMinus: false)

                BreakdownRow(label: "Tax Reserve (\(String(format: "%.1f", taxReservePct))%)", value: taxReserve, color: .purple, icon: "building.columns.fill", isMinus: true)

                if efka > 0 {
                    BreakdownRow(label: "ΕΦΚΑ", value: efka, color: .orange, icon: "person.fill", isMinus: true)
                }

                Divider().padding(.horizontal)

                // "Set aside" total — what you must NOT spend
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("Set aside this month")
                        .font(.subheadline.bold())
                    Spacer()
                    Text(totalSetAside.euroFormatted)
                        .font(.subheadline.bold())
                        .foregroundStyle(.yellow)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.yellow.opacity(0.08))
            }

            Divider()

            // Surplus row at bottom
            HStack {
                Image(systemName: surplus >= 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(surplus >= 0 ? .green : .red)
                Text("After expenses")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(surplus.euroFormatted)
                        .font(.headline)
                        .foregroundStyle(surplus >= 0 ? .green : .red)
                    Text("expenses: \(expenses.euroFormatted)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.green.opacity(0.2), lineWidth: 1))
    }
}

struct BreakdownRow: View {
    let label: String
    let value: Double
    let color: Color
    let icon: String
    let isMinus: Bool

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Text((isMinus ? "−" : "+") + " " + value.euroFormatted)
                .font(.subheadline.bold())
                .foregroundStyle(isMinus ? color.opacity(0.8) : color)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
