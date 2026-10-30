import SwiftUI
import SwiftData
import Charts

/// A single-purpose page: a pie chart showing how a payment splits across tax obligations,
/// ΕΦΚΑ, expenses, debt payments, investing, and whatever's left over to spend freely.
/// Defaults to this month's combined income; tap an individual income entry in the list
/// to see the allocation for just that payment instead.
struct AllocationView: View {
    @Environment(\.modelContext) private var context
    @Query private var incomes: [IncomeEntry]
    @Query private var expenses: [ExpenseEntry]
    @Query private var recurringExpenses: [RecurringExpense]
    @Query private var debts: [Debt]
    @Query private var settingsQuery: [AppSettings]

    @State private var investmentInput: String = ""
    @State private var selectedIncomeID: UUID?
    @State private var selectedMonth: Date = Calendar.current.startOfMonth(for: .now)

    private var settings: AppSettings {
        if let s = settingsQuery.first { return s }
        let s = AppSettings()
        context.insert(s)
        try? context.save()
        return s
    }

    private var calendar: Calendar { .current }

    private var monthIncomes: [IncomeEntry] {
        incomes
            .filter { calendar.isDate($0.date, equalTo: selectedMonth, toGranularity: .month) }
            .sorted { $0.date > $1.date }
    }

    private var monthIncome: Double { monthIncomes.reduce(0) { $0 + $1.amount } }

    // nil selection (or "This Month" chosen) falls back to the whole month's combined income.
    private var selectedIncome: IncomeEntry? {
        guard let selectedIncomeID else { return nil }
        return monthIncomes.first { $0.id == selectedIncomeID }
    }

    // The single payment amount the whole breakdown is calculated against.
    private var basisAmount: Double { selectedIncome?.amount ?? monthIncome }

    // What share of this payment is this payment's share of the month (used to prorate
    // fixed monthly obligations like ΕΦΚΑ and the investment target across individual entries).
    private var monthShare: Double { monthIncome > 0 ? basisAmount / monthIncome : 0 }

    private var projectedRatePct: Double {
        projectedTaxReservePct(incomes: incomes, efkaMonthly: settings.efkaMonthly)
    }

    // Tax reserve + 55% προκαταβολή — always calculated exactly against the basis amount,
    // never tiered down, since this obligation applies to every euro of income regardless of size.
    private var taxAndPrepayment: Double { basisAmount * projectedRatePct / 100 }

    private var efka: Double { settings.efkaMonthly * monthShare }

    private var monthExpenses: Double {
        let oneTime = expenses
            .filter { calendar.isDate($0.date, equalTo: selectedMonth, toGranularity: .month) }
            .reduce(0) { $0 + $1.amount }
        let recurring = recurringExpenses.filter { $0.isActive }.reduce(0) { $0 + $1.amount }
        return oneTime + recurring
    }

    private var monthDebt: Double { debts.reduce(0) { $0 + $1.monthlyPayment } }

    // Investment amount is set per payment, not prorated: a specific income shows its own
    // figure, "This Month (combined)" shows the sum across all of this month's payments.
    private var investments: Double {
        if let selectedIncome { return selectedIncome.investmentAmount ?? 0 }
        return monthIncomes.reduce(0) { $0 + ($1.investmentAmount ?? 0) }
    }

    // How much of expenses/debt this payment should shoulder, tiered by its own size:
    // under €1,000 → none, €1,000–€2,199 → half, €2,200+ → all of them.
    private var tierPct: Double {
        if basisAmount >= 2200 { return 1.0 }
        if basisAmount >= 1000 { return 0.5 }
        return 0
    }

    private var expensesShare: Double { monthExpenses * tierPct }
    private var debtShare: Double { monthDebt * tierPct }

    private var allocated: Double { taxAndPrepayment + efka + expensesShare + debtShare + investments }
    private var freeRoam: Double { max(0, basisAmount - allocated) }

