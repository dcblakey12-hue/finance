import Foundation
import SwiftData

/// Plain values for creating or editing a scheduled transaction (RecurringBill).
struct ScheduleDraft: Equatable {
    var name: String
    var amount: Double      // always positive; `isIncome` gives the direction
    var dueDay: Int         // 1...28
    var category: String
    var isIncome: Bool
    var isActive: Bool = true
    /// Transfer between two of your accounts (OFX accountIds). `isIncome` is false for these.
    var isTransfer: Bool = false
    var fromAccountId: String? = nil
    var toAccountId: String? = nil
}

enum ScheduleService {
    /// Pre-fill a schedule from an existing transaction: same merchant, amount,
    /// and day of month (clamped to 28, the latest day every month has).
    static func draft(fromName name: String, amount: Double, date: Date, category: String,
                      transferFrom: String? = nil, transferTo: String? = nil,
                      calendar: Calendar = .current) -> ScheduleDraft {
        let isIncome = amount > 0
        let day = calendar.component(.day, from: date)
        let merchant = MerchantNormalizer.key(for: name)
        let displayName = merchant.isEmpty ? name : merchant.capitalized
        if let from = transferFrom, let to = transferTo, from != to {
            return ScheduleDraft(name: displayName, amount: abs(amount), dueDay: min(max(day, 1), 28),
                                 category: Categorizer.transfer, isIncome: false,
                                 isTransfer: true, fromAccountId: from, toAccountId: to)
        }
        let cat: String
        if isIncome { cat = "Income" }
        else if category == Categorizer.uncategorized { cat = "Other" }
        else { cat = category }
        return ScheduleDraft(name: displayName, amount: abs(amount), dueDay: min(max(day, 1), 28),
                             category: cat, isIncome: isIncome)
    }

    /// Create or update a scheduled transaction from a draft, then make sure its category's
    /// budget envelope covers it. Shared by the Mac and iPhone apps.
    @MainActor
    static func save(_ d: ScheduleDraft, existing: RecurringBill?, in context: ModelContext) {
        let category = d.isTransfer ? Categorizer.transfer : (d.isIncome ? "Income" : d.category)
        let kind = d.isTransfer ? "transfer" : (d.isIncome ? "credit" : "debit")
        let from = d.isTransfer ? d.fromAccountId : nil, to = d.isTransfer ? d.toAccountId : nil
        if let s = existing {
            s.name = d.name; s.amount = abs(d.amount); s.dueDay = d.dueDay
            s.category = category; s.kindRaw = kind; s.isActive = d.isActive
            s.fromAccountId = from; s.toAccountId = to
        } else {
            let s = RecurringBill(name: d.name, amount: abs(d.amount), dueDay: d.dueDay, category: category,
                                  isActive: d.isActive, isIncome: d.isIncome && !d.isTransfer)
            s.kindRaw = kind; s.fromAccountId = from; s.toAccountId = to
            context.insert(s)
        }
        try? context.save()
        BudgetSync.apply(in: context)
    }

    /// Schedules in the order they come due: the next payment first, then the rest through the
    /// month, then the ones whose day has already passed (they roll over to next month).
    /// Paused schedules go last.
    @MainActor
    static func orderedByNextDue(_ bills: [RecurringBill], from: Date = Date(), calendar: Calendar = .current) -> [RecurringBill] {
        func next(_ b: RecurringBill) -> Date { nextDueDate(dueDay: b.dueDay, from: from, calendar: calendar) ?? .distantFuture }
        let active = bills.filter(\.isActive).sorted { (next($0), $0.name) < (next($1), $1.name) }
        let paused = bills.filter { !$0.isActive }.sorted { ($0.dueDay, $0.name) < ($1.dueDay, $1.name) }
        return active + paused
    }

    /// Next date on or after `from` (start of day) that falls on `dueDay`.
    static func nextDueDate(dueDay: Int, from: Date, calendar: Calendar = .current) -> Date? {
        let day = min(max(dueDay, 1), 28)
        let today = calendar.startOfDay(for: from)
        for offset in 0..<2 {
            guard let monthDate = calendar.date(byAdding: .month, value: offset, to: today) else { continue }
            var comps = calendar.dateComponents([.year, .month], from: monthDate)
            comps.day = day
            if let due = calendar.date(from: comps), due >= today { return due }
        }
        return nil
    }
}

