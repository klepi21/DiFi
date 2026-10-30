import Foundation
import SwiftUI

// MARK: - Double formatting

extension Double {
    /// Formats a Double as a Euro currency string using European locale (e.g. "€1.234,56")
    var euroFormatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "€"
        formatter.currencyCode = "EUR"
        formatter.locale = Locale(identifier: "el_GR")
        return formatter.string(from: NSNumber(value: self)) ?? "€\(self)"
    }

    /// Formats a signed percentage change, e.g. 12.34 -> "+12.3%", -4.5 -> "-4.5%"
    var signedPercentFormatted: String {
        String(format: "%@%.1f%%", self >= 0 ? "+" : "", self)
    }

    /// Formats a coin amount, trimming trailing zeros (e.g. 0.023845, 1.5, 1200)
    var coinFormatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = abs(self) >= 1 ? 4 : 8
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: self)) ?? String(self)
    }
}

// MARK: - Calendar helpers

extension Calendar {
    /// Returns the first day of the month containing the given date (time zeroed out)
    func startOfMonth(for date: Date) -> Date {
        let comps = dateComponents([.year, .month], from: date)
        return self.date(from: comps) ?? date
    }
}

// MARK: - Annual tax obligation

/// Total estimated tax obligation (income tax + 55% προκαταβολή) for a given calendar year,
/// using the progressive freelancer brackets. ΕΦΚΑ (year × monthly) is the only deduction applied.
/// Shared by DashboardView (live estimate) and ReportsView (year-end debt closure).
func annualTaxObligation(incomes: [IncomeEntry], efkaMonthly: Double, year: Int) -> Double {
    let yearIncomes = incomes.filter { Calendar.current.component(.year, from: $0.date) == year }
    let gross = yearIncomes.reduce(0) { $0 + $1.amount }
    let efka = efkaMonthly * 12
    let taxable = max(0, gross - efka)
    let result = calculateGreekIncomeTax(taxableIncome: taxable)
    return result.tax + result.tax * 0.55
}

// MARK: - Year-end income projection

/// Projects full-year gross income for `year` from the run rate observed since the FIRST income
/// entry of that year — not since 1 January — so someone who started earning mid-year isn't
/// extrapolated as if the earlier months had been zero. Elapsed days are floored at 14 so a
/// single fresh entry doesn't produce an absurd projection.
/// Returns the year-to-date total, the projected income still to come, and their sum.
func projectedYearEndGross(incomes: [IncomeEntry], year: Int, asOf: Date = .now) -> (ytd: Double, remaining: Double, annual: Double) {
    let calendar = Calendar.current
    let yearIncomes = incomes.filter { calendar.component(.year, from: $0.date) == year }
    let ytd = yearIncomes.reduce(0) { $0 + $1.amount }
    guard ytd > 0,
          let firstDate = yearIncomes.map(\.date).min(),
          let yearEnd = calendar.date(from: DateComponents(year: year, month: 12, day: 31))
    else { return (ytd, 0, ytd) }

    let today = calendar.startOfDay(for: asOf)
    let start = calendar.startOfDay(for: firstDate)
    let elapsedDays = Double(max((calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1, 14))
    let remainingDays = Double(max(calendar.dateComponents([.day], from: today, to: yearEnd).day ?? 0, 0))
    let remaining = ytd / elapsedDays * remainingDays
    return (ytd, remaining, ytd + remaining)
}

// MARK: - Projected tax reserve rate

/// The blended tax rate a full-year run-rate projection implies, as of a single calendar day:
/// extrapolate income earned up to and including that day to a full year, then run that
/// projection through the real progressive freelancer brackets. `asOfDay` must already be
/// normalized via `calendar.startOfDay(for:)` — entries are compared at day granularity so an
/// entry logged later in the same day is still counted (income entries carry a time-of-day
/// component, e.g. "12:49 PM", which would otherwise be excluded by a same-day midnight cutoff).
/// This is the instantaneous estimate at one checkpoint — see `projectedTaxReservePct` for how
/// checkpoints are combined across the year.
private func instantaneousProjectedRate(yearIncomes: [IncomeEntry], efkaMonthly: Double, asOfDay: Date, year: Int, calendar: Calendar) -> Double {
    let ytdGross = yearIncomes
        .filter { calendar.startOfDay(for: $0.date) <= asOfDay }
        .reduce(0) { $0 + $1.amount }
    guard ytdGross > 0 else { return 22 }

    // Clamp days-elapsed so the first few days of January don't produce absurd extrapolations
    let dayOfYear = calendar.ordinality(of: .day, in: .year, for: asOfDay) ?? 1
    let daysElapsed = Double(max(dayOfYear, 5))
    let isLeap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let daysInYear = Double(isLeap ? 366 : 365)

    let projectedAnnualGross = ytdGross / daysElapsed * daysInYear
    guard projectedAnnualGross > 0 else { return 22 }

    let taxableIncome = max(0, projectedAnnualGross - efkaMonthly * 12)
    let result = calculateGreekIncomeTax(taxableIncome: taxableIncome)
    let totalObligation = result.tax + result.tax * 0.55

    return min(60, max(9, (totalObligation / projectedAnnualGross) * 100))
}

/// Live tax-reserve rate for the current year — the HIGH-WATER MARK of the run-rate projection
/// so far, not just its current value. Recalculates every time income is added, but only ever
/// holds steady or climbs within a calendar year: it re-derives the projection as it would have
/// looked on every date an income entry landed (plus today) and takes the maximum. This means an
/// early lumpy invoice that briefly implies a high annual total keeps you reserving at that rate
/// even if the following weeks are quieter — so you're never short later and scrambling to catch
/// up. It resets to a conservative 22% floor at the start of each new calendar year.
func projectedTaxReservePct(incomes: [IncomeEntry], efkaMonthly: Double, asOf: Date = .now) -> Double {
    let calendar = Calendar.current
    let year = calendar.component(.year, from: asOf)
    let yearIncomes = incomes.filter { calendar.component(.year, from: $0.date) == year }
    guard !yearIncomes.isEmpty else { return 22 }

    let today = calendar.startOfDay(for: asOf)
    var checkpoints = Set(yearIncomes.map { calendar.startOfDay(for: $0.date) })
    checkpoints.insert(today)

    var highWaterMark = 22.0
    for checkpoint in checkpoints where checkpoint <= today {
        let rate = instantaneousProjectedRate(yearIncomes: yearIncomes, efkaMonthly: efkaMonthly, asOfDay: checkpoint, year: year, calendar: calendar)
        highWaterMark = max(highWaterMark, rate)
    }
    return highWaterMark
}
