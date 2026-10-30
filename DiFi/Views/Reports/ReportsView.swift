import SwiftUI
import SwiftData

struct ReportsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \IncomeEntry.date, order: .reverse) private var incomes: [IncomeEntry]
    @Query(sort: \ExpenseEntry.date, order: .reverse) private var expenses: [ExpenseEntry]
    @Query private var recurringExpenses: [RecurringExpense]
    @Query private var debts: [Debt]
    @Query private var cryptoHoldings: [CryptoHolding]
    @Query(sort: \VatPayment.month, order: .reverse) private var vatPayments: [VatPayment]
    @Query private var settingsQuery: [AppSettings]

    @State private var selectedMonth: Date = Calendar.current.startOfMonth(for: .now)
    @State private var copiedReport = false
    @State private var copiedAI = false
    @State private var confirmCloseYear = false

    private var settings: AppSettings { settingsQuery.first ?? AppSettings() }

    // MARK: - Prior year tax closure

    private var currentCalendarYear: Int { Calendar.current.component(.year, from: .now) }
    private var previousYear: Int { currentCalendarYear - 1 }
    private var previousYearIncomes: [IncomeEntry] {
        incomes.filter { Calendar.current.component(.year, from: $0.date) == previousYear }
    }
    private var previousYearDebtName: String { "Income Tax – \(previousYear)" }
    private var previousYearClosed: Bool { debts.contains { $0.name == previousYearDebtName } }
    private var previousYearObligation: Double {
        annualTaxObligation(incomes: incomes, efkaMonthly: settings.efkaMonthly, year: previousYear)
    }

    private func closePreviousYear() {
        let amount = previousYearObligation
        guard amount > 0 else { return }
        context.insert(Debt(
            name: previousYearDebtName,
            totalAmount: amount,
            currentBalance: amount,
            monthlyPayment: amount,
            notes: "Auto-created from \(previousYear) Annual Tax Estimation"
        ))
        try? context.save()
    }

    private var monthIncomes: [IncomeEntry] {
        incomes.filter { Calendar.current.isDate($0.date, equalTo: selectedMonth, toGranularity: .month) }
    }
    private var monthExpenses: [ExpenseEntry] {
        expenses.filter { Calendar.current.isDate($0.date, equalTo: selectedMonth, toGranularity: .month) }
    }
    private var activeRecurring: [RecurringExpense] { recurringExpenses.filter { $0.isActive } }

    // Live projected tax-reserve rate — see Extensions.swift for the run-rate projection logic
    private var projectedRatePct: Double {
        projectedTaxReservePct(incomes: incomes, efkaMonthly: settings.efkaMonthly)
    }

    private var grossIncome: Double { monthIncomes.reduce(0) { $0 + $1.amount } }
    private var taxReserve: Double { grossIncome * projectedRatePct / 100 }
    private var netIncome: Double { grossIncome - taxReserve - settings.efkaMonthly }
    private var totalOneTimeExpenses: Double { monthExpenses.reduce(0) { $0 + $1.amount } }
    private var totalRecurringExpenses: Double { activeRecurring.reduce(0) { $0 + $1.amount } }
    private var totalExpenses: Double { totalOneTimeExpenses + totalRecurringExpenses }
    private var surplus: Double { netIncome - totalExpenses }
    private var netWorth: Double {
        cryptoHoldings.reduce(0) { $0 + $1.valueEUR } - debts.reduce(0) { $0 + $1.currentBalance }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Monthly Report")
                        .font(.largeTitle.bold())
                    Spacer()
                    MonthPicker(selected: $selectedMonth)
                    Button(copiedReport ? "Copied!" : "Export as Text") {
                        copyReportToClipboard()
                    }
                    .buttonStyle(.bordered)
                    .tint(copiedReport ? .green : Color.accentColor)

                    Button(copiedAI ? "Copied!" : "Export for AI ✦") {
                        exportFullReportForAI()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(copiedAI ? .green : .purple)
                }

                // Prior-year tax obligation — close it out into Debts once the new season starts
                if !previousYearIncomes.isEmpty && !previousYearClosed && previousYearObligation > 0 {
                    GroupBox {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(String(previousYear)) Tax Obligation Unclosed")
                                    .font(.headline)
                                Text("Estimated total: \(previousYearObligation.euroFormatted)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Close \(String(previousYear)) & Move to Debts") { confirmCloseYear = true }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                        }
                    }
                    .confirmationDialog(
                        "Move \(previousYearObligation.euroFormatted) of \(String(previousYear)) tax obligation to Debts?",
                        isPresented: $confirmCloseYear,
                        titleVisibility: .visible
                    ) {
                        Button("Close & Move to Debts") { closePreviousYear() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This creates a debt so the old season's tax isn't forgotten as the new season starts.")
                    }
                }

                // Income breakdown
                GroupBox("Income") {
                    VStack(alignment: .leading, spacing: 6) {
                        ReportRow(label: "Gross Income", value: grossIncome, color: .green)
                        ReportRow(label: "Tax Reserve (\(String(format: "%.1f", projectedRatePct))%)", value: -taxReserve, color: .purple)
                        ReportRow(label: "ΕΦΚΑ", value: -settings.efkaMonthly, color: .orange)
                        Divider()
                        ReportRow(label: "Net Income", value: netIncome, color: .blue, bold: true)
                    }
                }

                // Expense breakdown
                GroupBox("Expenses") {
                    VStack(alignment: .leading, spacing: 6) {
                        // Recurring line items
                        if !activeRecurring.isEmpty {
                            ForEach(activeRecurring) { rec in
                                ReportRow(label: "\(rec.name) (Recurring)", value: -rec.amount, color: .orange)
                            }
                        }
                        // One-time by category
                        let byCategory = Dictionary(grouping: monthExpenses, by: \.category)
                            .mapValues { $0.reduce(0) { $0 + $1.amount } }
                            .sorted { $0.value > $1.value }
                        ForEach(byCategory, id: \.key) { cat, total in
                            ReportRow(label: cat.rawValue, value: -total, color: .red)
                        }
                        Divider()
                        ReportRow(label: "Total Expenses", value: -totalExpenses, color: .red, bold: true)
                    }
                }

                // Summary
                GroupBox("Summary") {
                    VStack(alignment: .leading, spacing: 6) {
                        ReportRow(label: "Surplus / (Deficit)", value: surplus, color: surplus >= 0 ? .green : .red, bold: true)
                        ReportRow(label: "Net Worth Snapshot", value: netWorth, color: .teal)
                    }
                }

                // Annual Tax Estimation (always shows current calendar year, not the selected month)
                AnnualTaxEstimationView(allIncomes: incomes, settings: settings)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Export

    /// Copies a plain-text summary of the report to the clipboard.
    /// PDF export is deferred (requires PDFKit setup) — clipboard is the fast fallback.
    private func copyReportToClipboard() {
        let monthLabel = selectedMonth.formatted(.dateTime.month(.wide).year())
        var lines: [String] = [
            "DiFi Monthly Report — \(monthLabel)",
            String(repeating: "=", count: 40),
            "",
            "INCOME",
            "  Gross:         \(grossIncome.euroFormatted)",
            "  Tax Reserve:   -\(taxReserve.euroFormatted)",
            "  ΕΦΚΑ:          -\(settings.efkaMonthly.euroFormatted)",
            "  Net Income:    \(netIncome.euroFormatted)",
            "",
            "EXPENSES",
        ]
        activeRecurring.forEach { lines.append("  \($0.name) (Recurring): \($0.amount.euroFormatted)") }
        let byCategory = Dictionary(grouping: monthExpenses, by: \.category)
            .mapValues { $0.reduce(0) { $0 + $1.amount } }
            .sorted { $0.value > $1.value }
        byCategory.forEach { lines.append("  \($0.key.rawValue): \($0.value.euroFormatted)") }
        lines += [
            "  Total:         \(totalExpenses.euroFormatted)",
            "",
            "SUMMARY",
            "  Surplus:       \(surplus.euroFormatted)",
            "  Net Worth:     \(netWorth.euroFormatted)",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copiedReport = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedReport = false }
    }

    // MARK: - AI Export

    /// Builds a comprehensive, AI-friendly plain-text report covering ALL data in the app:
    /// income history, expenses, recurring expenses, debts, investments, VAT, and tax estimation.
    /// Paste this directly into ChatGPT, Claude, or any AI assistant for financial analysis.
    private func exportFullReportForAI() {
        let now = Date()
        let currentYear = Calendar.current.component(.year, from: now)
        let df = DateFormatter()
        df.dateFormat = "dd MMM yyyy"

        var s = ""

        // ── Header ────────────────────────────────────────────────────────────
        s += "# DiFi Personal Finance Report\n"
        s += "Generated: \(df.string(from: now))\n"
        s += "Profile: Greek freelancer (self-employed)\n"
        s += "Tax reserve rate (live projection): \(String(format: "%.1f", projectedRatePct))% | Monthly ΕΦΚΑ: \(settings.efkaMonthly.euroFormatted)\n\n"

        // ── Income history (all years) ────────────────────────────────────────
        s += "## Income Entries (all time)\n"
        if incomes.isEmpty {
            s += "  No income recorded.\n"
        } else {
            s += "Date | Source | Type | Net Amount | VAT Rate | VAT Amount\n"
            s += String(repeating: "-", count: 70) + "\n"
            for e in incomes.reversed() {
                let vat = e.vatRate.map { "\(Int($0))%" } ?? "none"
                s += "\(df.string(from: e.date)) | \(e.source) | \(e.type.rawValue) | \(e.amount.euroFormatted) | \(vat) | \(e.vatAmount.euroFormatted)\n"
            }
        }
        s += "\n"

        // ── Expenses (all years, one-time) ────────────────────────────────────
        s += "## One-Time Expense Entries (all time)\n"
        if expenses.isEmpty {
            s += "  No expenses recorded.\n"
        } else {
            s += "Date | Category | Type | Amount | Notes\n"
            s += String(repeating: "-", count: 70) + "\n"
            for e in expenses.reversed() {
                s += "\(df.string(from: e.date)) | \(e.category.rawValue) | \(e.type.rawValue) | \(e.amount.euroFormatted) | \(e.notes)\n"
            }
        }
        s += "\n"

        // ── Recurring expenses ────────────────────────────────────────────────
        s += "## Recurring Monthly Expenses (active templates)\n"
        let active = recurringExpenses.filter { $0.isActive }
        if active.isEmpty {
            s += "  None.\n"
        } else {
            let recurringTotal = active.reduce(0) { $0 + $1.amount }
            for r in active {
                s += "  • \(r.name) — \(r.amount.euroFormatted)/month [\(r.category.rawValue)]\n"
            }
            s += "  Total recurring: \(recurringTotal.euroFormatted)/month\n"
        }
        s += "\n"

        // ── Monthly snapshot for selected month ───────────────────────────────
        let monthLabel = selectedMonth.formatted(.dateTime.month(.wide).year())
        s += "## Monthly Snapshot — \(monthLabel)\n"
        s += "  Gross income:         \(grossIncome.euroFormatted)\n"
        s += "  VAT collected:        \(monthIncomes.reduce(0) { $0 + $1.vatAmount }.euroFormatted)\n"
        s += "  Tax reserve (\(String(format: "%.1f", projectedRatePct))%):  \(taxReserve.euroFormatted)\n"
        s += "  ΕΦΚΑ:                 \(settings.efkaMonthly.euroFormatted)\n"
        s += "  Net income:           \(netIncome.euroFormatted)\n"
        s += "  One-time expenses:    \(totalOneTimeExpenses.euroFormatted)\n"
        s += "  Recurring expenses:   \(totalRecurringExpenses.euroFormatted)\n"
        s += "  Total expenses:       \(totalExpenses.euroFormatted)\n"
        s += "  Surplus / (Deficit):  \(surplus.euroFormatted)\n\n"

        // ── Debts ─────────────────────────────────────────────────────────────
        s += "## Debts\n"
        if debts.isEmpty {
            s += "  No debts recorded.\n"
        } else {
            let totalDebt = debts.reduce(0) { $0 + $1.currentBalance }
            s += "Name | Total | Remaining | Monthly Payment | Interest Rate | Months Left\n"
            s += String(repeating: "-", count: 80) + "\n"
            for d in debts {
                let rate = d.interestRate > 0 ? "\(String(format: "%.1f", d.interestRate))%" : "0%"
                let months = d.monthsToPayoff > 0 ? "\(d.monthsToPayoff)" : "paid off"
                s += "\(d.name) | \(d.totalAmount.euroFormatted) | \(d.currentBalance.euroFormatted) | \(d.monthlyPayment.euroFormatted) | \(rate) | \(months)\n"
            }
            s += "Total remaining debt: \(totalDebt.euroFormatted)\n"
        }
        s += "\n"

        // ── Crypto (synced from Kraken) ──────────────────────────────────────
        s += "## Crypto Holdings\n"
        if cryptoHoldings.isEmpty {
            s += "  No synced Kraken balances.\n"
        } else {
            let totalValue = cryptoHoldings.reduce(0) { $0 + $1.valueEUR }
            s += "Asset | Amount | Price | Value\n"
            s += String(repeating: "-", count: 80) + "\n"
            for h in cryptoHoldings {
                s += "\(h.displayName) | \(String(format: "%.6f", h.amount)) | \(h.priceEUR.euroFormatted) | \(h.valueEUR.euroFormatted)\n"
            }
            s += "Portfolio total: \(totalValue.euroFormatted)\n"
        }
        s += "\n"

        // ── VAT history ───────────────────────────────────────────────────────
        s += "## VAT / ΦΠΑ Payment History\n"
        if vatPayments.isEmpty {
            s += "  No VAT payment records.\n"
        } else {
            for v in vatPayments.reversed() {
                let status = v.isPaid ? "PAID \(v.paidDate.map { df.string(from: $0) } ?? "")" : "PENDING"
                s += "  \(v.month.formatted(.dateTime.month(.wide).year())) — Due: \(v.amountDue.euroFormatted) | Paid: \(v.amountPaid.euroFormatted) | \(status)\n"
            }
        }
        s += "\n"

        // ── Annual tax estimation ─────────────────────────────────────────────
        let projectionAI = projectedYearEndGross(incomes: incomes, year: currentYear)
        let annualGrossAI = projectionAI.annual
        let annualEfkaAI = settings.efkaMonthly * 12
        let taxableAI = max(0, annualGrossAI - annualEfkaAI)
        let taxResultAI = calculateGreekIncomeTax(taxableIncome: taxableAI)
        let prokatavoliAI = taxResultAI.tax * 0.55

        s += "## Annual Tax Estimation — \(currentYear) (projected to year end)\n"
        s += "  Gross income so far (YTD):  \(projectionAI.ytd.euroFormatted)\n"
        s += "  Projected until Dec 31:     \(projectionAI.remaining.euroFormatted)\n"
        s += "  Projected annual gross:     \(annualGrossAI.euroFormatted)\n"
        s += "  Deductible ΕΦΚΑ (×12):      \(annualEfkaAI.euroFormatted)\n"
        s += "  Taxable income:             \(taxableAI.euroFormatted)\n"
        s += "  Bracket breakdown:\n"
        for b in taxResultAI.breakdown {
            s += "    \(b.bracket) @ \(Int(b.rate))% = \(b.tax.euroFormatted)\n"
        }
        s += "  Estimated income tax:       \(taxResultAI.tax.euroFormatted)\n"
        s += "  Προκαταβολή (55%):          \(prokatavoliAI.euroFormatted)\n"
        let totalObligationAI = taxResultAI.tax + prokatavoliAI
        let effectiveRateAI = annualGrossAI > 0 ? totalObligationAI / annualGrossAI : 0
        let earnedShareAI = annualGrossAI > 0 ? projectionAI.ytd / annualGrossAI : 0
        let accruedTaxAI = taxResultAI.tax * earnedShareAI
        let accruedProkatavoliAI = prokatavoliAI * earnedShareAI
        let accruedAI = accruedTaxAI + accruedProkatavoliAI
        s += "  Total tax obligation (year): \(totalObligationAI.euroFormatted)\n"
        s += "  So far (\(Int((effectiveRateAI * 100).rounded()))% of income to date):\n"
        s += "    Income tax so far:        \(accruedTaxAI.euroFormatted)\n"
        s += "    Προκαταβολή (55%) so far: \(accruedProkatavoliAI.euroFormatted)\n"
        s += "    Tax obligation so far:    \(accruedAI.euroFormatted)\n"
        s += "  Still to accrue until Dec 31: \(max(0, totalObligationAI - accruedAI).euroFormatted)\n\n"

        // ── Net worth ─────────────────────────────────────────────────────────
        s += "## Net Worth Snapshot\n"
        s += "  Portfolio value:  \(cryptoHoldings.reduce(0) { $0 + $1.valueEUR }.euroFormatted)\n"
        s += "  Total debt:       \(debts.reduce(0) { $0 + $1.currentBalance }.euroFormatted)\n"
        s += "  Net worth:        \(netWorth.euroFormatted)\n\n"

        s += "---\nEnd of report. Feel free to ask any questions about this data.\n"

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copiedAI = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedAI = false }
    }
}