// MARK: - Calendar projection

/// A scheduled transaction as plain values (amount is signed: + income, - expense).
struct ScheduleItem: Equatable {
    var name: String
    var amount: Double
    var dueDay: Int
    var category: String
    /// Between two of your accounts: `amount` is then its positive size.
    var isTransfer: Bool = false
    var fromAccountId: String? = nil
    var toAccountId: String? = nil
    var detail: String? = nil      // e.g. "Checking → Visa"
    var isIncome: Bool { !isTransfer && amount > 0 }
}

struct CalendarDay: Identifiable {
    let date: Date
    let inMonth: Bool
    let events: [ForecastEvent]
    /// Projected balance at the end of this day. Nil for days before today.
    let closing: Double?
    var id: Date { date }
    var net: Double { events.reduce(0) { $0 + $1.amount } }
}

struct CalendarMonthSummary: Equatable {
    var income: Double
    var expenses: Double
    var low: Double?       // lowest end-of-day balance in the month
    var lowDate: Date?     // the (first) day that low occurs
    var closing: Double?   // balance at the end of the month
}

enum CashCalendar {
    static func clampedDay(_ d: Int) -> Int { min(max(d, 1), 28) }

    /// Month grid (whole weeks) with scheduled events on each day and a running balance.
    /// From today on, the balance starts at `balanceToday` and applies scheduled items.
    /// Earlier days are worked backward from `balanceToday` using `actualNetByDay` (the
    /// net of real transactions per start-of-day); with none supplied they have no balance.
    static func grid(month: Date, schedules: [ScheduleItem], balanceToday: Double, today: Date = Date(),
                     actualNetByDay: [Date: Double]? = nil, cashAccountIds: Set<String>? = nil,
                     calendar: Calendar = .current) -> [CalendarDay] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let first = monthInterval.start
        let daysInMonth = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let rows = Int((Double(leading + daysInMonth) / 7).rounded(.up))
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: first) else { return [] }
        let todayStart = calendar.startOfDay(for: today)

        func date(_ offset: Int, from start: Date) -> Date { calendar.date(byAdding: .day, value: offset, to: start)! }
        let totalDays = rows * 7
        let gridEnd = date(totalDays - 1, from: gridStart)

        // Running balance from today (or the grid start, if later) forward.
        var running = balanceToday
        var closingByDay: [Date: Double] = [:]
        if gridEnd >= todayStart {
            var cursor = todayStart
            let limit = calendar.dateComponents([.day], from: todayStart, to: gridEnd).day ?? 0
            for _ in 0...min(limit, 1500) {
                running += events(on: cursor, schedules: schedules, cashAccountIds: cashAccountIds, calendar: calendar).reduce(0) { $0 + $1.amount }
                closingByDay[cursor] = running
                cursor = date(1, from: cursor)
            }
        }
        // Past days: balance at the end of day d = balanceToday minus real activity after d, through today.
        if let actual = actualNetByDay, gridStart < todayStart {
            var back = balanceToday - (actual[todayStart] ?? 0)   // end of yesterday
            var cursor = date(-1, from: todayStart)
            let limit = min(calendar.dateComponents([.day], from: gridStart, to: todayStart).day ?? 0, 1500)
            for _ in 0..<limit {
                closingByDay[cursor] = back
                back -= actual[cursor] ?? 0
                cursor = date(-1, from: cursor)
            }
        }
        return (0..<totalDays).map { i in
            let d = date(i, from: gridStart)
            return CalendarDay(date: d, inMonth: calendar.isDate(d, equalTo: first, toGranularity: .month),
                               events: events(on: d, schedules: schedules, cashAccountIds: cashAccountIds, calendar: calendar),
                               closing: closingByDay[d])
        }
    }

    /// How a scheduled item changes the balance of the accounts being tracked (`cashAccountIds`).
    /// A transfer only matters when exactly one side is tracked: money leaving or arriving.
    static func balanceEffect(of item: ScheduleItem, cashAccountIds: Set<String>?) -> Double {
        guard item.isTransfer else { return item.amount }
        guard let cash = cashAccountIds, let from = item.fromAccountId, let to = item.toAccountId else { return 0 }
        let size = abs(item.amount)
        switch (cash.contains(from), cash.contains(to)) {
        case (true, false): return -size
        case (false, true): return size
        default: return 0
        }
    }

    static func events(on date: Date, schedules: [ScheduleItem], cashAccountIds: Set<String>? = nil,
                       calendar: Calendar = .current) -> [ForecastEvent] {
        let day = calendar.component(.day, from: date)
        return schedules.filter { clampedDay($0.dueDay) == day }
            .sorted { $0.name < $1.name }
            .map { ForecastEvent(date: date, name: $0.name,
                                 amount: balanceEffect(of: $0, cashAccountIds: cashAccountIds),
                                 isIncome: $0.isIncome, category: $0.category,
                                 isTransfer: $0.isTransfer, gross: abs($0.amount), detail: $0.detail) }
    }

    /// Totals for the days that fall inside the month. Income/expenses count only today onward
    /// (earlier days are in the past and already in your transactions).
    static func summary(of days: [CalendarDay], today: Date = Date(), calendar: Calendar = .current) -> CalendarMonthSummary {
        let todayStart = calendar.startOfDay(for: today)
        let inMonth = days.filter(\.inMonth)
        let upcoming = inMonth.filter { $0.date >= todayStart }
        let lowDay = inMonth.filter { $0.closing != nil }.min { ($0.closing ?? 0) < ($1.closing ?? 0) }
        return CalendarMonthSummary(
            income: upcoming.flatMap(\.events).filter { !$0.isTransfer && $0.amount > 0 }.reduce(0) { $0 + $1.amount },
            expenses: upcoming.flatMap(\.events).filter { !$0.isTransfer && $0.amount < 0 }.reduce(0) { $0 + abs($1.amount) },
            low: lowDay?.closing, lowDate: lowDay?.date, closing: inMonth.last?.closing)
    }
}

