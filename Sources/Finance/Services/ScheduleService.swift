import Foundation
import SwiftData

/// How often a scheduled transaction repeats.
enum ScheduleFrequency: String, CaseIterable, Identifiable {
    case monthly, semimonthly, weekly, biweekly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .monthly: return "Monthly"
        case .semimonthly: return "Twice a month"
        case .weekly: return "Every week"
        case .biweekly: return "Every 2 weeks"
        }
    }
}

/// When a scheduled transaction lands. Monthly and twice-a-month use days of the month
/// (capped at the 28th); weekly and every-2-weeks repeat from `anchor` (any date it lands on).
struct ScheduleRule: Equatable {
    var frequency: ScheduleFrequency = .monthly
    var dueDay: Int = 1
    var secondDay: Int = 15
    var anchor: Date? = nil
    /// Specific days (start of day) to leave out, e.g. payments already entered or skipped.
    var excluded: Set<Date> = []

    static let fallbackAnchor = Date(timeIntervalSinceReferenceDate: 0)

    private static func clamp(_ d: Int) -> Int { min(max(d, 1), 28) }

    func occurs(on date: Date, calendar: Calendar = .current) -> Bool {
        if !excluded.isEmpty, excluded.contains(calendar.startOfDay(for: date)) { return false }
        switch frequency {
        case .monthly:
            return calendar.component(.day, from: date) == Self.clamp(dueDay)
        case .semimonthly:
            let d = calendar.component(.day, from: date)
            return d == Self.clamp(dueDay) || d == Self.clamp(secondDay)
        case .weekly, .biweekly:
            let start = calendar.startOfDay(for: anchor ?? Self.fallbackAnchor)
            let days = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? 1
            return days % (frequency == .weekly ? 7 : 14) == 0
        }
    }

    /// Every date from `from` through `to` (start-of-day, inclusive) on which it lands.
    func dates(from: Date, to: Date, calendar: Calendar = .current) -> [Date] {
        var out: [Date] = []
        var day = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        var guardCount = 0
        while day <= end, guardCount < 4000 {
            if occurs(on: day, calendar: calendar) { out.append(day) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next; guardCount += 1
        }
        return out
    }

    /// First date on or after `from` it lands on.
    func nextDate(from: Date, calendar: Calendar = .current) -> Date? {
        var day = calendar.startOfDay(for: from)
        for _ in 0..<400 {
            if occurs(on: day, calendar: calendar) { return day }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    /// Average number of times per month, for monthly totals and budgets.
    var monthlyFactor: Double {
        switch frequency {
        case .monthly: return 1
        case .semimonthly: return 2
        case .weekly: return 52.0 / 12.0
        case .biweekly: return 26.0 / 12.0
        }
    }

    func summary(calendar: Calendar = .current) -> String {
        func ordinal(_ n: Int) -> String {
            let f = NumberFormatter(); f.numberStyle = .ordinal
            return f.string(from: NSNumber(value: n)) ?? "\(n)"
        }
        func weekdayName() -> String {
            let d = anchor ?? Self.fallbackAnchor
            let i = calendar.component(.weekday, from: d) - 1
            return calendar.weekdaySymbols[i]
        }
        switch frequency {
        case .monthly: return "Monthly on the \(ordinal(Self.clamp(dueDay)))"
        case .semimonthly:
            let a = Self.clamp(dueDay), b = Self.clamp(secondDay)
            return "\(ordinal(min(a, b))) & \(ordinal(max(a, b))) of the month"
        case .weekly: return "Every \(weekdayName())"
        case .biweekly: return "Every other \(weekdayName())"
        }
    }
}

enum OccurrenceStatus: String { case entered = "e", skipped = "s" }

/// Text format for `RecurringBill.occurrenceLogRaw`.
enum OccurrenceLog {
    static func key(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func date(fromKey k: String, calendar: Calendar = .current) -> Date? {
        let p = k.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])).map { calendar.startOfDay(for: $0) }
    }
    static func parse(_ raw: String) -> [String: OccurrenceStatus] {
        var out: [String: OccurrenceStatus] = [:]
        for part in raw.split(separator: ",") {
            let bits = part.split(separator: "|")
            if bits.count == 2, let s = OccurrenceStatus(rawValue: String(bits[1])) { out[String(bits[0])] = s }
        }
        return out
    }
    static func serialize(_ log: [String: OccurrenceStatus], keepingSince cutoff: Date? = nil, calendar: Calendar = .current) -> String {
        log.filter { k, _ in
            guard let cutoff, let d = date(fromKey: k, calendar: calendar) else { return true }
            return d >= calendar.startOfDay(for: cutoff)
        }
        .sorted { $0.key < $1.key }
        .map { "\($0.key)|\($0.value.rawValue)" }
        .joined(separator: ",")
    }
}

/// A scheduled payment whose date has passed without being entered or skipped.
struct OverdueItem: Identifiable {
    let bill: RecurringBill
    let date: Date
    var id: String { "\(bill.id.uuidString)|\(Int(date.timeIntervalSince1970))" }
    func daysLate(today: Date = Date(), calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: today)).day ?? 0
    }
}

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
    /// Repeat pattern. For weekly / every-2-weeks, `startDate` is a date it lands on.
    var frequency: ScheduleFrequency = .monthly
    var secondDay: Int = 15
    var startDate: Date? = nil
    /// The account (OFX accountId) a bill is paid from or a payday arrives in. Not used for transfers.
    var accountId: String? = nil

    var rule: ScheduleRule { ScheduleRule(frequency: frequency, dueDay: dueDay, secondDay: secondDay, anchor: startDate) }
    /// Valid when the chosen pattern is complete (twice a month needs two different days).
    var scheduleIsValid: Bool { frequency != .semimonthly || min(max(dueDay, 1), 28) != min(max(secondDay, 1), 28) }
}

