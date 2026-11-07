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
        var inserted = 0, skipped = 0
        for t in parsed.transactions {
            let key = "\(acctId)|\(t.fitid)"
            if existingFitIds.contains(key) { skipped += 1; continue }
            let category = Categorizer.category(forName: t.name, rules: rules) ?? Categorizer.uncategorized
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

    /// Default categories followed by the user's own, de-duplicated
    /// case-insensitively (a custom "groceries" doesn't duplicate "Groceries").
    static func allCategories(custom: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let customSorted = custom.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for c in defaultCategories + customSorted {
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
