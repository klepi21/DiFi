import SwiftUI
import SwiftData
import Charts

// MARK: - Expenses View

struct ExpensesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ExpenseEntry.date, order: .reverse) private var entries: [ExpenseEntry]
    @Query private var recurringExpenses: [RecurringExpense]
    // All payment records — filtered per-row in the view to find the matching month record
    @Query private var recurringPayments: [RecurringExpensePayment]

    @State private var showAdd = false
    @State private var showAddRecurring = false
    @State private var editTarget: ExpenseEntry?
    @State private var editRecurring: RecurringExpense?
    @State private var selectedMonth: Date = Calendar.current.startOfMonth(for: .now)
    @State private var tab: ExpensesTab = .thisMonth
    @State private var chartExpanded = true

    enum ExpensesTab: String, CaseIterable {
        case thisMonth = "This Month"
        case recurring = "Recurring"
    }

    // One-time entries for selected month
    private var filtered: [ExpenseEntry] {
        entries.filter { Calendar.current.isDate($0.date, equalTo: selectedMonth, toGranularity: .month) }
    }

    // Total = one-time + active recurring
    private var recurringTotal: Double {
        recurringExpenses.filter { $0.isActive }.reduce(0) { $0 + $1.amount }
    }
    private var total: Double { filtered.reduce(0) { $0 + $1.amount } + recurringTotal }

    // Category breakdown including recurring
    private var byCategory: [(category: ExpenseCategory, total: Double)] {
        var map: [ExpenseCategory: Double] = [:]
        filtered.forEach { map[$0.category, default: 0] += $0.amount }
        recurringExpenses.filter { $0.isActive }.forEach { map[$0.category, default: 0] += $0.amount }
        return map.map { ($0.key, $0.value) }.sorted { $0.total > $1.total }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Expenses")
                    .font(.largeTitle.bold())
                Spacer()
                if tab == .thisMonth {
                    MonthPicker(selected: $selectedMonth)
                    Button("Add Expense") { showAdd = true }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Add Recurring") { showAddRecurring = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()

            // Tab picker
            Picker("View", selection: $tab) {
                ForEach(ExpensesTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            if tab == .thisMonth {
                thisMonthView
            } else {
                recurringView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showAdd) { AddExpenseSheet() }
        .sheet(isPresented: $showAddRecurring) { AddRecurringExpenseSheet() }
        .sheet(item: $editTarget) { entry in EditExpenseSheet(entry: entry) }
        .sheet(item: $editRecurring) { rec in EditRecurringExpenseSheet(expense: rec) }
    }

    // MARK: This Month Tab

    @ViewBuilder
    private var thisMonthView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsible donut chart
            DisclosureGroup(isExpanded: $chartExpanded) {
                if byCategory.isEmpty {
                    Text("No data").foregroundStyle(.secondary).frame(height: 140).frame(maxWidth: .infinity)
                } else {
                    HStack(alignment: .top, spacing: 20) {
                        Chart(byCategory, id: \.category) { d in
                            SectorMark(angle: .value("Amount", d.total), innerRadius: .ratio(0.55))
                                .foregroundStyle(by: .value("Category", d.category.rawValue))
                        }
                        .frame(width: 140, height: 140)

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(byCategory, id: \.category) { d in
                                HStack {
                                    Text(d.category.rawValue).font(.caption)
                                    Spacer()
                                    Text(d.total.euroFormatted).font(.caption.bold())
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 8)
                }
            } label: {
                HStack {
                    Text("By Category").font(.headline)
                    Spacer()
                    Text("Total: \(total.euroFormatted)").font(.title3.bold()).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            // List: recurring items first (labeled), then one-time entries
            if filtered.isEmpty && recurringExpenses.filter({ $0.isActive }).isEmpty {
                ContentUnavailableView("No expenses this month", systemImage: "arrow.up.circle", description: Text("Add one-time or recurring expenses to see them here."))
            } else {
                List {
                    // Active recurring expenses with per-month paid/unpaid tracking
                    let activeRecurring = recurringExpenses.filter { $0.isActive }
                    if !activeRecurring.isEmpty {
                        Section("Recurring") {
                            ForEach(activeRecurring) { rec in
                                // Look up any existing payment record for this expense + month
                                let payment = recurringPayments.first {
                                    $0.recurringExpenseID == rec.id &&
                                    Calendar.current.isDate($0.month, equalTo: selectedMonth, toGranularity: .month)
                                }
                                RecurringMonthRow(
                                    rec: rec,
                                    payment: payment,
                                    month: selectedMonth,
                                    onMarkPaid: { markRecurringPaid(rec: rec, existingPayment: payment) },
                                    onEdit: { editRecurring = rec }
                                )
                            }
                        }
                    }

                    // One-time expense entries for the selected month
                    if !filtered.isEmpty {
                        Section("One-time") {
                            ForEach(filtered) { entry in
                                ExpenseRow(
                                    entry: entry,
                                    onEdit: { editTarget = entry },
                                    onDelete: { context.delete(entry); try? context.save() }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Mark Recurring Paid

    /// Creates or updates a RecurringExpensePayment record, then logs an ExpenseEntry for the month.
    /// Guard: only creates the ExpenseEntry when the payment record transitions to isPaid=true for the first time.
    private func markRecurringPaid(rec: RecurringExpense, existingPayment: RecurringExpensePayment?) {
        if let existing = existingPayment {
            // Payment record already exists — just flip it to paid
            existing.isPaid = true
            existing.paidDate = Date()
        } else {
            // First time marking paid this month — create the record
            let p = RecurringExpensePayment(recurringExpenseID: rec.id, month: selectedMonth, amount: rec.amount)
            p.isPaid = true
            p.paidDate = Date()
            context.insert(p)
        }

        // Only log as an ExpenseEntry when going paid for the first time (existingPayment nil or unpaid).
        // Using the 1st of the selected month as the date so it lands in the correct month bucket.
        let expenseDate = Calendar.current.startOfMonth(for: selectedMonth)
        context.insert(ExpenseEntry(
            date: expenseDate,
            amount: rec.amount,
            category: rec.category,
            type: .fixed,
            notes: "\(rec.name) – recurring"
        ))

        try? context.save()
    }

    // MARK: Recurring Tab

    @ViewBuilder
    private var recurringView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if recurringExpenses.isEmpty {
                ContentUnavailableView(
                    "No recurring expenses",
                    systemImage: "arrow.clockwise.circle",
                    description: Text("Add fixed monthly costs like rent, subscriptions, or insurance.")
                )
            } else {
                List {
                    ForEach(recurringExpenses) { rec in
                        RecurringExpenseRow(
                            rec: rec,
                            onEdit: { editRecurring = rec },
                            onDelete: { context.delete(rec); try? context.save() }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Row Views

struct ExpenseRow: View {
    let entry: ExpenseEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var confirmDelete = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.notes.isEmpty ? entry.category.rawValue : entry.notes).font(.headline)
                HStack {
                    Text(entry.date.formatted(.dateTime.day().month().year())).font(.caption).foregroundStyle(.secondary)
                    CategoryChip(category: entry.category)
                }
            }
            Spacer()
            Text(entry.amount.euroFormatted).font(.headline)
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
        .confirmationDialog("Delete \"\(entry.notes.isEmpty ? entry.category.rawValue : entry.notes)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }
}

/// Shows a recurring expense in "This Month" with paid/unpaid badge and a Mark Paid button.
/// `payment` is nil when no payment record exists for this expense+month yet.
struct RecurringMonthRow: View {
    let rec: RecurringExpense
    let payment: RecurringExpensePayment?
    let month: Date
    let onMarkPaid: () -> Void
    let onEdit: () -> Void

    @State private var confirmPaid = false

    private var isPaid: Bool { payment?.isPaid == true }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rec.name).font(.headline)
                    Image(systemName: "arrow.clockwise").font(.caption2).foregroundStyle(Color.accentColor)
                }
                HStack(spacing: 6) {
                    CategoryChip(category: rec.category)
                    if isPaid, let pd = payment?.paidDate {
                        Text("Paid \(pd.formatted(.dateTime.day().month()))")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Not paid yet").font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Text(rec.amount.euroFormatted).font(.headline)
                .foregroundStyle(isPaid ? .green : .primary)

            if isPaid {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Button("Mark Paid") { confirmPaid = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
            }

            Button { onEdit() } label: { Image(systemName: "pencil") }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.vertical, 6)
        .confirmationDialog(
            "Mark \"\(rec.name)\" as paid for \(month.formatted(.dateTime.month(.wide).year()))?",
            isPresented: $confirmPaid,
            titleVisibility: .visible
        ) {
            Button("Mark as Paid") { onMarkPaid() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(rec.amount.euroFormatted) will be logged as an expense for this month.")
        }
    }
}

/// Row inside the Recurring tab
struct RecurringExpenseRow: View {
    let rec: RecurringExpense
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var confirmDelete = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.name).font(.headline)
                HStack {
                    CategoryChip(category: rec.category)
                    if !rec.isActive {
                        Text("Paused").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Text(rec.amount.euroFormatted).font(.headline)
                .foregroundStyle(rec.isActive ? .primary : .secondary)
            HStack(spacing: 6) {
                Button { onEdit() } label: { Image(systemName: "pencil") }
                    .buttonStyle(.bordered).controlSize(.small)
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .opacity(rec.isActive ? 1 : 0.5)
        .contextMenu {
            Button("Edit") { onEdit() }
            Divider()
            Button("Delete", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete recurring expense \"\(rec.name)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove it from all months. This cannot be undone.")
        }
    }
}

struct CategoryChip: View {
    let category: ExpenseCategory
    var body: some View {
        Text(category.rawValue)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(chipColor.opacity(0.2), in: Capsule())
            .foregroundStyle(chipColor)
    }
    private var chipColor: Color {
        switch category {
        case .housing: return .blue
        case .food: return .orange
        case .transport: return .green
        case .health: return .red
        case .entertainment: return .purple
        case .business: return .teal
        case .other: return .gray
        }
    }
}

// MARK: - Add / Edit Sheets

struct AddExpenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var amount = ""
    @State private var notes = ""
    @State private var category: ExpenseCategory = .other
    @State private var type: ExpenseType = .extra
    @State private var date = Date()

    var body: some View {
        Form {
            Text("Add Expense").font(.headline)
            TextField("Amount (€)", text: $amount)
            TextField("Description", text: $notes)
            Picker("Category", selection: $category) {
                ForEach(ExpenseCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Type", selection: $type) {
                ForEach(ExpenseType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            DatePicker("Date", selection: $date, displayedComponents: .date)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(amount.isEmpty).keyboardShortcut(.return)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 380)
    }

    private func save() {
        guard let value = Double(amount.replacingOccurrences(of: ",", with: ".")) else { return }
        context.insert(ExpenseEntry(date: date, amount: value, category: category, type: type, notes: notes))
        try? context.save()
        dismiss()
    }
}

struct EditExpenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let entry: ExpenseEntry

    @State private var amount = ""
    @State private var notes = ""
    @State private var category: ExpenseCategory = .other
    @State private var date = Date()

    var body: some View {
        Form {
            Text("Edit Expense").font(.headline)
            TextField("Amount (€)", text: $amount)
            TextField("Description", text: $notes)
            Picker("Category", selection: $category) {
                ForEach(ExpenseCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            DatePicker("Date", selection: $date, displayedComponents: .date)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(amount.isEmpty).keyboardShortcut(.return)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 380)
        .onAppear {
            amount = String(format: "%.2f", entry.amount)
            notes = entry.notes
            category = entry.category
            date = entry.date
        }
    }

    private func save() {
        guard let value = Double(amount.replacingOccurrences(of: ",", with: ".")) else { return }
        entry.amount = value
        entry.notes = notes
        entry.category = category
        entry.date = date
        try? context.save()
        dismiss()
    }
}

struct AddRecurringExpenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name = ""
    @State private var amount = ""
    @State private var category: ExpenseCategory = .other
    @State private var notes = ""

    var body: some View {
        Form {
            Text("Add Recurring Expense").font(.headline)
            Text("This expense will auto-appear in every month.").font(.caption).foregroundStyle(.secondary)
            TextField("Name (e.g. Rent, Netflix)", text: $name)
            TextField("Monthly Amount (€)", text: $amount)
            Picker("Category", selection: $category) {
                ForEach(ExpenseCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            TextField("Notes (optional)", text: $notes)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(name.isEmpty || amount.isEmpty).keyboardShortcut(.return)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 380)
    }

    private func save() {
        guard let value = Double(amount.replacingOccurrences(of: ",", with: ".")) else { return }
        context.insert(RecurringExpense(name: name, amount: value, category: category, notes: notes))
        try? context.save()
        dismiss()
    }
}

struct EditRecurringExpenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let expense: RecurringExpense

    @State private var name = ""
    @State private var amount = ""
    @State private var category: ExpenseCategory = .other
    @State private var notes = ""
    @State private var isActive = true

    var body: some View {
        Form {
            Text("Edit Recurring Expense").font(.headline)
            TextField("Name", text: $name)
            TextField("Monthly Amount (€)", text: $amount)
            Picker("Category", selection: $category) {
                ForEach(ExpenseCategory.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            TextField("Notes", text: $notes)
            Toggle("Active", isOn: $isActive)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape)
                Spacer()
                Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(name.isEmpty || amount.isEmpty).keyboardShortcut(.return)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 380)
        .onAppear {
            name = expense.name
            amount = String(format: "%.2f", expense.amount)
            category = expense.category
            notes = expense.notes
            isActive = expense.isActive
        }
    }

    private func save() {
        guard let value = Double(amount.replacingOccurrences(of: ",", with: ".")) else { return }
        expense.name = name
        expense.amount = value
        expense.category = category
        expense.notes = notes
        expense.isActive = isActive
        try? context.save()
        dismiss()
    }
}
