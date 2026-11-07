import Foundation

/// Month-by-month cash-flow projection from current balances, scheduled
/// transactions, and envelope allocations.
///
/// Rules (v1, monthly schedules only):
/// - Starting balance is supplied by the caller (defaults to net worth in UI).
/// - Every active RecurringBill contributes once per month on its `dueDay`.
///   Income (`kindRaw == "credit"`) is +, expenses are −.
/// - Current month only counts events still ahead (`dueDate >= today`) so you
///   don't double-subtract bills already paid. Envelope remainder for the
///   current month is pro-rated by remaining days.
/// - Envelopes are included as variable spend *after* same-category bills so
///   Rent ($1,200) inside a Housing envelope ($1,500) forecasts $300 more
///   variable, not $2,700. If no envelope exists for a future month, the most
///   recent defined month's allocations are carried forward; if no envelope
///   ever exists and `fallbackAverageVariable` is on, the trailing 3-month
///   average expense is used (floored at zero, minus scheduled bills).
/// - If no income schedules exist and `inferIncomeFromHistory` is on, the
///   trailing 3-month average income is used as an estimate. Once you schedule
///   paydays, the estimate is ignored.
enum CashFlowForecastService: Sendable {
    static func forecast(
        bills: [RecurringBill],
        envelopes: [Envelope],
        transactions: [TransactionRecord],
        options: ForecastOptions
    ) -> [ForecastMonth] {
        // `RecurringBill` / `Envelope` / `TransactionRecord` are @MainActor-isolated
        // SwiftData models. Read plain values here via Sendable DTOs to keep
        // this function pure and testable without SwiftData concurrency noise.
        let active = bills.filter { $0.isActive }
        let plainBills = active.map { (name: $0.name, amount: abs($0.amount), dueDay: $0.dueDay, category: $0.category, isIncome: $0.isIncome) }
        let plainEnvelopes = envelopes.map { (category: $0.category, year: $0.year, month: $0.month, allocated: max(0, $0.allocated)) }
        let plainTx = transactions.filter { $0.category != Categorizer.transfer }.map { (date: $0.date, amount: $0.amount) }
        return forecastPlain(bills: plainBills, envelopes: plainEnvelopes, transactions: plainTx, options: options)
    }