extension RecurringBill {
    /// Plain value for projections. `accountNames` (OFX accountId → name) labels transfers.
    func item(accountNames: [String: String] = [:]) -> ScheduleItem {
        var detail: String?
        if isTransfer, let f = fromAccountId, let t = toAccountId {
            detail = "\(accountNames[f] ?? "?") → \(accountNames[t] ?? "?")"
        }
        return ScheduleItem(name: name, amount: signedAmount, dueDay: dueDay, category: category,
                            isTransfer: isTransfer, fromAccountId: fromAccountId, toAccountId: toAccountId, detail: detail)
    }
    var item: ScheduleItem { item() }
}

// MARK: - Scheduled transactions feed the budget

enum BudgetSync {
    /// Monthly scheduled total per expense category (active bills only).
    static func scheduledExpenses(_ items: [ScheduleItem]) -> [String: Double] {
        var out: [String: Double] = [:]
        for i in items where !i.isIncome && !i.isTransfer { out[i.category, default: 0] += abs(i.amount) }
        return out
    }
    static func scheduledIncome(_ items: [ScheduleItem]) -> Double {
        items.filter(\.isIncome).reduce(0) { $0 + $1.amount }
    }

    /// Make sure every category with scheduled bills has an envelope at least as big as
    /// those bills, for this month and any later month that already has one. Never lowers
    /// an allocation you set higher. Returns the number of envelopes created or raised.
    @MainActor @discardableResult
    static func apply(in context: ModelContext, now: Date = Date(), calendar: Calendar = .current) -> Int {
        let bills = ((try? context.fetch(FetchDescriptor<RecurringBill>())) ?? []).filter(\.isActive)
        let required = scheduledExpenses(bills.map(\.item))
        guard !required.isEmpty else { return 0 }
        let year = calendar.component(.year, from: now), month = calendar.component(.month, from: now)
        let envelopes = (try? context.fetch(FetchDescriptor<Envelope>())) ?? []
        var changed = 0
        for (category, total) in required {
            let mine = envelopes.filter { $0.category == category }
            if let current = mine.first(where: { $0.year == year && $0.month == month }) {
                if current.allocated < total { current.allocated = total; changed += 1 }
            } else {
                context.insert(Envelope(category: category, year: year, month: month, allocated: total)); changed += 1
            }
            for e in mine where (e.year, e.month) > (year, month) && e.allocated < total {
                e.allocated = total; changed += 1
            }
        }
        try? context.save()
        return changed
    }
}
