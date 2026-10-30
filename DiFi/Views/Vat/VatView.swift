import SwiftUI
import SwiftData

// MARK: - VatView
// Main view for the VAT / ΦΠΑ tracker. Two tabs:
//   • This Month — collected VAT for the selected month, payment status, income entries with VAT
//   • History    — all VatPayment records sorted newest first

struct VatView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \IncomeEntry.date, order: .reverse) private var incomes: [IncomeEntry]
    @Query(sort: \VatPayment.month, order: .reverse) private var vatPayments: [VatPayment]

    @State private var tab: VatTab = .thisMonth
    @State private var selectedMonth: Date = Calendar.current.startOfMonth(for: .now)
    @State private var showMarkPaidSheet = false
    @State private var editTarget: VatPayment?

    enum VatTab: String, CaseIterable {
        case thisMonth = "This Month"
        case history = "History"
    }

    // Income entries for the selected month that have a VAT rate set
    private var vatIncomes: [IncomeEntry] {
        incomes.filter {
            $0.vatRate != nil &&
            Calendar.current.isDate($0.date, equalTo: selectedMonth, toGranularity: .month)
        }
    }

    // Total VAT collected this month across all qualifying income entries
    private var vatCollected: Double { vatIncomes.reduce(0) { $0 + $1.vatAmount } }

    // VatPayment record for the selected month (nil if not yet created)
    private var currentPayment: VatPayment? {
        vatPayments.first { Calendar.current.isDate($0.month, equalTo: selectedMonth, toGranularity: .month) }
    }

    private var vatPaid: Double { currentPayment?.amountPaid ?? 0 }
    private var vatRemaining: Double { max(0, vatCollected - vatPaid) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("VAT / ΦΠΑ")
                    .font(.largeTitle.bold())
                Spacer()
                if tab == .thisMonth {
                    MonthPicker(selected: $selectedMonth)
                }
            }
            .padding()

            // Tab picker
            Picker("View", selection: $tab) {
                ForEach(VatTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            switch tab {
            case .thisMonth: thisMonthView
            case .history: historyView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Sheet: mark current month as paid
        .sheet(isPresented: $showMarkPaidSheet) {
            MarkVatPaidSheet(
                month: selectedMonth,
                collected: vatCollected,
                existingPayment: currentPayment
            )
        }
        // Sheet: edit an existing VatPayment from history
        .sheet(item: $editTarget) { payment in
            EditVatPaymentSheet(payment: payment)
        }
    }

    // MARK: - This Month Tab

    @ViewBuilder
    private var thisMonthView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Summary cards
                HStack(spacing: 12) {
                    SummaryCard(title: "ΦΠΑ Collected", value: vatCollected.euroFormatted, color: .blue, icon: "percent")
                    SummaryCard(title: "Paid to ΔΟΥ", value: vatPaid.euroFormatted, color: .green, icon: "checkmark.circle.fill")
                    SummaryCard(title: "Remaining", value: vatRemaining.euroFormatted, color: vatRemaining > 0 ? .orange : .green, icon: "clock.fill")
                }
                .padding(.horizontal)

                // Status card (mirrors EfkaStatusCard pattern)
                VatStatusCard(
                    month: selectedMonth,
                    collected: vatCollected,
                    payment: currentPayment,
                    onMarkPaid: { showMarkPaidSheet = true }
                )
                .padding(.horizontal)

                // Income entries with VAT for this month
                if vatIncomes.isEmpty {
                    ContentUnavailableView(
                        "No VAT income this month",
                        systemImage: "percent",
                        description: Text("Add income entries with a ΦΠΑ rate to track VAT.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Income with VAT")
                            .font(.headline)
                            .padding(.horizontal)
                            .padding(.bottom, 4)
                        Divider()
                        ForEach(vatIncomes) { entry in
                            VatIncomeRow(entry: entry)
                            Divider()
                        }
                    }
                }
            }
            .padding(.vertical, 16)
        }
    }

    // MARK: - History Tab

    @ViewBuilder
    private var historyView: some View {
        if vatPayments.isEmpty {
            VStack {
                Spacer()
                ContentUnavailableView(
                    "No VAT payments recorded",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Mark a month as paid to create a history record.")
                )
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(vatPayments) { payment in
                    VatPaymentRow(
                        payment: payment,
                        onEdit: { editTarget = payment },
                        onDelete: { context.delete(payment); try? context.save() }
                    )
                }
            }
        }
    }
}

// MARK: - VatStatusCard
// Shows collection status for the month and offers a "Mark as Paid" action.

struct VatStatusCard: View {
    let month: Date
    let collected: Double
    let payment: VatPayment?
    let onMarkPaid: () -> Void

