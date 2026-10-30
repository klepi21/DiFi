import SwiftUI
import SwiftData

struct DebtsView: View {
    @Environment(\.modelContext) private var context
    @Query private var debts: [Debt]
    @State private var showAdd = false
    @State private var editTarget: Debt?
    @State private var payTarget: Debt?

    private var totalDebt: Double { debts.reduce(0) { $0 + $1.currentBalance } }
    private var debtFreeDate: Date? {
        let maxMonths = debts.compactMap { $0.monthsToPayoff == 0 ? nil : $0.monthsToPayoff }.max()
        guard let m = maxMonths else { return nil }
        return Calendar.current.date(byAdding: .month, value: m, to: .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Debts")
                    .font(.largeTitle.bold())
                Spacer()
                Button("Add Debt") { showAdd = true }.buttonStyle(.borderedProminent)
            }
            .padding()

            HStack(spacing: 16) {
                SummaryCard(title: "Total Remaining", value: totalDebt.euroFormatted, color: .red, icon: "creditcard.fill")
                if let date = debtFreeDate {
                    SummaryCard(title: "Debt-Free Date", value: date.formatted(.dateTime.month(.wide).year()), color: .green, icon: "flag.fill")
                }
            }
            .padding(.horizontal)

            if debts.isEmpty {
                ContentUnavailableView("No debts", systemImage: "checkmark.seal.fill", description: Text("You're debt-free! Or add a debt to track it."))
                    .padding()
            } else {
                List {
                    ForEach(debts) { debt in
                        DebtRow(
                            debt: debt,
                            onPay: { payTarget = debt },
                            onEdit: { editTarget = debt },
                            onDelete: { context.delete(debt); try? context.save() }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showAdd) { AddDebtSheet() }
        .sheet(item: $editTarget) { debt in EditDebtSheet(debt: debt) }
        .sheet(item: $payTarget) { debt in MakePaymentSheet(debt: debt) }
    }
}

struct DebtRow: View {
    let debt: Debt
    let onPay: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var confirmDelete = false
    var progress: Double { debt.totalAmount > 0 ? 1 - (debt.currentBalance / debt.totalAmount) : 0 }

    private var isPaidOff: Bool { debt.currentBalance <= 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(debt.name).font(.headline)
                if isPaidOff {
                    Text("PAID OFF")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }
                Spacer()
                Text(isPaidOff ? "0,00 €" : debt.currentBalance.euroFormatted)
                    .font(.headline.bold())
                    .foregroundStyle(isPaidOff ? .green : .red)
            }

            ProgressView(value: progress).tint(isPaidOff ? .green : .accentColor)

            if !isPaidOff {
                HStack {
                    Text("Monthly: \(debt.monthlyPayment.euroFormatted)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if debt.monthsToPayoff > 0 {
                        Text("\(debt.monthsToPayoff) months left").font(.caption).foregroundStyle(.secondary)
                    }
                    if debt.totalInterest > 0 {
                        Text("Interest: \(debt.totalInterest.euroFormatted)").font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            if !debt.notes.isEmpty {
                Text(debt.notes).font(.caption2).foregroundStyle(.secondary)
            }

            if isPaidOff {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Fully paid off. You can remove it from the list.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { onEdit() } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    Button { onPay() } label: {
                        Label("Make Payment", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(.green)

                    Button { onEdit() } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered).controlSize(.small)

                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            if isPaidOff {
                Button("Remove (Paid Off)", role: .destructive) { confirmDelete = true }
            } else {
                Button("Make Payment") { onPay() }
                Button("Edit") { onEdit() }
                Divider()
                Button("Delete", role: .destructive) { confirmDelete = true }
            }
        }
        .confirmationDialog(
            isPaidOff ? "Remove \"\(debt.name)\" from your list?" : "Delete debt \"\(debt.name)\"?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button(isPaidOff ? "Remove" : "Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isPaidOff ? "You've paid this off — great job! This will remove it permanently." : "This cannot be undone.")
        }
    }
}

// MARK: - Add Debt

struct AddDebtSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var total = ""
    @State private var balance = ""
    @State private var monthly = ""
    @State private var rate = ""
    @State private var startDate = Date()
    @State private var notes = ""

    var body: some View {
        Form {
            Text("Add Debt").font(.headline)
            TextField("Name (e.g. Car Loan)", text: $name)
            TextField("Total Amount (€)", text: $total)
            TextField("Current Balance (€)", text: $balance)
            TextField("Monthly Payment (€)", text: $monthly)
            TextField("Interest Rate % (optional)", text: $rate)
            DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
            TextField("Notes", text: $notes)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(name.isEmpty || total.isEmpty).keyboardShortcut(.return)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
    }

    private func save() {
        guard let t = Double(total.replacingOccurrences(of: ",", with: ".")),
              let m = Double(monthly.replacingOccurrences(of: ",", with: ".")) else { return }
        let b = Double((balance.isEmpty ? total : balance).replacingOccurrences(of: ",", with: ".")) ?? t
        let r = Double(rate.replacingOccurrences(of: ",", with: ".")) ?? 0
        context.insert(Debt(name: name, totalAmount: t, currentBalance: b, monthlyPayment: m, interestRate: r, startDate: startDate, notes: notes))
        try? context.save()
        dismiss()
    }
}

// MARK: - Edit Debt

struct EditDebtSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let debt: Debt

    @Query private var efkaStatuses: [EfkaMonthStatus]

    @State private var name = ""
    @State private var total = ""
    @State private var balance = ""
    @State private var monthly = ""
    @State private var rate = ""
    @State private var startDate = Date()
    @State private var notes = ""

    var body: some View {
        Form {
            Text("Edit Debt").font(.headline)
            TextField("Name", text: $name)
            TextField("Total Amount (€)", text: $total)
            TextField("Current Balance (€)", text: $balance)
            TextField("Monthly Payment (€)", text: $monthly)
            TextField("Interest Rate %", text: $rate)
            DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
            TextField("Notes", text: $notes)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(name.isEmpty).keyboardShortcut(.return)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
        .onAppear {
            name = debt.name
            total = String(format: "%.2f", debt.totalAmount)
            balance = String(format: "%.2f", debt.currentBalance)
            monthly = String(format: "%.2f", debt.monthlyPayment)
            rate = debt.interestRate > 0 ? String(format: "%.2f", debt.interestRate) : ""
            startDate = debt.startDate
            notes = debt.notes
        }
    }

    private func save() {
        guard let t = Double(total.replacingOccurrences(of: ",", with: ".")),
              let b = Double(balance.replacingOccurrences(of: ",", with: ".")),
              let m = Double(monthly.replacingOccurrences(of: ",", with: ".")) else { return }
        debt.name = name
        debt.totalAmount = t
        debt.currentBalance = b
        debt.monthlyPayment = m
        debt.interestRate = Double(rate.replacingOccurrences(of: ",", with: ".")) ?? 0
        debt.startDate = startDate
        debt.notes = notes

        // If this is an ΕΦΚΑ debt and the balance was restored to > 0,
        // revert the corresponding EfkaMonthStatus back to unpaid.
        if debt.name.hasPrefix("ΕΦΚΑ –") && b > 0 {
            if let status = efkaStatuses.first(where: { $0.isPaid && ($0.addedToDebt ?? false) }) {
                status.isPaid = false
                status.paidDate = nil
            }
        }

        try? context.save()
        dismiss()
    }
}

// MARK: - Make Payment Sheet

struct MakePaymentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let debt: Debt

    @Query private var efkaStatuses: [EfkaMonthStatus]

    @State private var paymentAmount = ""

    private var parsedAmount: Double? {
        Double(paymentAmount.replacingOccurrences(of: ",", with: "."))
    }
    private var newBalance: Double {
        max(0, debt.currentBalance - (parsedAmount ?? 0))
    }
    private var isValid: Bool {
        guard let v = parsedAmount else { return false }
        return v > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Make Payment")
                    .font(.title2.bold())
                Text(debt.name)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Current balance info
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current Balance").font(.caption).foregroundStyle(.secondary)
                    Text(debt.currentBalance.euroFormatted).font(.title3.bold()).foregroundStyle(.red)
                }
                Spacer()
                if parsedAmount != nil && isValid {
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New Balance").font(.caption).foregroundStyle(.secondary)
                        Text(newBalance.euroFormatted)
                            .font(.title3.bold())
                            .foregroundStyle(newBalance == 0 ? .green : .primary)
                    }
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

            // Amount input
            VStack(alignment: .leading, spacing: 8) {
                Text("Payment Amount").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("€").foregroundStyle(.secondary)
                    TextField("0,00", text: $paymentAmount)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                }

                // Quick-fill chips
                HStack(spacing: 8) {
                    Text("Quick fill:").font(.caption).foregroundStyle(.secondary)
                    Button("Monthly (\(debt.monthlyPayment.euroFormatted))") {
                        paymentAmount = String(format: "%.2f", debt.monthlyPayment)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if debt.monthlyPayment * 2 <= debt.currentBalance {
                        Button("2× (\((debt.monthlyPayment * 2).euroFormatted))") {
                            paymentAmount = String(format: "%.2f", debt.monthlyPayment * 2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button("Full (\(debt.currentBalance.euroFormatted))") {
                        paymentAmount = String(format: "%.2f", debt.currentBalance)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.green)
                }
            }

            Divider()

            // Actions
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Apply Payment") { applyPayment() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
                    .keyboardShortcut(.return)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func applyPayment() {
        guard let amount = Double(paymentAmount.replacingOccurrences(of: ",", with: ".")) else { return }

        // Reduce debt balance
        let previousBalance = debt.currentBalance
        debt.currentBalance = max(0, previousBalance - amount)

        // Log as an expense — but NOT for ΕΦΚΑ debts, since ΕΦΚΑ is already
        // accounted for in the Dashboard "Set aside" deduction and logging it
        // again would double-count it.
        if !debt.name.hasPrefix("ΕΦΚΑ –") {
            context.insert(ExpenseEntry(
                date: Date(),
                amount: amount,
                category: .business,
                type: .extra,
                notes: "Debt payment — \(debt.name)"
            ))
        }

        // If this is an ΕΦΚΑ auto-debt and it's now fully paid, sync back to the
        // Income view's ΕΦΚΑ status card so it shows "Paid" there too.
        if debt.name.hasPrefix("ΕΦΚΑ –") && debt.currentBalance == 0 {
            // Extract the month from the debt name "ΕΦΚΑ – June 2026"
            // Match by finding the EfkaMonthStatus whose addedToDebt == true and isn't paid yet
            if let status = efkaStatuses.first(where: { ($0.addedToDebt ?? false) && !$0.isPaid }) {
                status.isPaid = true
                status.paidDate = Date()
            }
        }

        try? context.save()
        dismiss()
    }
}
