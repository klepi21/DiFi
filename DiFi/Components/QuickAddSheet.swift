import SwiftUI
import SwiftData

struct QuickAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var mode: QuickAddMode = .expense
    @State private var amount: String = ""
    @State private var label: String = ""
    @State private var category: ExpenseCategory = .other
    @State private var notes: String = ""

    enum QuickAddMode: String, CaseIterable {
        case expense = "Expense"
        case income = "Income"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sheet title bar
            HStack {
                Text("Quick Add")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            VStack(spacing: 16) {
                Picker("Type", selection: $mode) {
                    ForEach(QuickAddMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("€").foregroundStyle(.secondary)
                    TextField(mode == .income ? "Net Amount" : "Amount", text: $amount)
                        .textFieldStyle(.roundedBorder)
                }
                if mode == .income {
                    Text("Εισάγετε το καθαρό ποσό — ΦΠΑ 24% προστίθεται αυτόματα")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField(mode == .expense ? "Description" : "Source", text: $label)
                    .textFieldStyle(.roundedBorder)

                if mode == .expense {
                    Picker("Category", selection: $category) {
                        ForEach(ExpenseCategory.allCases, id: \.self) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                    .pickerStyle(.menu)
                }

                TextField("Notes (optional)", text: $notes)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.escape)
                    Spacer()
                    Button("Add") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(amount.isEmpty || label.isEmpty)
                        .keyboardShortcut(.return)
                }
            }
            .padding()
        }
        .frame(width: 360)
    }

    private func save() {
        guard let value = Double(amount.replacingOccurrences(of: ",", with: ".")) else { return }
        if mode == .expense {
            let entry = ExpenseEntry(amount: value, category: category, type: .extra,
                                    notes: label + (notes.isEmpty ? "" : " – " + notes))
            context.insert(entry)
        } else {
            // Net amount, consistent with the Income tab — VAT is always 24%, added on top.
            context.insert(IncomeEntry(amount: value, source: label, type: .oneTime, notes: notes, vatRate: 24))
        }
        try? context.save()
        dismiss()
    }
}
