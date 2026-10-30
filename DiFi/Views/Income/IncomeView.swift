import SwiftUI
import SwiftData

struct IncomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \IncomeEntry.date, order: .reverse) private var entries: [IncomeEntry]
    @Query private var settingsQuery: [AppSettings]
    @Query private var efkaStatuses: [EfkaMonthStatus]

    @State private var showAdd = false
    @State private var editTarget: IncomeEntry?
    @State private var tab: IncomeTab = .thisMonth
    @State private var selectedMonth: Date = Calendar.current.startOfMonth(for: .now)

    enum IncomeTab: String, CaseIterable {
        case thisMonth = "This Month"
        case all = "All Entries"
        case upcoming = "Upcoming"
    }

    private var settings: AppSettings { settingsQuery.first ?? AppSettings() }

    private var monthEntries: [IncomeEntry] {
        entries.filter { Calendar.current.isDate($0.date, equalTo: selectedMonth, toGranularity: .month) }
    }

    private var upcomingEntries: [IncomeEntry] {
        entries.filter { $0.date > Date() }.sorted { $0.date < $1.date }
    }

    // Live projected tax-reserve rate — see Extensions.swift for the run-rate projection logic
    private var projectedRatePct: Double {
        projectedTaxReservePct(incomes: entries, efkaMonthly: settings.efkaMonthly)
    }

    private var totalGross: Double { monthEntries.reduce(0) { $0 + $1.amount } }
    private var totalTax: Double { totalGross * projectedRatePct / 100 }
    private var totalNet: Double { totalGross - totalTax - settings.efkaMonthly }

    // Find or lazily create the ΕΦΚΑ status for the selected month
    private var efkaStatus: EfkaMonthStatus? {
        efkaStatuses.first { Calendar.current.isDate($0.month, equalTo: selectedMonth, toGranularity: .month) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Income")
                    .font(.largeTitle.bold())
                Spacer()
                if tab == .thisMonth {
                    MonthPicker(selected: $selectedMonth)
                }
                Button("Add Income") { showAdd = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            // Tab picker
            Picker("View", selection: $tab) {
                ForEach(IncomeTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            if tab == .thisMonth {
                // Summary cards
                HStack(spacing: 12) {
                    SummaryCard(title: "Gross", value: totalGross.euroFormatted, color: .green, icon: "eurosign.circle.fill")
                    SummaryCard(title: "Tax Reserve (\(String(format: "%.1f", projectedRatePct))%)", value: totalTax.euroFormatted, color: .purple, icon: "building.columns.fill")
                    SummaryCard(title: "ΕΦΚΑ", value: settings.efkaMonthly.euroFormatted, color: .orange, icon: "person.fill")
                    SummaryCard(title: "Net", value: totalNet.euroFormatted, color: .blue, icon: "checkmark.circle.fill")
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

                // ΕΦΚΑ monthly status card
                if settings.efkaMonthly > 0 {
                    EfkaStatusCard(
                        month: selectedMonth,
                        amount: settings.efkaMonthly,
                        status: efkaStatus,
                        onMarkPaid: { markEfkaPaid() },
                        onAddToDebt: { addEfkaToDebt() }
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }

            Divider()

            switch tab {
            case .thisMonth:
                incomeList(monthEntries, emptyMessage: "No income this month", emptyIcon: "arrow.down.circle")
            case .all:
                incomeList(entries.map { $0 }, emptyMessage: "No income entries yet", emptyIcon: "tray")
            case .upcoming:
                upcomingView
            }
        }
        // Fix: anchor content to top-left; NavigationSplitView detail otherwise centers it
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showAdd) { AddIncomeSheet() }
        .sheet(item: $editTarget) { entry in EditIncomeSheet(entry: entry) }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func incomeList(_ items: [IncomeEntry], emptyMessage: String, emptyIcon: String) -> some View {
        if items.isEmpty {
            // Full-width centered empty state
            VStack {
                Spacer()
                ContentUnavailableView(emptyMessage, systemImage: emptyIcon, description: Text("Tap Add Income to record earnings."))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(items) { entry in
                    IncomeRow(
                        entry: entry,
                        taxPct: projectedRatePct,
                        onEdit: { editTarget = entry },
                        onDelete: { context.delete(entry); try? context.save() }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var upcomingView: some View {
        if upcomingEntries.isEmpty {
            VStack {
                Spacer()
                ContentUnavailableView(
                    "No upcoming income",
                    systemImage: "calendar.badge.clock",
                    description: Text("Add an income entry with a future date to see it here.")
                )
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(upcomingEntries) { entry in
                    IncomeRow(
                        entry: entry,
                        taxPct: projectedRatePct,
                        onEdit: { editTarget = entry },
                        onDelete: { context.delete(entry); try? context.save() }
                    )
                }
            }
        }
    }

    private func markEfkaPaid() {
        let status = efkaStatus ?? createEfkaStatus()
        status.isPaid = true
        status.paidDate = Date()
        try? context.save()
    }

    private func addEfkaToDebt() {
        // Guard: only create the debt once per month
        guard !(efkaStatus?.addedToDebt ?? false) else { return }
        let monthLabel = selectedMonth.formatted(.dateTime.month(.wide).year())
        context.insert(Debt(
            name: "ΕΦΚΑ – \(monthLabel)",
            totalAmount: settings.efkaMonthly,
            currentBalance: settings.efkaMonthly,
            monthlyPayment: settings.efkaMonthly,
            notes: "Auto-created from ΕΦΚΑ unpaid status"
        ))
        let status = efkaStatus ?? createEfkaStatus()
        status.addedToDebt = true
        try? context.save()
    }

    private func createEfkaStatus() -> EfkaMonthStatus {
        let s = EfkaMonthStatus(month: selectedMonth, amount: settings.efkaMonthly)
        context.insert(s)
        return s
    }
}

// MARK: - ΕΦΚΑ Status Card

struct EfkaStatusCard: View {
    let month: Date
    let amount: Double
    let status: EfkaMonthStatus?
    let onMarkPaid: () -> Void
    let onAddToDebt: () -> Void

    @State private var confirmPaid = false
    @State private var confirmDebt = false

    private var isPaid: Bool { status?.isPaid == true }
    private var isAddedToDebt: Bool { status?.addedToDebt ?? false }
    // Card is "resolved" when either action has been taken
    private var isResolved: Bool { isPaid || isAddedToDebt }

    private var borderColor: Color {
        if isPaid { return .green }
        if isAddedToDebt { return .orange }
        return .orange.opacity(0.5)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isPaid ? "checkmark.circle.fill" : isAddedToDebt ? "arrow.right.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(isPaid ? .green : isAddedToDebt ? .orange : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("ΕΦΚΑ — \(month.formatted(.dateTime.month(.wide).year()))")
                    .font(.headline)
                if isPaid, let paidDate = status?.paidDate {
                    Text("Paid on \(paidDate.formatted(.dateTime.day().month().year()))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if isAddedToDebt {
                    Text("Added to Debts — pay from there")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not yet paid — mark it or move it to Debts")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Spacer()

            Text(amount.euroFormatted).font(.headline)

            if isPaid {
                badge("Paid", color: .green)
            } else if isAddedToDebt {
                badge("In Debts", color: .orange)
            } else {
                // Show action buttons only when neither action has been taken
                HStack(spacing: 8) {
                    Button("Mark Paid") { confirmPaid = true }
                        .buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
                    Button("Add to Debts") { confirmDebt = true }
                        .buttonStyle(.bordered).tint(.orange).controlSize(.small)
                }
                .confirmationDialog("Mark ΕΦΚΑ as paid for \(month.formatted(.dateTime.month(.wide).year()))?", isPresented: $confirmPaid, titleVisibility: .visible) {
                    Button("Mark as Paid") { onMarkPaid() }
                    Button("Cancel", role: .cancel) {}
                }
                .confirmationDialog("Add \(amount.euroFormatted) ΕΦΚΑ to Debts for \(month.formatted(.dateTime.month(.wide).year()))?", isPresented: $confirmDebt, titleVisibility: .visible) {
                    Button("Add to Debts") { onAddToDebt() }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(borderColor.opacity(0.4), lineWidth: 1))
    }

    private func badge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Income Row

struct IncomeRow: View {
    let entry: IncomeEntry
    let taxPct: Double
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var confirmDelete = false
    private var isFuture: Bool { entry.date > Date() }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.source).font(.headline)
                    if isFuture {
                        Text("Upcoming")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                HStack {
                    Text(entry.date.formatted(.dateTime.day().month().year()))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(entry.type.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                    if !entry.notes.isEmpty {
                        Text(entry.notes).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.amount.euroFormatted).font(.headline)
                Text("Tax: \((entry.amount * taxPct / 100).euroFormatted)")
                    .font(.caption).foregroundStyle(.secondary)
                // Show VAT line only when a VAT rate is set on this entry
                if let rate = entry.vatRate {
                    Text("ΦΠΑ \(Int(rate))%: \(entry.vatAmount.euroFormatted)")
                        .font(.caption).foregroundStyle(.blue)
                }
            }
            HStack(spacing: 6) {
                Button { onEdit() } label: { Image(systemName: "pencil") }
                    .buttonStyle(.bordered).controlSize(.small)
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .opacity(isFuture ? 0.75 : 1)
        .contextMenu {
            Button("Edit") { onEdit() }
            Divider()
            Button("Delete", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete \"\(entry.source)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }
}

// MARK: - Add Income Sheet

struct AddIncomeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var amount = ""
    @State private var source = ""
    @State private var type: IncomeType = .oneTime
    @State private var date = Date()
    @State private var notes = ""

    // VAT is always 24% (standard rate), added as an extra on top of the entered amount.
    private var parsedAmount: Double? { Double(amount.replacingOccurrences(of: ",", with: ".")) }
    private var vatAmount: Double { (parsedAmount ?? 0) * 0.24 }
    private var invoiceTotal: Double { (parsedAmount ?? 0) + vatAmount }

    var body: some View {
        Form {
            Text("Add Income").font(.headline)

            // Amount field with live invoice preview (VAT is always +24% on top)
            VStack(alignment: .leading, spacing: 6) {
                TextField("Net Amount (€)", text: $amount)
                Text("Εισάγετε το καθαρό ποσό χωρίς ΦΠΑ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let net = parsedAmount, net > 0 {
                    HStack {
                        Image(systemName: "doc.text").font(.caption).foregroundStyle(.blue)
                        Text("Σύνολο τιμολογίου: \(invoiceTotal.euroFormatted)  (net \(net.euroFormatted) + ΦΠΑ 24% \(vatAmount.euroFormatted))")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                    }
                    .padding(6)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            TextField("Source / Client", text: $source)

            Picker("Type", selection: $type) {
                ForEach(IncomeType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)

            DatePicker("Date", selection: $date, displayedComponents: .date)
            TextField("Notes (optional)", text: $notes)

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(amount.isEmpty || source.isEmpty)
                    .keyboardShortcut(.return)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
    }

    private func save() {
        guard let value = parsedAmount else { return }
        context.insert(IncomeEntry(date: date, amount: value, source: source, type: type, notes: notes, vatRate: 24))
        try? context.save()
        dismiss()
    }
}

// MARK: - Edit Income Sheet

struct EditIncomeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let entry: IncomeEntry

    @State private var amount = ""
    @State private var source = ""
    @State private var type: IncomeType = .oneTime
    @State private var date = Date()
    @State private var notes = ""

    // VAT is always 24%, added as an extra on top of the entered amount.
    private var parsedAmount: Double? { Double(amount.replacingOccurrences(of: ",", with: ".")) }
    private var vatAmount: Double { (parsedAmount ?? 0) * 0.24 }
    private var invoiceTotal: Double { (parsedAmount ?? 0) + vatAmount }

    var body: some View {
        Form {
            Text("Edit Income").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Net Amount (€)", text: $amount)
                Text("Εισάγετε το καθαρό ποσό χωρίς ΦΠΑ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let net = parsedAmount, net > 0 {
                    HStack {
                        Image(systemName: "doc.text").font(.caption).foregroundStyle(.blue)
                        Text("Σύνολο τιμολογίου: \(invoiceTotal.euroFormatted)  (net \(net.euroFormatted) + ΦΠΑ 24% \(vatAmount.euroFormatted))")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                    }
                    .padding(6)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            TextField("Source / Client", text: $source)

            Picker("Type", selection: $type) {
                ForEach(IncomeType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)

            DatePicker("Date", selection: $date, displayedComponents: .date)
            TextField("Notes (optional)", text: $notes)

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(amount.isEmpty || source.isEmpty)
                    .keyboardShortcut(.return)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
        .onAppear {
            amount = String(format: "%.2f", entry.amount)
            source = entry.source
            type = entry.type
            date = entry.date
            notes = entry.notes
        }
    }

    private func save() {
        guard let value = parsedAmount else { return }
        entry.amount = value
        entry.source = source
        entry.type = type
        entry.date = date
        entry.notes = notes
        entry.vatRate = 24
        try? context.save()
        dismiss()
    }
}