    private var slices: [(label: String, value: Double, color: Color)] {
        [
            ("Tax + 55% Prepayment", taxAndPrepayment, .purple),
            ("ΕΦΚΑ", efka, .orange),
            ("Expenses", expensesShare, .red),
            ("Debt", debtShare, .brown),
            ("Investments", investments, .teal),
            ("Free Roam Money", freeRoam, .green)
        ].filter { $0.value > 0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Allocation")
                        .font(.largeTitle.bold())
                    Spacer()
                    MonthPicker(selected: $selectedMonth)
                }

                if monthIncome <= 0 {
                    ContentUnavailableView(
                        "No income logged this month",
                        systemImage: "chart.pie",
                        description: Text("Add income for this month to see how it's allocated.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    HStack(alignment: .top, spacing: 24) {
                        // Income picker — "This Month" (combined) plus every individual entry.
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Income").font(.headline).padding(.bottom, 4)

                            AllocationIncomeRow(
                                title: "This Month (combined)",
                                subtitle: "\(monthIncomes.count) payment\(monthIncomes.count == 1 ? "" : "s")",
                                amount: monthIncome,
                                isSelected: selectedIncomeID == nil
                            ) { selectedIncomeID = nil }

                            Divider().padding(.vertical, 4)

                            ForEach(monthIncomes) { income in
                                AllocationIncomeRow(
                                    title: income.source,
                                    subtitle: income.date.formatted(date: .abbreviated, time: .omitted),
                                    amount: income.amount,
                                    isSelected: selectedIncomeID == income.id
                                ) { selectedIncomeID = income.id }
                            }
                        }
                        .frame(width: 240, alignment: .leading)

                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top, spacing: 32) {
                                Chart(slices, id: \.label) { slice in
                                    SectorMark(angle: .value("Amount", slice.value), innerRadius: .ratio(0.55))
                                        .foregroundStyle(slice.color)
                                }
                                .frame(width: 220, height: 220)

                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(slices, id: \.label) { slice in
                                        HStack {
                                            Circle().fill(slice.color).frame(width: 10, height: 10)
                                            Text(slice.label).font(.subheadline)
                                            Spacer()
                                            Text(slice.value.euroFormatted)
                                                .font(.subheadline.bold())
                                            Text(basisAmount > 0 ? "\(String(format: "%.1f", slice.value / basisAmount * 100))%" : "—")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .frame(width: 48, alignment: .trailing)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

                            VStack(alignment: .leading, spacing: 4) {
                                if let selectedIncome {
                                    HStack {
                                        Text("Investment for \"\(selectedIncome.source)\" (€)")
                                        Spacer()
                                        TextField("0", text: $investmentInput)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 120)
                                            .onSubmit { saveInvestment() }
                                            .onChange(of: investmentInput) { _, _ in saveInvestment() }
                                    }
                                } else {
                                    HStack {
                                        Text("Investments This Month (€)")
                                        Spacer()
                                        Text(investments.euroFormatted).font(.headline)
                                    }
                                    Text("Select a payment on the left to set its investment amount.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24)
        }
        .onAppear { loadInvestmentInput() }
        .onChange(of: selectedIncomeID) { _, _ in loadInvestmentInput() }
        .onChange(of: selectedMonth) { _, _ in
            selectedIncomeID = nil
            loadInvestmentInput()
        }
    }

    private func loadInvestmentInput() {
        let v = selectedIncome?.investmentAmount ?? 0
        investmentInput = v == 0 ? "" : String(format: "%.2f", v)
    }

    private func saveInvestment() {
        guard let selectedIncome else { return }
        let v = Double(investmentInput.replacingOccurrences(of: ",", with: ".")) ?? 0
        selectedIncome.investmentAmount = v
        try? context.save()
    }
}

private struct AllocationIncomeRow: View {
    let title: String
    let subtitle: String
    let amount: Double
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold()).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                Text(amount.euroFormatted).font(.caption.bold()).foregroundStyle(isSelected ? .white : .accentColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
