import Foundation
import SwiftData
import EventKit

// MARK: - Import

@MainActor
final class TransactionImportService {
    func importParsed(_ parsed: ParsedOFXFile, into context: ModelContext) -> (inserted: Int, skipped: Int) {
        // Upsert account
        let acctId = parsed.accountId
        let account: Account
        let acctDesc = FetchDescriptor<Account>(predicate: #Predicate { $0.accountId == acctId })
        if let existing = try? context.fetch(acctDesc).first {
            account = existing
            if let bal = parsed.balance { account.balance = bal }
        } else {
            account = Account(name: parsed.accountName, type: parsed.isCreditCard ? .creditCard : .checking, accountId: acctId, bankName: parsed.bankId, balance: parsed.balance ?? 0)
            context.insert(account)
        }

        let existingRecords: [TransactionRecord] = (try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? []
        let existingFitIds = Set(existingRecords.map { "\($0.accountId)|\($0.fitid)" })
        let rules = CategorizationService.ruleMap(in: context)
        let allowed = CategoryService.allowedBuiltIns(in: context)
        var inserted = 0, skipped = 0
        for t in parsed.transactions {
            let key = "\(acctId)|\(t.fitid)"
            if existingFitIds.contains(key) { skipped += 1; continue }
            let category = Categorizer.category(forName: t.name, rules: rules, allowed: allowed) ?? Categorizer.uncategorized
            let rec = TransactionRecord(fitid: t.fitid, accountId: acctId, accountName: account.name, date: t.date, name: t.name, amount: t.amount, type: t.type, category: category, memo: t.memo)
            context.insert(rec)
            inserted += 1
        }
        try? context.save()
        return (inserted, skipped)
    }
}

// MARK: - Budget

@MainActor
final class BudgetService {
    static func spent(for category: String, year: Int, month: Int, transactions: [TransactionRecord]) -> Double {
        let cal = Calendar.current
        return transactions.filter { tx in
            tx.category == category && tx.isExpense && cal.component(.year, from: tx.date) == year && cal.component(.month, from: tx.date) == month
        }.reduce(0) { $0 + abs($1.amount) }
    }

    static func summary(year: Int, month: Int, transactions: [TransactionRecord]) -> MonthlySummary {
        let cal = Calendar.current
        let inMonth = transactions.filter { cal.component(.year, from: $0.date) == year && cal.component(.month, from: $0.date) == month }
        let income = inMonth.filter { !$0.isExpense }.reduce(0) { $0 + $1.amount }
        let expenses = inMonth.filter { $0.isExpense }.reduce(0) { $0 + abs($1.amount) }
        return MonthlySummary(income: income, expenses: expenses, net: income - expenses)
    }

    static var defaultCategories: [String] {
        ["Housing", "Groceries", "Dining", "Transport", "Utilities", "Entertainment", "Health", "Savings", "Debt", "Other"]
    }

    /// The user's categories, sorted by name and de-duplicated case-insensitively.
    /// Stored in the `CustomCategory` table (seeded from `defaultCategories` on
    /// first launch) so every category can be renamed or deleted.
    static func allCategories(stored: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let sorted = stored.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for c in sorted {
            let trimmed = c.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// Names that can't be added as custom categories because the app uses them itself.
    static let reservedCategories = ["Income", "Uncategorized"]

    /// Returns a cleaned name if it can be added, or nil if it's empty,
    /// reserved, or already exists (case-insensitive).
    /// Returns a cleaned new name if renaming `old` to `raw` is allowed, or nil if
    /// it's empty, unchanged, reserved, or taken by a *different* category
    /// (case-insensitive). Changing only the capitalization is allowed.
    static func validatedRename(_ raw: String, from old: String, existing: [String]) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return nil }
        let others = (existing.filter { $0.lowercased() != old.lowercased() } + reservedCategories).map { $0.lowercased() }
        return others.contains(name.lowercased()) ? nil : name
    }

    static func validatedNewCategory(_ raw: String, existing: [String]) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let taken = Set((existing + reservedCategories).map { $0.lowercased() })
        return taken.contains(name.lowercased()) ? nil : name
    }
}

// MARK: - Running balance

enum RunningBalance {
    /// Balance after each transaction, anchored so the newest transaction ends
    /// at `endingBalance` (the account's current balance) and older rows are
    /// found by undoing the newer transactions' amounts.
    /// `newestFirst` must already be sorted newest to oldest.
    static func compute(newestFirst: [(id: UUID, amount: Double)], endingBalance: Double) -> [UUID: Double] {
        var result: [UUID: Double] = [:]
        var balance = endingBalance
        for tx in newestFirst {
            result[tx.id] = balance
            balance -= tx.amount
        }
        return result
    }
}

// MARK: - Calendar (Bills + EventKit)

@MainActor
@Observable
final class CalendarService {
    var access: EKAuthorizationStatus = .notDetermined
    private let store = EKEventStore()
    var financeCalendarID: String?

    func requestAccess() async {
        do { _ = try await store.requestFullAccessToEvents() } catch {}
        access = EKEventStore.authorizationStatus(for: .event)
    }

    var calendars: [EKCalendar] { store.calendars(for: .event) }