    /// Testable core — no SwiftData types.
    static func forecastPlain(
        bills: [(name: String, amount: Double, dueDay: Int, category: String, isIncome: Bool)],
        envelopes: [(category: String, year: Int, month: Int, allocated: Double)],
        transactions: [(date: Date, amount: Double)],
        options: ForecastOptions
    ) -> [ForecastMonth] {
        let cal = Calendar.current
        let firstMonth = cal.date(from: cal.dateComponents([.year, .month], from: options.from))!
        let monthCount = max(1, options.months)

        let trailingIncomeAvg = trailingMonthlyAverage(transactions: transactions, from: options.from, isIncome: true)
        let trailingExpenseAvg = trailingMonthlyAverage(transactions: transactions, from: options.from, isIncome: false)
        let hasIncomeSchedules = bills.contains(where: { $0.isIncome })

        // Map year-month -> [category: allocated]
        var byYearMonth: [String: [String: Double]] = [:]
        for e in envelopes {
            let key = "\(e.year)-\(e.month)"
            byYearMonth[key, default: [:]][e.category, default: 0] += e.allocated
        }
        // Most recent defined envelope template (<= last forecast month) to carry forward.
        let templateSource = byYearMonth.keys
            .map { key -> (year: Int, month: Int, allocations: [String: Double])? in
                let parts = key.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 2, let allocs = byYearMonth[key] else { return nil }
                return (parts[0], parts[1], allocs)
            }
            .compactMap { $0 }
            .sorted { ($0.year, $0.month) < ($1.year, $1.month) }
            .last

        var months: [ForecastMonth] = []
        var balance = options.startingBalance

        for idx in 0..<monthCount {
            let monthDate = cal.date(byAdding: .month, value: idx, to: firstMonth) ?? firstMonth
            let y = cal.component(.year, from: monthDate)
            let m = cal.component(.month, from: monthDate)
            let isCurrentMonth = idx == 0

            // Build events for this month (current month: remaining only)
            var events: [ForecastEvent] = []
            for b in bills {
                guard let due = cal.date(from: DateComponents(year: y, month: m, day: max(1, min(28, b.dueDay)))) else { continue }
                if isCurrentMonth, due < cal.startOfDay(for: options.from) { continue }
                let signed = b.isIncome ? b.amount : -b.amount
                events.append(ForecastEvent(date: due, name: b.name, amount: signed, isIncome: b.isIncome, category: b.category))
            }
            // Inferred income when user hasn't scheduled any payday yet.
            let inferredIncome: Double
            if !hasIncomeSchedules, options.inferIncomeFromHistory, trailingIncomeAvg > 0 {
                inferredIncome = trailingIncomeAvg
                if !isCurrentMonth {
                    let payDate = cal.date(from: DateComponents(year: y, month: m, day: 15)) ?? monthDate
                    events.append(ForecastEvent(date: payDate, name: "Estimated income (avg)", amount: inferredIncome, isIncome: true, category: "Income"))
                } else {
                    // Only add estimate if its synthetic day is still ahead.
                    let payDate = cal.date(from: DateComponents(year: y, month: m, day: 15)) ?? monthDate
                    if payDate >= cal.startOfDay(for: options.from) {
                        events.append(ForecastEvent(date: payDate, name: "Estimated income (avg)", amount: inferredIncome, isIncome: true, category: "Income"))
                    }
                }
            } else { inferredIncome = 0 }

            events.sort { $0.date < $1.date }
            let income = events.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
            let scheduledExpenses = events.filter { $0.amount < 0 }.reduce(0) { $0 + abs($1.amount) }

            // Envelope variable remainder (exclude same-category bills to avoid double count).
            var envelopeSpend = 0.0
            if options.includeEnvelopes {
                let thisKey = "\(y)-\(m)"
                let allocations: [String: Double]?
                if let allocs = byYearMonth[thisKey] { allocations = allocs }
                else { allocations = templateSource?.allocations }
                if let allocs = allocations {
                    // Sum bills per category this month.
                    var billsByCat: [String: Double] = [:]
                    for e in events where !e.isIncome { billsByCat[e.category, default: 0] += abs(e.amount) }
                    var remainder = 0.0
                    for (cat, allocated) in allocs {
                        let billed = billsByCat[cat] ?? 0
                        remainder += max(0, allocated - billed)
                    }
                    // Bills in categories without an envelope were already counted as scheduled;
                    // their remainder is 0, so no double count.
                    if isCurrentMonth {
                        let totalDays = cal.range(of: .day, in: .month, for: monthDate)?.count ?? 30
                        let remainingDays = max(0, totalDays - cal.component(.day, from: options.from) + 1)
                        remainder *= Double(remainingDays) / Double(totalDays)
                    }
                    envelopeSpend = remainder
                } else if options.fallbackAverageVariable, trailingExpenseAvg > 0 {
                    envelopeSpend = max(0, trailingExpenseAvg - scheduledExpenses)
                    if isCurrentMonth {
                        let totalDays = cal.range(of: .day, in: .month, for: monthDate)?.count ?? 30
                        let remainingDays = max(0, totalDays - cal.component(.day, from: options.from) + 1)
                        envelopeSpend *= Double(remainingDays) / Double(totalDays)
                    }
                }
            }

            let totalExpenses = scheduledExpenses + envelopeSpend
            let net = income - totalExpenses

            // Intra-month low: walk events in date order.
            var running = balance
            var low = balance
            for e in events {
                running += e.amount
                low = min(low, running)
            }
            // Envelope spend is spread across the month; approximate its worst
            // intra-month effect as a gradual drain — use closing as floor.
            let closing = balance + net
            low = min(low, closing)

            months.append(ForecastMonth(
                monthDate: monthDate, openingBalance: balance, scheduledIncome: income,
                scheduledExpenses: scheduledExpenses, envelopeSpend: envelopeSpend,
                net: net, closingBalance: closing, intraMonthLow: low, events: events
            ))
            balance = closing
        }
        return months
    }

    private static func trailingMonthlyAverage(transactions: [(date: Date, amount: Double)], from fromDate: Date, isIncome: Bool) -> Double {
        let cal = Calendar.current
        // Sum last 3 complete calendar months (excluding current partial month).
        var sums: [Double] = []
        for back in 1...3 {
            guard let ref = cal.date(byAdding: .month, value: -back, to: fromDate) else { continue }
            let y = cal.component(.year, from: ref), m = cal.component(.month, from: ref)
            let total = transactions.filter { tx in
                cal.component(.year, from: tx.date) == y && cal.component(.month, from: tx.date) == m &&
                (isIncome ? tx.amount > 0 : tx.amount < 0)
            }.reduce(0) { $0 + abs($1.amount) }
            sums.append(total)
        }
        guard !sums.isEmpty else { return 0 }
        return sums.reduce(0, +) / Double(sums.count)
    }
}