struct ReportRow: View {
    let label: String
    let value: Double
    let color: Color
    var bold: Bool = false

    var body: some View {
        HStack {
            Text(label).font(bold ? .body.bold() : .body)
            Spacer()
            Text((value >= 0 ? "" : "-") + abs(value).euroFormatted)
                .font(bold ? .body.bold() : .body)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Annual Tax Estimation

/// Shows a Greek income-tax estimate for the CURRENT calendar year.
/// Receives all income entries and settings so it can be embedded in ReportsView
/// without duplicating @Query declarations.
struct AnnualTaxEstimationView: View {
    let allIncomes: [IncomeEntry]
    let settings: AppSettings

    private var currentYear: Int { Calendar.current.component(.year, from: .now) }

    // Year-to-date gross plus a run-rate projection to 31 December — see Extensions.swift
    private var projection: (ytd: Double, remaining: Double, annual: Double) {
        projectedYearEndGross(incomes: allIncomes, year: currentYear)
    }
    private var annualGross: Double { projection.annual }

    // ΕΦΚΑ is deductible from taxable income (annual = monthly × 12)
    private var annualEfka: Double { settings.efkaMonthly * 12 }

    private var taxableIncome: Double { max(0, annualGross - annualEfka) }

    private var taxResult: (tax: Double, breakdown: [(bracket: String, rate: Double, tax: Double)]) {
        calculateGreekIncomeTax(taxableIncome: taxableIncome)
    }

    // Προκαταβολή φόρου: 55% of calculated income tax, paid alongside the annual declaration
    private var prokatavoli: Double { taxResult.tax * 0.55 }
    private var totalObligation: Double { taxResult.tax + prokatavoli }

    // Effective blended rate of the projected year, applied to income earned so far:
    // the slice of the year's total bill attributable to what you've actually invoiced to date.
    private var effectiveRate: Double { annualGross > 0 ? totalObligation / annualGross : 0 }
    // Share of the projected year already earned — used to split each figure into "so far" vs remaining
    private var earnedShare: Double { annualGross > 0 ? projection.ytd / annualGross : 0 }
    private var accruedTax: Double { taxResult.tax * earnedShare }
    private var accruedProkatavoli: Double { prokatavoli * earnedShare }
    private var accruedObligation: Double { accruedTax + accruedProkatavoli }
    private var remainingObligation: Double { max(0, totalObligation - accruedObligation) }

    var body: some View {
        GroupBox("Annual Tax Estimation — \(currentYear) (projected to year end)") {
            VStack(alignment: .leading, spacing: 8) {
                // YTD income summary
                Group {
                    ReportRow(label: "Income so far (YTD)", value: projection.ytd, color: .green)
                    ReportRow(label: "Projected until Dec 31", value: projection.remaining, color: .green)
                    ReportRow(label: "Projected Annual Income", value: annualGross, color: .green, bold: true)
                    ReportRow(label: "Deductible ΕΦΚΑ (×12)", value: -annualEfka, color: .orange)
                    ReportRow(label: "Taxable Income", value: taxableIncome, color: .primary, bold: true)
                }

                Divider()

                // Progressive bracket breakdown — only show applicable brackets
                Text("Tax Bracket Breakdown:")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

                if taxResult.breakdown.isEmpty {
                    Text("No taxable income yet")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(taxResult.breakdown, id: \.bracket) { item in
                        HStack {
                            Text("\(item.bracket) @ \(Int(item.rate))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("= \(item.tax.euroFormatted)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                // Full-year totals
                Text("Full year (projected):")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                ReportRow(label: "Estimated Income Tax", value: taxResult.tax, color: .red)
                ReportRow(label: "Προκαταβολή (55%)", value: prokatavoli, color: .orange)
                HStack {
                    Text("Total Tax Obligation (year)")
                        .font(.body.bold())
                    Spacer()
                    Text(totalObligation.euroFormatted)
                        .font(.body.bold())
                        .foregroundStyle(totalObligation > 0 ? .red : .primary)
                }

                Divider()

                // Accrued so far — each figure scaled by the share of the year's income already earned,
                // i.e. what you should already have set aside at the blended rate
                Text("So far (\(Int((effectiveRate * 100).rounded()))% of income to date):")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                ReportRow(label: "Income Tax so far", value: accruedTax, color: .red)
                ReportRow(label: "Προκαταβολή (55%) so far", value: accruedProkatavoli, color: .orange)
                HStack {
                    Text("Tax Obligation so far")
                        .font(.body.bold())
                    Spacer()
                    Text(accruedObligation.euroFormatted)
                        .font(.body.bold())
                        .foregroundStyle(accruedObligation > 0 ? .red : .primary)
                }
                ReportRow(label: "Still to accrue until Dec 31", value: remainingObligation, color: .secondary)

                // Disclaimer
                Text("Προβολή έως 31/12 βάσει του ρυθμού εσόδων από την πρώτη εγγραφή του έτους. Συμβουλευτείτε λογιστή για την τελική δήλωση.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - Greek Income Tax Calculator

/// Calculates progressive Greek income tax for φυσικά πρόσωπα / freelancers.
/// Returns the total tax and a per-bracket breakdown for display.
func calculateGreekIncomeTax(taxableIncome: Double) -> (tax: Double, breakdown: [(bracket: String, rate: Double, tax: Double)]) {
    // Greek income-tax brackets for freelancers (φυσικά πρόσωπα / επιχειρηματική δραστηριότητα)
    let brackets: [(limit: Double, rate: Double, label: String)] = [
        (10_000,    0.09, "0 – 10.000€"),
        (20_000,    0.20, "10.000,01 – 20.000€"),
        (30_000,    0.26, "20.000,01 – 30.000€"),
        (40_000,    0.34, "30.000,01 – 40.000€"),
        (60_000,    0.39, "40.000,01 – 60.000€"),
        (.infinity, 0.44, "60.000€+"),
    ]

    var remaining = taxableIncome
    var totalTax = 0.0
    var breakdown: [(String, Double, Double)] = []
    var previousLimit = 0.0

    for bracket in brackets {
        guard remaining > 0 else { break }
        // How much of the remaining income falls in this bracket
        let bracketSize = bracket.limit == .infinity
            ? remaining
            : min(remaining, bracket.limit - previousLimit)
        let tax = bracketSize * bracket.rate
        if bracketSize > 0 {
            breakdown.append((bracket.label, bracket.rate * 100, tax))
            totalTax += tax
        }
        remaining -= bracketSize
        previousLimit = bracket.limit
    }

    return (totalTax, breakdown)
}
