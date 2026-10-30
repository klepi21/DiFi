import SwiftUI
import SwiftData

struct TaxVaultView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TaxPayment.date, order: .reverse) private var payments: [TaxPayment]
    @Query private var incomes: [IncomeEntry]
    @Query private var settingsQuery: [AppSettings]

    @State private var showMarkPaid = false
    @State private var editTarget: TaxPayment?

    private var settings: AppSettings { settingsQuery.first ?? AppSettings() }

    // Live projected tax-reserve rate — see Extensions.swift for the run-rate projection logic
    private var projectedRatePct: Double {
        projectedTaxReservePct(incomes: incomes, efkaMonthly: settings.efkaMonthly)
    }

    private var totalAccumulated: Double {
        incomes.reduce(0) { $0 + $1.amount * projectedRatePct / 100 }
    }
    private var totalPaid: Double { payments.reduce(0) { $0 + $1.amount } }
    private var remaining: Double { totalAccumulated - totalPaid }

    private var thisMonthContribution: Double {
        let start = Calendar.current.startOfMonth(for: .now)
        return incomes
            .filter { Calendar.current.isDate($0.date, equalTo: start, toGranularity: .month) }
            .reduce(0) { $0 + $1.amount * projectedRatePct / 100 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tax Vault")
                    .font(.largeTitle.bold())
                Text("Προκαταβολή Φόρου")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Mark as Paid to ΔΟΥ") { showMarkPaid = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
            }
            .padding()

            HStack(spacing: 16) {
                SummaryCard(title: "Total Reserved", value: totalAccumulated.euroFormatted, color: .purple, icon: "building.columns.fill")
                SummaryCard(title: "Total Paid to ΔΟΥ", value: totalPaid.euroFormatted, color: .green, icon: "checkmark.seal.fill")
                SummaryCard(title: "Currently Held", value: remaining.euroFormatted, color: .orange, icon: "banknote.fill")
                SummaryCard(title: "This Month", value: thisMonthContribution.euroFormatted, subtitle: "Contribution", color: .blue, icon: "calendar")
            }
            .padding(.horizontal)

            Divider().padding(.vertical, 12)

            HStack {
                Text("Payment History")
                    .font(.headline)
                Spacer()
                Text("\(payments.count) payment\(payments.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            if payments.isEmpty {
                ContentUnavailableView(
                    "No payments yet",
                    systemImage: "building.columns",
                    description: Text("Use 'Mark as Paid' when you pay the εφορία.")
                )
                .padding()
            } else {
                List {
                    ForEach(payments) { payment in
                        TaxPaymentRow(
                            payment: payment,
                            onEdit: { editTarget = payment },
                            onDelete: {
                                context.delete(payment)
                                try? context.save()
                            }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showMarkPaid) { MarkTaxPaidSheet() }
        .sheet(item: $editTarget) { payment in EditTaxPaymentSheet(payment: payment) }
    }
}

// MARK: - Payment Row

struct TaxPaymentRow: View {
    let payment: TaxPayment
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var confirmDelete = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(payment.date.formatted(.dateTime.day().month(.wide).year()))
                    .font(.headline)
                if !payment.notes.isEmpty {
                    Text(payment.notes).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(payment.amount.euroFormatted)
                .font(.headline.bold())
                .foregroundStyle(.green)

            HStack(spacing: 6) {
                Button { onEdit() } label: { Image(systemName: "pencil") }
                    .buttonStyle(.bordered).controlSize(.small)
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Edit") { onEdit() }
            Divider()
            Button("Delete", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete this tax payment of \(payment.amount.euroFormatted)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }
}

// MARK: - Mark Tax Paid Sheet

struct MarkTaxPaidSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var incomes: [IncomeEntry]
    @Query private var payments: [TaxPayment]
    @Query private var settingsQuery: [AppSettings]

    @State private var amount = ""
    @State private var date = Date()
    @State private var notes = ""

    private var settings: AppSettings { settingsQuery.first ?? AppSettings() }
    private var suggestedAmount: Double {
        let rate = projectedTaxReservePct(incomes: incomes, efkaMonthly: settings.efkaMonthly)
        let acc = incomes.reduce(0) { $0 + $1.amount * rate / 100 }
        let paid = payments.reduce(0) { $0 + $1.amount }
        return max(0, acc - paid)
    }

    var body: some View {
        Form {
            Text("Record Tax Payment").font(.headline)
            Text("Suggested amount based on accumulated reserve:")
                .font(.caption).foregroundStyle(.secondary)
            Button("Use suggested: \(suggestedAmount.euroFormatted)") {
                amount = String(format: "%.2f", suggestedAmount)
            }
            .buttonStyle(.bordered)
            TextField("Amount Paid (€)", text: $amount)
            DatePicker("Payment Date", selection: $date, displayedComponents: .date)
            TextField("Notes (e.g. reference number)", text: $notes)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Record") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(amount.isEmpty)
                    .keyboardShortcut(.return)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 380)
        .onAppear { amount = String(format: "%.2f", suggestedAmount) }
    }

    private func save() {
        guard let v = Double(amount.replacingOccurrences(of: ",", with: ".")) else { return }
        context.insert(TaxPayment(date: date, amount: v, notes: notes))
        try? context.save()
        dismiss()
    }
}

// MARK: - Edit Tax Payment Sheet

struct EditTaxPaymentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let payment: TaxPayment

    @State private var amount = ""
    @State private var date = Date()
    @State private var notes = ""

    var body: some View {
        Form {
            Text("Edit Tax Payment").font(.headline)
            TextField("Amount (€)", text: $amount)
            DatePicker("Payment Date", selection: $date, displayedComponents: .date)
            TextField("Notes", text: $notes)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(amount.isEmpty)
                    .keyboardShortcut(.return)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 360)
        .onAppear {
            amount = String(format: "%.2f", payment.amount)
            date = payment.date
            notes = payment.notes
        }
    }

    private func save() {
        guard let v = Double(amount.replacingOccurrences(of: ",", with: ".")) else { return }
        payment.amount = v
        payment.date = date
        payment.notes = notes
        try? context.save()
        dismiss()
    }
}