    func ensureFinanceCalendar() -> EKCalendar? {
        if let id = financeCalendarID, let cal = store.calendar(withIdentifier: id) { return cal }
        guard let defaultCal = store.defaultCalendarForNewEvents ?? store.calendars(for: .event).first else { return nil }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = "Finance Bills"
        cal.source = defaultCal.source
        do {
            try store.saveCalendar(cal, commit: true)
            financeCalendarID = cal.calendarIdentifier
            return cal
        } catch { return nil }
    }

    /// Create one event per active bill for the next N months in Finance Bills calendar.
    func syncBills(_ bills: [RecurringBill], months: Int = 12) throws -> Int {
        guard let cal = ensureFinanceCalendar() else { throw NSError(domain: "Calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "No calendar available"]) }
        var created = 0
        let now = Date()
        for bill in bills where bill.isActive {
            for offset in 0..<months {
                guard let date = Calendar.current.date(byAdding: .month, value: offset, to: now),
                      let due = Calendar.current.date(from: DateComponents(year: Calendar.current.component(.year, from: date), month: Calendar.current.component(.month, from: date), day: bill.dueDay)) else { continue }
                if due < now.addingTimeInterval(-86_400) { continue }
                let ev = EKEvent(eventStore: store)
                ev.title = "\(bill.name) — $\(String(format: "%.2f", bill.amount))"
                ev.startDate = Calendar.current.startOfDay(for: due)
                ev.endDate = Calendar.current.date(byAdding: .hour, value: 1, to: due)
                ev.calendar = cal
                ev.notes = "Category: \(bill.category)\nSynced by Finance app"
                if bill.lastPaid != nil { ev.notes! += "\nLast paid: \(bill.lastPaid!)" }
                try store.save(ev, span: .thisEvent, commit: true)
                created += 1
            }
        }
        return created
    }

    func upcomingBills(_ bills: [RecurringBill], days: Int = 30) -> [RecurringBill] {
        let now = Date()
        return bills.filter { bill in
            guard bill.isActive else { return false }
            for offset in 0..<2 {
                if let d = Calendar.current.date(byAdding: .month, value: offset, to: now),
                   let due = Calendar.current.date(from: DateComponents(year: Calendar.current.component(.year, from: d), month: Calendar.current.component(.month, from: d), day: bill.dueDay)),
                   due >= now && due.timeIntervalSince(now) < Double(days) * 86_400 { return true }
            }
            return false
        }.sorted { $0.dueDay < $1.dueDay }
    }
}

// MARK: - Dashboard reporting

enum DashboardPeriod: String, CaseIterable, Identifiable {
    case thisMonth = "This Month", lastMonth = "Last Month", last30Days = "Last 30 Days"
    case thisYear = "This Year", lastYear = "Last Year", allTime = "All Time"
    var id: String { rawValue }

    /// Half-open date range [start, end). A nil start means "from the beginning".
    func range(now: Date = Date(), calendar: Calendar = .current) -> (start: Date?, end: Date) {
        func interval(_ component: Calendar.Component, offset: Int) -> (start: Date?, end: Date) {
            let anchor = calendar.date(byAdding: component, value: offset, to: now) ?? now
            let i = calendar.dateInterval(of: component, for: anchor)
            return (i?.start, i?.end ?? now)
        }
        switch self {
        case .thisMonth: return interval(.month, offset: 0)
        case .lastMonth: return interval(.month, offset: -1)
        case .thisYear: return interval(.year, offset: 0)
        case .lastYear: return interval(.year, offset: -1)
        case .last30Days:
            let today = calendar.startOfDay(for: now)
            return (calendar.date(byAdding: .day, value: -29, to: today),
                    calendar.date(byAdding: .day, value: 1, to: today) ?? now)
        case .allTime: return (nil, .distantFuture)
        }
    }

    func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let r = range(now: now, calendar: calendar)
        if let start = r.start, date < start { return false }
        return date < r.end
    }
}

struct CategorySpend: Identifiable, Equatable {
    let category: String
    let amount: Double   // positive total spent
    let count: Int
    var id: String { category }
}

enum SpendingReport {
    typealias Row = (category: String, amount: Double, date: Date)

    /// Expenses (negative amounts) in the period, summed per category, biggest first.
    static func byCategory(_ rows: [Row], period: DashboardPeriod, now: Date = Date(), calendar: Calendar = .current) -> [CategorySpend] {
        var totals: [String: (amount: Double, count: Int)] = [:]
        for r in rows where r.amount < 0 && period.contains(r.date, now: now, calendar: calendar) {
            let cur = totals[r.category] ?? (0, 0)
            totals[r.category] = (cur.amount + abs(r.amount), cur.count + 1)
        }
        return totals.map { CategorySpend(category: $0.key, amount: $0.value.amount, count: $0.value.count) }
            .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.category < $1.category }
    }

    /// Money in and money out within the period.
    static func totals(_ rows: [Row], period: DashboardPeriod, now: Date = Date(), calendar: Calendar = .current) -> (income: Double, expenses: Double) {
        var income = 0.0, expenses = 0.0
        for r in rows where period.contains(r.date, now: now, calendar: calendar) {
            if r.amount < 0 { expenses += abs(r.amount) } else { income += r.amount }
        }
        return (income, expenses)
    }
}
