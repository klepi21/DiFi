import Foundation
import SwiftData

// MARK: - Income

enum IncomeType: String, Codable, CaseIterable {
    case recurring = "Recurring"
    case oneTime = "One-time"
}

@Model
final class IncomeEntry {
    var id: UUID
    var date: Date
    var amount: Double
    var source: String
    var type: IncomeType
    var notes: String
    // taxReserved is computed live via projectedTaxReservePct(...) — not stored, calculated on the fly

    // VAT / ΦΠΑ: nil means no VAT applies to this entry.
    // 24.0 = standard Greek rate, 13.0 = reduced, 6.0 = super-reduced.
    // MUST be Optional for SwiftData auto-migration safety.
    var vatRate: Double?

    // Computed VAT amount for this entry
    var vatAmount: Double { amount * (vatRate ?? 0) / 100 }

    // How much of this specific payment the user wants set aside for investing.
    // Set per income entry on the Allocation page. Optional for SwiftData migration safety.
    var investmentAmount: Double?

    init(date: Date = .now, amount: Double, source: String, type: IncomeType = .oneTime, notes: String = "", vatRate: Double? = nil) {
        self.id = UUID()
        self.date = date
        self.amount = amount
        self.source = source
        self.type = type
        self.notes = notes
        self.vatRate = vatRate
    }
}

// MARK: - VAT Payment
// Tracks whether the VAT collected in a given month has been remitted to ΔΟΥ.
// One record per month — created when the user marks a month as paid.

@Model
final class VatPayment {
    var id: UUID
    var month: Date        // normalized to the 1st of the month
    var amountDue: Double  // total VAT collected that month (sum of vatAmount across income entries)
    var amountPaid: Double // actual amount remitted to ΔΟΥ (may differ slightly)
    var isPaid: Bool
    var paidDate: Date?
    var notes: String

    init(month: Date, amountDue: Double) {
        self.id = UUID()
        self.month = month
        self.amountDue = amountDue
        self.amountPaid = 0
        self.isPaid = false
        self.paidDate = nil
        self.notes = ""
    }
}

// MARK: - Expense

enum ExpenseCategory: String, Codable, CaseIterable {
    case housing = "Housing"
    case food = "Food"
    case transport = "Transport"
    case health = "Health"
    case entertainment = "Entertainment"
    case business = "Business"
    case other = "Other"

    var color: String {
        switch self {
        case .housing: return "blue"
        case .food: return "orange"
        case .transport: return "green"
        case .health: return "red"
        case .entertainment: return "purple"
        case .business: return "teal"
        case .other: return "gray"
        }
    }
}

enum ExpenseType: String, Codable, CaseIterable {
    case fixed = "Fixed"
    case extra = "Extra"
}

@Model
final class ExpenseEntry {
    var id: UUID
    var date: Date
    var amount: Double
    var category: ExpenseCategory
    var type: ExpenseType
    var notes: String

    init(date: Date = .now, amount: Double, category: ExpenseCategory = .other, type: ExpenseType = .extra, notes: String = "") {
        self.id = UUID()
        self.date = date
        self.amount = amount
        self.category = category
        self.type = type
        self.notes = notes
    }
}

// MARK: - Recurring Expense
// Recurring expenses are templates that appear in every month automatically.
// They are NOT duplicated as ExpenseEntry rows — they are merged at display time.

@Model
final class RecurringExpense {
    var id: UUID
    var name: String
    var amount: Double
    var category: ExpenseCategory
    var notes: String
    var isActive: Bool  // When false, the item is paused and won't appear in monthly views

    init(name: String, amount: Double, category: ExpenseCategory = .other, notes: String = "") {
        self.id = UUID()
        self.name = name
        self.amount = amount
        self.category = category
        self.notes = notes
        self.isActive = true
    }
}

// MARK: - Debt

@Model
final class Debt {
    var id: UUID
    var name: String
    var totalAmount: Double
    var currentBalance: Double
    var monthlyPayment: Double
    var interestRate: Double // annual %, 0 if none
    var startDate: Date
    var notes: String

    init(name: String, totalAmount: Double, currentBalance: Double, monthlyPayment: Double, interestRate: Double = 0, startDate: Date = .now, notes: String = "") {
        self.id = UUID()
        self.name = name
        self.totalAmount = totalAmount
        self.currentBalance = currentBalance
        self.monthlyPayment = monthlyPayment
        self.interestRate = interestRate
        self.startDate = startDate
        self.notes = notes
    }

    var monthsToPayoff: Int {
        guard monthlyPayment > 0 else { return 0 }
        if interestRate == 0 {
            return Int(ceil(currentBalance / monthlyPayment))
        }
        let r = interestRate / 100 / 12
        let n = -log(1 - (r * currentBalance) / monthlyPayment) / log(1 + r)
        return n.isNaN || n.isInfinite ? 0 : Int(ceil(n))
    }

    var totalInterest: Double {
        guard interestRate > 0, monthlyPayment > 0 else { return 0 }
        let months = Double(monthsToPayoff)
        return (monthlyPayment * months) - currentBalance
    }
}

