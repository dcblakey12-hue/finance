import Foundation

/// Month-by-month cash-flow projection from current balances, scheduled
/// transactions, and envelope allocations.
///
/// Rules (v1):
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
        options: ForecastOptions,
        accountIds: Set<String>? = nil      // nil = all accounts
    ) -> [ForecastMonth] {
        // `RecurringBill` / `Envelope` / `TransactionRecord` are @MainActor-isolated
        // SwiftData models. Read plain values here via Sendable DTOs to keep
        // this function pure and testable without SwiftData concurrency noise.
        // Payments already entered in the past still count when you start the forecast before them
        // (the starting balance is wound back to that date); skipped ones never happened.
        let todayStart = Calendar.current.startOfDay(for: Date())
        var plainBills: [(name: String, amount: Double, dueDay: Int, category: String, isIncome: Bool)] = []
        var rules: [ScheduleRule?] = []
        for b in bills where b.isActive {
            var r = b.rule
            r.excluded = Set(b.occurrenceLog.compactMap { key, status -> Date? in
                guard let d = OccurrenceLog.date(fromKey: key) else { return nil }
                return (status == .skipped || d >= todayStart) ? d : nil
            })
            if b.isTransfer {
                // Between your own accounts it only matters when exactly one side is in the forecast.
                guard let ids = accountIds, let from = b.fromAccountId, let to = b.toAccountId else { continue }
                let fromIn = ids.contains(from), toIn = ids.contains(to)
                guard fromIn != toIn else { continue }
                plainBills.append((name: b.name, amount: abs(b.amount), dueDay: b.dueDay, category: Categorizer.transfer, isIncome: toIn))
            } else {
                if let ids = accountIds, let a = b.accountId, !ids.contains(a) { continue }
                plainBills.append((name: b.name, amount: abs(b.amount), dueDay: b.dueDay, category: b.category, isIncome: b.isIncome))
            }
            rules.append(r)
        }
        let plainEnvelopes = envelopes.map { (category: $0.category, year: $0.year, month: $0.month, allocated: max(0, $0.allocated)) }
        let plainTx = transactions
            .filter { $0.category != Categorizer.transfer && (accountIds?.contains($0.accountId) ?? true) }
            .map { (date: $0.date, amount: $0.amount) }
        return forecastPlain(bills: plainBills, envelopes: plainEnvelopes, transactions: plainTx, options: options, rules: rules)
    }

    /// Testable core — no SwiftData types.
    static func forecastPlain(
        bills: [(name: String, amount: Double, dueDay: Int, category: String, isIncome: Bool)],
        envelopes: [(category: String, year: Int, month: Int, allocated: Double)],
        transactions: [(date: Date, amount: Double)],
        options: ForecastOptions,
        rules: [ScheduleRule?] = []     // optional repeat pattern per bill (same order); nil = monthly on dueDay
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
            for (i, b) in bills.enumerated() {
                let signed = b.isIncome ? b.amount : -b.amount
                let startOfToday = cal.startOfDay(for: options.from)
                var dues: [Date] = []
                if i < rules.count, let rule = rules[i] {
                    let monthEnd = cal.date(byAdding: DateComponents(month: 1, day: -1), to: monthDate) ?? monthDate
                    dues = rule.dates(from: monthDate, to: monthEnd, calendar: cal)
                } else if let due = cal.date(from: DateComponents(year: y, month: m, day: max(1, min(28, b.dueDay)))) {
                    dues = [due]
                }
                for due in dues {
                    if isCurrentMonth, due < startOfToday { continue }
                    events.append(ForecastEvent(date: due, name: b.name, amount: signed, isIncome: b.isIncome, category: b.category))
                }
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

// MARK: - Dashboard numbers

struct CashPoint: Identifiable, Equatable {
    var date: Date
    var balance: Double
    var id: Date { date }
}

enum DashboardMath {
    /// Projected cash balance day by day from today for `days` days, plus the scheduled and
    /// booked-ahead items that land in that window (only the ones that move the cash balance, or transfers).
    static func projection(days: Int, schedules: [ScheduleItem], balanceToday: Double, cashAccountIds: Set<String>,
                           ledger: [LedgerEntry] = [], today: Date = Date(), calendar: Calendar = .current)
        -> (points: [CashPoint], upcoming: [ForecastEvent]) {
        let start = calendar.startOfDay(for: today)
        guard let end = calendar.date(byAdding: .day, value: max(days, 1), to: start) else { return ([], []) }
        var byDay: [Date: CalendarDay] = [:]
        var month = start
        while month <= end {
            for d in CashCalendar.grid(month: month, schedules: schedules, balanceToday: balanceToday, today: today,
                                       cashAccountIds: cashAccountIds, ledger: ledger, calendar: calendar)
            where d.date >= start && d.date <= end && d.closing != nil {
                byDay[d.date] = d
            }
            guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
            month = next
        }
        let ordered = byDay.values.sorted { $0.date < $1.date }
        let points = ordered.compactMap { d in d.closing.map { CashPoint(date: d.date, balance: $0) } }
        let upcoming = ordered.flatMap(\.events).filter { $0.amount != 0 || $0.isTransfer }
        return (points, upcoming)
    }

    /// Net worth at the end of each of the last `months` months and today, found by undoing
    /// the transactions posted since (future-dated ones are ignored: `currentTotal` is as of today).
    static func netWorthHistory(currentTotal: Double, transactions: [(date: Date, amount: Double)], months: Int,
                                today: Date = Date(), calendar: Calendar = .current) -> [CashPoint] {
        let todayStart = calendar.startOfDay(for: today)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return [] }
        let posted = transactions.filter { $0.date < tomorrow }
        func value(endOfDay d: Date) -> Double {
            guard let after = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: d)) else { return currentTotal }
            return currentTotal - posted.filter { $0.date >= after }.reduce(0) { $0 + $1.amount }
        }
        var out: [CashPoint] = []
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: todayStart)) ?? todayStart
        for back in stride(from: months, through: 1, by: -1) {
            guard let thisStart = calendar.date(byAdding: .month, value: -back + 1, to: monthStart),
                  let end = calendar.date(byAdding: .day, value: -1, to: thisStart) else { continue }
            out.append(CashPoint(date: end, balance: value(endOfDay: end)))
        }
        out.append(CashPoint(date: todayStart, balance: currentTotal))
        return out
    }
}