enum ScheduleService {
    /// Pre-fill a schedule from an existing transaction: same merchant, amount,
    /// and day of month (clamped to 28, the latest day every month has).
    static func draft(fromName name: String, amount: Double, date: Date, category: String,
                      accountId: String? = nil,
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
        var d = ScheduleDraft(name: displayName, amount: abs(amount), dueDay: min(max(day, 1), 28),
                              category: cat, isIncome: isIncome)
        d.accountId = accountId
        return d
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
            s.frequencyRaw = d.frequency.rawValue; s.secondDay = d.secondDay; s.anchorDate = d.startDate
            s.accountId = d.isTransfer ? nil : d.accountId
        } else {
            let s = RecurringBill(name: d.name, amount: abs(d.amount), dueDay: d.dueDay, category: category,
                                  isActive: d.isActive, isIncome: d.isIncome && !d.isTransfer)
            s.kindRaw = kind; s.fromAccountId = from; s.toAccountId = to
            s.frequencyRaw = d.frequency.rawValue; s.secondDay = d.secondDay; s.anchorDate = d.startDate
            s.trackedSince = Calendar.current.startOfDay(for: Date())
            s.accountId = d.isTransfer ? nil : d.accountId
            context.insert(s)
        }
        try? context.save()
        BudgetSync.apply(in: context)
    }

    /// Enter the next payment as a real transaction (amount and date may differ from the schedule),
    /// then count that occurrence as done so it isn't projected again. A transfer creates both
    /// sides, linked. Returns false if the needed account(s) are missing.
    @MainActor @discardableResult
    static func enter(_ bill: RecurringBill, occurrence: Date, postedOn: Date, amount: Double,
                      account: Account?, from: Account? = nil, to: Account? = nil,
                      in context: ModelContext) -> Bool {
        let size = abs(amount)
        if bill.isTransfer {
            guard let from, let to, from.accountId != to.accountId else { return false }
            let out = ManualTransactionService.add(to: from, date: postedOn, name: bill.name, amount: -size,
                                                   category: Categorizer.transfer, memo: "Scheduled transfer", in: context)
            let inn = ManualTransactionService.add(to: to, date: postedOn, name: bill.name, amount: size,
                                                   category: Categorizer.transfer, memo: "Scheduled transfer", in: context)
            out.transferPeerId = inn.id; inn.transferPeerId = out.id
            bill.fromAccountId = from.accountId; bill.toAccountId = to.accountId
        } else {
            guard let account else { return false }
            ManualTransactionService.add(to: account, date: postedOn, name: bill.name,
                                         amount: bill.isIncome ? size : -size,
                                         category: bill.category, memo: "Scheduled", in: context)
            bill.accountId = account.accountId
        }
        bill.lastPaid = postedOn
        bill.record(.entered, on: occurrence)
        try? context.save()
        return true
    }

    /// Payments that came due after a schedule started being tracked (at most 90 days back) and
    /// were neither entered nor skipped, oldest first. Paused schedules are ignored.
    @MainActor
    static func overdue(_ bills: [RecurringBill], today: Date = Date(), calendar: Calendar = .current) -> [OverdueItem] {
        let todayStart = calendar.startOfDay(for: today)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart),
              let floor = calendar.date(byAdding: .day, value: -90, to: todayStart) else { return [] }
        var out: [OverdueItem] = []
        for b in bills where b.isActive {
            guard let since = b.trackedSince else { continue }
            let from = max(calendar.startOfDay(for: since), floor)
            guard from <= yesterday else { continue }
            for d in b.rule.dates(from: from, to: yesterday, calendar: calendar) { out.append(OverdueItem(bill: b, date: d)) }
        }
        return out.sorted { ($0.date, $0.bill.name) < ($1.date, $1.bill.name) }
    }

    /// Existing schedules start being tracked today, so the first run of the overdue list doesn't
    /// dredge up payments from before it existed.
    @MainActor
    static func ensureTracking(in context: ModelContext, now: Date = Date(), calendar: Calendar = .current) {
        let bills = (try? context.fetch(FetchDescriptor<RecurringBill>())) ?? []
        var changed = false
        for b in bills where b.trackedSince == nil { b.trackedSince = calendar.startOfDay(for: now); changed = true }
        if changed { try? context.save() }
    }

    /// After an import: mark overdue payments as entered when the bank reported a matching
    /// transaction (same direction, amount within 15%, within 5 days of the due date, in the
    /// schedule's usual account if it has one). Each new transaction resolves at most one payment.
    @MainActor @discardableResult
    static func autoResolve(with newTransactions: [TransactionRecord], in context: ModelContext,
                            today: Date = Date(), calendar: Calendar = .current) -> Int {
        let bills = ((try? context.fetch(FetchDescriptor<RecurringBill>())) ?? []).filter { !$0.isTransfer }
        var used = Set<UUID>()
        var resolved = 0
        for item in overdue(bills, today: today, calendar: calendar) {
            let b = item.bill
            let size = abs(b.amount)
            func gap(_ t: TransactionRecord) -> (Double, Int) {
                (abs(abs(t.amount) - size),
                 abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: t.date), to: item.date).day ?? 99))
            }
            let match = newTransactions
                .filter { t in
                    !used.contains(t.id) && (t.amount > 0) == b.isIncome &&
                    (b.accountId == nil || b.accountId == t.accountId) &&
                    gap(t).0 <= max(1, size * 0.15) && gap(t).1 <= 5
                }
                .min { gap($0) < gap($1) }
            if let match {
                used.insert(match.id)
                b.record(.entered, on: item.date, now: today, calendar: calendar)
                resolved += 1
            }
        }
        if resolved > 0 { try? context.save() }
        return resolved
    }

    /// Leave this payment out: no transaction, and the schedule moves on to the next one.
    @MainActor
    static func skip(_ bill: RecurringBill, occurrence: Date, in context: ModelContext) {
        bill.record(.skipped, on: occurrence)
        try? context.save()
    }

    /// Make `newDate` the next due date. Payments before it are skipped; then the schedule is moved:
    /// weekly / every-2-weeks repeat from it, monthly uses its day of the month (capped at the 28th),
    /// twice-a-month swaps it in for whichever of its two days is due next.
    @MainActor
    static func setNextDue(_ bill: RecurringBill, to newDate: Date, today: Date = Date(),
                           calendar: Calendar = .current, in context: ModelContext) {
        let target = calendar.startOfDay(for: newDate)
        // Earlier moves may have skipped upcoming payments; forget those so the date can move back too.
        let todayStart = calendar.startOfDay(for: today)
        var log = bill.occurrenceLog
        for (k, status) in log where status == .skipped {
            if let d = OccurrenceLog.date(fromKey: k, calendar: calendar), d >= todayStart { log[k] = nil }
        }
        bill.occurrenceLogRaw = OccurrenceLog.serialize(log, calendar: calendar)
        var guardCount = 0
        while guardCount < 60, let next = bill.rule.nextDate(from: today, calendar: calendar), next < target {
            bill.record(.skipped, on: next)
            guardCount += 1
        }
        let day = min(calendar.component(.day, from: target), 28)
        switch bill.rule.frequency {
        case .weekly, .biweekly:
            bill.anchorDate = target
        case .monthly:
            bill.dueDay = day
        case .semimonthly:
            // Replace the day that was due next (the first of the two if it can't be told).
            let next = bill.rule.nextDate(from: today, calendar: calendar)
            let nextDay = next.map { calendar.component(.day, from: $0) }
            if nextDay == bill.secondDay { bill.secondDay = day } else { bill.dueDay = day }
        }
        try? context.save()
    }

    /// Schedules in the order they come due: the next payment first, then the rest through the
    /// month, then the ones whose day has already passed (they roll over to next month).
    /// Paused schedules go last.
    @MainActor
    static func orderedByNextDue(_ bills: [RecurringBill], from: Date = Date(), calendar: Calendar = .current) -> [RecurringBill] {
        func next(_ b: RecurringBill) -> Date { b.rule.nextDate(from: from, calendar: calendar) ?? .distantFuture }
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
    var frequency: ScheduleFrequency = .monthly
    var secondDay: Int = 15
    var anchor: Date? = nil
    var excluded: Set<Date> = []
    /// The account a bill/payday belongs to (nil = unspecified).
    var accountId: String? = nil
    /// The RecurringBill this was built from (nil in tests / ad-hoc items).
    var billId: UUID? = nil
    var rule: ScheduleRule { ScheduleRule(frequency: frequency, dueDay: dueDay, secondDay: secondDay, anchor: anchor, excluded: excluded) }
    /// Average amount per month (signed), counting every repeat.
    var monthlyAmount: Double { amount * rule.monthlyFactor }
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

/// A transaction already in the ledger, for showing future-dated ones on the calendar.
struct LedgerEntry {
    var date: Date
    var name: String
    var amount: Double          // signed
    var accountId: String
    var category: String = ""
    var isTransfer: Bool = false
}

enum CashCalendar {
    static func clampedDay(_ d: Int) -> Int { min(max(d, 1), 28) }

    /// Month grid (whole weeks) with scheduled events on each day and a running balance.
    /// From today on, the balance starts at `balanceToday` and applies scheduled items.
    /// Earlier days are worked backward from `balanceToday` using `actualNetByDay` (the
    /// net of real transactions per start-of-day); with none supplied they have no balance.
    static func grid(month: Date, schedules: [ScheduleItem], balanceToday: Double, today: Date = Date(),
                     actualNetByDay: [Date: Double]? = nil, cashAccountIds: Set<String>? = nil,
                     ledger: [LedgerEntry] = [], calendar: Calendar = .current) -> [CalendarDay] {
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

        // `balanceToday` is the balance as of today (future-dated entries not included); the
        // ones already in the ledger land on their own day.
        let futureLedger = ledger.filter { calendar.startOfDay(for: $0.date) > todayStart }
        func ledgerEvents(on day: Date) -> [ForecastEvent] {
            futureLedger.filter { calendar.isDate($0.date, inSameDayAs: day) && (cashAccountIds?.contains($0.accountId) ?? true) }
                .sorted { $0.name < $1.name }
                .map { ForecastEvent(date: day, name: $0.name, amount: $0.amount, isIncome: $0.amount > 0 && !$0.isTransfer,
                                     category: $0.category, isTransfer: $0.isTransfer, gross: abs($0.amount), detail: "Already entered") }
        }

        // Running balance from today (or the grid start, if later) forward.
        var running = balanceToday
        var closingByDay: [Date: Double] = [:]
        if gridEnd >= todayStart {
            var cursor = todayStart
            let limit = calendar.dateComponents([.day], from: todayStart, to: gridEnd).day ?? 0
            for _ in 0...min(limit, 1500) {
                running += (events(on: cursor, schedules: schedules, cashAccountIds: cashAccountIds, calendar: calendar) + ledgerEvents(on: cursor)).reduce(0) { $0 + $1.amount }
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
                               events: events(on: d, schedules: schedules, cashAccountIds: cashAccountIds, calendar: calendar) + ledgerEvents(on: d),
                               closing: closingByDay[d])
        }
    }

    /// How a scheduled item changes the balance of the accounts being tracked (`cashAccountIds`).
    /// A transfer only matters when exactly one side is tracked: money leaving or arriving.
    static func balanceEffect(of item: ScheduleItem, cashAccountIds: Set<String>?) -> Double {
        guard item.isTransfer else {
            // A bill or payday only moves the tracked balance if its account is one of the tracked ones.
            if let acct = item.accountId, let cash = cashAccountIds, !cash.contains(acct) { return 0 }
            return item.amount
        }
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
        return schedules.filter { $0.rule.occurs(on: date, calendar: calendar) }
            .sorted { $0.name < $1.name }
            .map { ForecastEvent(date: date, name: $0.name,
                                 amount: balanceEffect(of: $0, cashAccountIds: cashAccountIds),
                                 isIncome: $0.isIncome, category: $0.category,
                                 isTransfer: $0.isTransfer, gross: abs($0.amount), detail: $0.detail, billId: $0.billId) }
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
                            isTransfer: isTransfer, fromAccountId: fromAccountId, toAccountId: toAccountId, detail: detail,
                            frequency: rule.frequency, secondDay: secondDay, anchor: anchorDate, excluded: rule.excluded,
                            accountId: accountId, billId: id)
    }
    var item: ScheduleItem { item() }

    var rule: ScheduleRule {
        ScheduleRule(frequency: ScheduleFrequency(rawValue: frequencyRaw) ?? .monthly,
                     dueDay: dueDay, secondDay: secondDay, anchor: anchorDate,
                     excluded: Set(occurrenceLog.keys.compactMap { OccurrenceLog.date(fromKey: $0) }))
    }

    /// Dealt-with occurrences by day key ("yyyy-MM-dd").
    var occurrenceLog: [String: OccurrenceStatus] { OccurrenceLog.parse(occurrenceLogRaw) }

    /// Mark the occurrence on `date` as entered or skipped (older than ~4 months are dropped).
    func record(_ status: OccurrenceStatus, on date: Date, now: Date = Date(), calendar: Calendar = .current) {
        var log = occurrenceLog
        log[OccurrenceLog.key(date, calendar: calendar)] = status
        occurrenceLogRaw = OccurrenceLog.serialize(log, keepingSince: calendar.date(byAdding: .day, value: -120, to: now), calendar: calendar)
    }
    /// Average amount per month in absolute terms, counting every repeat.
    var monthlySize: Double { abs(amount) * rule.monthlyFactor }
}

// MARK: - Scheduled transactions feed the budget

enum BudgetSync {
    /// Monthly scheduled total per expense category (active bills only).
    static func scheduledExpenses(_ items: [ScheduleItem]) -> [String: Double] {
        var out: [String: Double] = [:]
        for i in items where !i.isIncome && !i.isTransfer { out[i.category, default: 0] += abs(i.monthlyAmount) }
        return out
    }
    static func scheduledIncome(_ items: [ScheduleItem]) -> Double {
        items.filter(\.isIncome).reduce(0) { $0 + $1.monthlyAmount }
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