    private var isPaid: Bool { payment?.isPaid == true }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isPaid ? "checkmark.seal.fill" : collected > 0 ? "exclamationmark.circle.fill" : "percent")
                .font(.title2)
                .foregroundStyle(isPaid ? .green : collected > 0 ? .orange : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("ΦΠΑ — \(month.formatted(.dateTime.month(.wide).year()))")
                    .font(.headline)
                if isPaid, let pd = payment?.paidDate {
                    Text("Paid on \(pd.formatted(.dateTime.day().month().year()))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let n = payment?.notes, !n.isEmpty {
                        Text(n).font(.caption).foregroundStyle(.secondary)
                    }
                } else if collected == 0 {
                    Text("No VAT collected this month")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not yet remitted to ΔΟΥ")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Spacer()

            Text(collected.euroFormatted).font(.headline)

            if isPaid {
                Text("Paid")
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
            } else if collected > 0 {
                Button("Mark as Paid") { onMarkPaid() }
                    .buttonStyle(.borderedProminent).tint(.blue).controlSize(.small)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isPaid ? Color.green.opacity(0.4) : Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - VatIncomeRow
// Compact row showing an income entry's VAT details.

struct VatIncomeRow: View {
    let entry: IncomeEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.source).font(.headline)
                Text(entry.date.formatted(.dateTime.day().month().year()))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.amount.euroFormatted).font(.subheadline)
                if let rate = entry.vatRate {
                    Text("ΦΠΑ \(Int(rate))%: \(entry.vatAmount.euroFormatted)")
                        .font(.caption.bold()).foregroundStyle(.blue)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - VatPaymentRow
// Row in the history list.

struct VatPaymentRow: View {
    let payment: VatPayment
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var confirmDelete = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(payment.month.formatted(.dateTime.month(.wide).year())).font(.headline)
                if payment.isPaid, let pd = payment.paidDate {
                    Text("Paid \(pd.formatted(.dateTime.day().month().year()))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !payment.notes.isEmpty {
                    Text(payment.notes).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Due: \(payment.amountDue.euroFormatted)").font(.subheadline)
                if payment.amountPaid > 0 {
                    Text("Paid: \(payment.amountPaid.euroFormatted)")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            // Status badge
            Text(payment.isPaid ? "Paid" : "Pending")
                .font(.caption.bold())
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(payment.isPaid ? Color.green.opacity(0.15) : Color.orange.opacity(0.15), in: Capsule())
                .foregroundStyle(payment.isPaid ? .green : .orange)

            HStack(spacing: 6) {
                Button { onEdit() } label: { Image(systemName: "pencil") }
                    .buttonStyle(.bordered).controlSize(.small)
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("Delete VAT record for \(payment.month.formatted(.dateTime.month(.wide).year()))?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }
}

// MARK: - MarkVatPaidSheet
// Sheet opened when the user taps "Mark as Paid".
// Pre-fills the amount with the collected total; lets user adjust before saving.

struct MarkVatPaidSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let month: Date
    let collected: Double
    let existingPayment: VatPayment?  // non-nil if a record already exists (update rather than insert)

    @State private var amountPaid = ""
    @State private var paidDate = Date()
    @State private var notes = ""
    @State private var showConfirm = false

    var body: some View {
        Form {
            Text("Mark VAT as Paid")
                .font(.headline)
            Text("Month: \(month.formatted(.dateTime.month(.wide).year()))")
                .foregroundStyle(.secondary)
            Text("Collected: \(collected.euroFormatted)")
                .foregroundStyle(.secondary)
            TextField("Amount Paid (€)", text: $amountPaid)
            DatePicker("Payment Date", selection: $paidDate, displayedComponents: .date)
            TextField("Notes (optional)", text: $notes)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Confirm") { showConfirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(amountPaid.isEmpty)
                    .keyboardShortcut(.return)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 380)
        .onAppear {
            amountPaid = String(format: "%.2f", collected)
            if let p = existingPayment {
                if p.amountPaid > 0 { amountPaid = String(format: "%.2f", p.amountPaid) }
                if let pd = p.paidDate { paidDate = pd }
                notes = p.notes
            }
        }
        .confirmationDialog(
            "Mark \(amountPaid)€ as paid to ΔΟΥ for \(month.formatted(.dateTime.month(.wide).year()))?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Confirm Payment") { save() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func save() {
        guard let value = Double(amountPaid.replacingOccurrences(of: ",", with: ".")) else { return }
        if let payment = existingPayment {
            payment.amountPaid = value
            payment.isPaid = true
            payment.paidDate = paidDate
            payment.notes = notes
        } else {
            let payment = VatPayment(month: month, amountDue: collected)
            payment.amountPaid = value
            payment.isPaid = true
            payment.paidDate = paidDate
            payment.notes = notes
            context.insert(payment)
        }
        // Log as an expense on the payment date so it shows in monthly totals
        context.insert(ExpenseEntry(
            date: paidDate,
            amount: value,
            category: .business,
            type: .extra,
            notes: "ΦΠΑ payment — \(month.formatted(.dateTime.month(.wide).year()))"
        ))
        try? context.save()
        dismiss()
    }
}

// MARK: - EditVatPaymentSheet
// Sheet for editing an existing VatPayment from the history list.

struct EditVatPaymentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let payment: VatPayment

    @State private var amountDue = ""
    @State private var amountPaid = ""
    @State private var isPaid = false
    @State private var paidDate = Date()
    @State private var notes = ""

    var body: some View {
        Form {
            Text("Edit VAT Payment").font(.headline)
            Text("Month: \(payment.month.formatted(.dateTime.month(.wide).year()))")
                .foregroundStyle(.secondary)
            TextField("Amount Due (€)", text: $amountDue)
            TextField("Amount Paid (€)", text: $amountPaid)
            Toggle("Paid", isOn: $isPaid)
            if isPaid {
                DatePicker("Payment Date", selection: $paidDate, displayedComponents: .date)
            }
            TextField("Notes (optional)", text: $notes)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 380)
        .onAppear {
            amountDue = String(format: "%.2f", payment.amountDue)
            amountPaid = String(format: "%.2f", payment.amountPaid)
            isPaid = payment.isPaid
            paidDate = payment.paidDate ?? Date()
            notes = payment.notes
        }
    }

    private func save() {
        payment.amountDue = Double(amountDue.replacingOccurrences(of: ",", with: ".")) ?? payment.amountDue
        payment.amountPaid = Double(amountPaid.replacingOccurrences(of: ",", with: ".")) ?? payment.amountPaid
        payment.isPaid = isPaid
        payment.paidDate = isPaid ? paidDate : nil
        payment.notes = notes
        try? context.save()
        dismiss()
    }
}