// MARK: - Crypto Holding
// A cached snapshot of a Kraken balance, refreshed by CryptoView's sync action.
// Not user-editable — it mirrors whatever Kraken last reported so the dashboard/reports
// have something to read without hitting the network on every screen.

@Model
final class CryptoHolding {
    var id: UUID
    var rawAsset: String       // Kraken's own code, e.g. "XXBT", "SOL" — or an ERC-20 contract address / "ETH"
    var displayName: String    // normalized, e.g. "BTC", "SOL"
    var amount: Double
    var priceEUR: Double
    var valueEUR: Double
    var lastSyncedAt: Date
    // Cost basis of the amount still held, derived from Kraken trade history (average-cost
    // method). Nil when trade history is unavailable (e.g. missing API permission, or the coins
    // were deposited rather than bought on Kraken) — the UI falls back to "—" for those rows.
    var costBasisEUR: Double?
    // "kraken" or "wallet" — which sync owns this row, so each sync only replaces its own rows
    // instead of wiping out the other source's holdings. Needs the inline default (not just an
    // init parameter default) so SwiftData's lightweight migration can backfill this value for
    // rows that existed before this attribute was added — without it, migration fails outright
    // and the app won't launch at all.
    var source: String = "kraken"

    init(rawAsset: String, displayName: String, amount: Double, priceEUR: Double, costBasisEUR: Double? = nil, source: String = "kraken", lastSyncedAt: Date = .now) {
        self.id = UUID()
        self.rawAsset = rawAsset
        self.displayName = displayName
        self.amount = amount
        self.priceEUR = priceEUR
        self.valueEUR = amount * priceEUR
        self.costBasisEUR = costBasisEUR
        self.source = source
        self.lastSyncedAt = lastSyncedAt
    }

    /// Unrealized gain/loss in EUR on the amount still held, vs. what it cost to acquire.
    var changeEUR: Double? {
        guard let costBasisEUR else { return nil }
        return valueEUR - costBasisEUR
    }

    /// Unrealized gain/loss as a percentage of cost basis.
    var changePercent: Double? {
        guard let costBasisEUR, costBasisEUR > 0 else { return nil }
        return (valueEUR - costBasisEUR) / costBasisEUR * 100
    }
}

// MARK: - Tax Payment

@Model
final class TaxPayment {
    var id: UUID
    var date: Date
    var amount: Double
    var notes: String

    init(date: Date = .now, amount: Double, notes: String = "") {
        self.id = UUID()
        self.date = date
        self.amount = amount
        self.notes = notes
    }
}

// MARK: - ΕΦΚΑ Monthly Status
// Tracks whether the fixed monthly ΕΦΚΑ contribution has been paid for a given month.
// If marked unpaid, the app offers to add it as a debt.

@Model
final class EfkaMonthStatus {
    var id: UUID
    var month: Date        // always the 1st of the month (normalized)
    var amount: Double
    var isPaid: Bool
    var paidDate: Date?
    // Optional so SwiftData can migrate existing rows by setting nil (treated as false)
    var addedToDebt: Bool?

    init(month: Date, amount: Double) {
        self.id = UUID()
        self.month = month
        self.amount = amount
        self.isPaid = false
        self.paidDate = nil
        self.addedToDebt = false
    }
}

// MARK: - Recurring Expense Payment
// Tracks paid/unpaid status for each recurring expense per calendar month.
// One record per (recurringExpense, month) pair — created when the user marks it paid.
// All fields that could be added to an existing store MUST be Optional for SwiftData migration safety.

@Model
final class RecurringExpensePayment {
    var id: UUID
    var recurringExpenseID: UUID  // matches RecurringExpense.id
    var month: Date               // normalized to 1st of month
    var amount: Double            // snapshot of amount at time of payment
    var isPaid: Bool
    var paidDate: Date?

    init(recurringExpenseID: UUID, month: Date, amount: Double) {
        self.id = UUID()
        self.recurringExpenseID = recurringExpenseID
        self.month = month
        self.amount = amount
        self.isPaid = false
        self.paidDate = nil
    }
}

// MARK: - App Settings (singleton stored as single row)

@Model
final class AppSettings {
    var id: UUID
    var efkaMonthly: Double     // fixed monthly ΕΦΚΑ deduction

    init() {
        self.id = UUID()
        self.efkaMonthly = 0
    }
}

// MARK: - Emergency Fund (singleton stored as single row)
// Backs the Assistant tab's priority waterfall: emergency fund is topped up before debt
// payoff or investing get a share of monthly surplus.

@Model
final class EmergencyFund {
    var id: UUID
    var targetMonths: Double  // how many months of expenses the fund should cover, default 3
    var balance: Double       // current cash saved, updated manually by the user
    // How much of this month's surplus the user wants the Assistant to actually split up —
    // NOT the full surplus by default. Optional so SwiftData migration is safe; nil means
    // "not set yet", prompting the user to choose an amount rather than silently defaulting
    // to 100% of surplus.
    var monthlyAllocationTarget: Double?

    init(targetMonths: Double = 3, balance: Double = 0) {
        self.id = UUID()
        self.targetMonths = targetMonths
        self.balance = balance
    }
}
