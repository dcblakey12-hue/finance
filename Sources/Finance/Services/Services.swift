import Foundation
import SwiftData
import EventKit
import CoreData
import Combine
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

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
        } else {
            account = Account(name: parsed.accountName, type: parsed.isCreditCard ? .creditCard : .checking, accountId: acctId, bankName: parsed.bankId, balance: parsed.balance ?? 0)
            context.insert(account)
        }

        let existingRecords: [TransactionRecord] = (try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? []
        let existingFitIds = Set(existingRecords.map { "\($0.accountId)|\($0.fitid)" })
        let rules = CategorizationService.ruleMap(in: context)
        let allowed = CategoryService.allowedBuiltIns(in: context)
        var inserted = 0, skipped = 0
        var newlyInserted: [TransactionRecord] = []
        // Transactions typed in by hand (e.g. on the phone) that the bank has now reported.
        var manual = existingRecords.filter { $0.accountId == acctId && ManualTransactionService.isManual($0) }
        for t in parsed.transactions {
            let key = "\(acctId)|\(t.fitid)"
            if existingFitIds.contains(key) { skipped += 1; continue }
            let category = Categorizer.category(forName: t.name, rules: rules, allowed: allowed) ?? Categorizer.uncategorized
            let rec = TransactionRecord(fitid: t.fitid, accountId: acctId, accountName: account.name, date: t.date, name: t.name, amount: t.amount, type: t.type, category: category, memo: t.memo)
            // Replace the matching hand-entered transaction so it isn't counted twice,
            // keeping the category you chose and any transfer link.
            if let i = manual.firstIndex(where: { ManualTransactionService.matches($0, amount: t.amount, date: t.date) }) {
                let m = manual.remove(at: i)
                if m.category != Categorizer.uncategorized { rec.category = m.category }
                rec.transferPeerId = m.transferPeerId
                for other in existingRecords where other.transferPeerId == m.id { other.transferPeerId = rec.id }
                context.delete(m)
            }
            context.insert(rec)
            newlyInserted.append(rec)
            inserted += 1
        }
        // The bank's balance doesn't know about hand-entered transactions it hasn't reported yet,
        // so those still left over are added on top (matched ones were removed above).
        if let bal = parsed.balance { account.balance = ManualTransactionService.balance(bank: bal, unreported: manual) }
        try? context.save()
        // Scheduled payments the bank has now reported no longer count as overdue.
        ScheduleService.autoResolve(with: newlyInserted, in: context)
        return (inserted, skipped)
    }
}

extension TransactionRecord {
    /// Confirmed by the bank: it came from a bank sync or a file import. Hand-entered transactions
    /// (typed in, or entered from a scheduled payment) stay unreconciled until the bank reports them.
    @MainActor var isReconciled: Bool { !ManualTransactionService.isManual(self) }
}

// MARK: - Hand-entered transactions

/// Transactions typed in directly (phone or Mac) rather than imported from a bank file.
/// They are given a "manual-" id and are replaced automatically when the bank's own record
/// of the same amount arrives within a few days.
@MainActor
enum ManualTransactionService {
    static let prefix = "manual-"
    static let matchWindowDays = 5

    static func isManual(_ t: TransactionRecord) -> Bool { t.fitid.hasPrefix(prefix) }

    /// Would `t` (a hand-entered record) be the same purchase as an imported one?
    static func matches(_ t: TransactionRecord, amount: Double, date: Date, calendar: Calendar = .current) -> Bool {
        guard t.amount == amount else { return false }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: t.date), to: calendar.startOfDay(for: date)).day ?? Int.max
        return abs(days) <= matchWindowDays
    }

    /// Hand-entered transactions in an account that the bank hasn't reported yet.
    static func unreported(in accountId: String, from all: [TransactionRecord]) -> [TransactionRecord] {
        all.filter { $0.accountId == accountId && isManual($0) }
    }

    /// The balance to show when the bank reports `bank`: its figure plus the hand-entered transactions
    /// it hasn't reported yet. Each one is replaced by the bank's own record when that arrives (see
    /// `TransactionImportService`), so it stops counting here at the same moment the bank's figure
    /// starts including it, and nothing is counted twice.
    static func balance(bank: Double, unreported: [TransactionRecord]) -> Double {
        unreported.reduce(bank) { $0 + $1.amount }
    }

    /// Add a transaction by hand. `amount` is signed (negative = money out). The account's
    /// balance moves by the same amount, and keeps it through bank syncs until the bank reports it.
    @discardableResult
    static func add(to account: Account, date: Date, name: String, amount: Double,
                    category: String? = nil, memo: String = "", in context: ModelContext) -> TransactionRecord {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = category ?? Categorizer.category(forName: cleaned, rules: CategorizationService.ruleMap(in: context),
                                                       allowed: CategoryService.allowedBuiltIns(in: context))
            ?? Categorizer.uncategorized
        let tx = TransactionRecord(fitid: prefix + UUID().uuidString, accountId: account.accountId, accountName: account.name,
                                   date: date, name: cleaned, amount: amount, type: amount < 0 ? .debit : .credit,
                                   category: chosen, memo: memo)
        context.insert(tx)
        account.balance += amount
        try? context.save()
        return tx
    }

    /// Delete a hand-entered transaction and undo its effect on the balance.
    /// Does nothing for imported transactions.
    @discardableResult
    static func delete(_ tx: TransactionRecord, from accounts: [Account], in context: ModelContext) -> Bool {
        guard isManual(tx) else { return false }
        accounts.first { $0.accountId == tx.accountId }?.balance -= tx.amount
        for other in (try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? [] where other.transferPeerId == tx.id {
            other.transferPeerId = nil
        }
        context.delete(tx)
        try? context.save()
        return true
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

    /// Months to offer in the Budget month dropdown, newest first (each is a start-of-month date):
    /// from the earlier of your first transaction and 11 months ago, through 3 months ahead,
    /// always including the currently selected month.
    static func monthOptions(earliest: Date?, now: Date, selected: Date, calendar: Calendar = .current) -> [Date] {
        func monthStart(_ d: Date) -> Date { calendar.dateInterval(of: .month, for: d)?.start ?? d }
        let current = monthStart(now)
        let elevenAgo = calendar.date(byAdding: .month, value: -11, to: current) ?? current
        let first = min(earliest.map(monthStart) ?? elevenAgo, elevenAgo, monthStart(selected))
        let last = max(calendar.date(byAdding: .month, value: 3, to: current) ?? current, monthStart(selected))
        var months: [Date] = []
        var m = first
        while m <= last && months.count < 600 {
            months.append(m)
            guard let next = calendar.date(byAdding: .month, value: 1, to: m) else { break }
            m = next
        }
        return months.reversed()
    }

    /// Month totals excluding transfers. When `incomeAccountIds` is given, only money
    /// arriving in those accounts (e.g. checking) counts as income, so card refunds and
    /// savings interest don't. Spending always counts every account.
    static func summary(year: Int, month: Int, transactions: [TransactionRecord],
                        incomeAccountIds: Set<String>? = nil) -> MonthlySummary {
        let cal = Calendar.current
        let inMonth = transactions.filter {
            $0.category != Categorizer.transfer &&
            cal.component(.year, from: $0.date) == year && cal.component(.month, from: $0.date) == month
        }
        let income = inMonth.filter { !$0.isExpense && (incomeAccountIds?.contains($0.accountId) ?? true) }
            .reduce(0) { $0 + $1.amount }
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
    static let reservedCategories = ["Income", "Uncategorized", "Transfer"]

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
    var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    private let store = EKEventStore()
    static let defaultCalendarName = "Finance Bills"
    /// Title of the Mac calendar the app writes to (user-chosen; created if missing).
    var calendarName = CalendarService.defaultCalendarName
    static let marker = "Synced by Finance app"
    var isAuthorized: Bool { access == .fullAccess }

    func requestAccess() async {
        do { _ = try await store.requestFullAccessToEvents() } catch {}
        access = EKEventStore.authorizationStatus(for: .event)
    }

    var calendars: [EKCalendar] { store.calendars(for: .event) }

    /// The "Finance Bills" calendar: reused if it exists (by title), otherwise created.
    func ensureFinanceCalendar() -> EKCalendar? {
        if let existing = store.calendars(for: .event).first(where: { $0.title == calendarName }) { return existing }
        guard let defaultCal = store.defaultCalendarForNewEvents ?? store.calendars(for: .event).first else { return nil }
        let cal = EKCalendar(for: .event, eventStore: store)
        cal.title = calendarName
        cal.source = defaultCal.source
        do { try store.saveCalendar(cal, commit: true); return cal } catch { return nil }
    }

    /// Remove events this app created (from a month ago to five years out). Returns how many.
    @discardableResult
    func clearSynced() throws -> Int {
        guard let cal = store.calendars(for: .event).first(where: { $0.title == calendarName }) else { return 0 }
        let start = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        let end = Calendar.current.date(byAdding: .year, value: 5, to: Date())!
        let mine = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: [cal]))
            .filter { $0.notes?.contains(Self.marker) == true }
        for ev in mine { try store.remove(ev, span: .thisEvent, commit: false) }
        try store.commit()
        return mine.count
    }

    /// Replace the app's events in the Finance Bills calendar with one all-day event per
    /// active scheduled transaction per month for the next `months` months. Safe to re-run:
    /// earlier synced events are removed first, so nothing is duplicated.
    func syncBills(_ bills: [RecurringBill], months: Int = 12, accountNames: [String: String] = [:]) throws -> Int {
        guard let cal = ensureFinanceCalendar() else { throw NSError(domain: "Calendar", code: 1, userInfo: [NSLocalizedDescriptionKey: "No calendar available"]) }
        try clearSynced()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .month, value: months, to: today) ?? today
        var created = 0
        for bill in bills where bill.isActive {
            for due in bill.rule.dates(from: today, to: end, calendar: calendar) {
                let ev = EKEvent(eventStore: store)
                let amount = currency.string(from: NSNumber(value: abs(bill.amount))) ?? String(format: "$%.2f", abs(bill.amount))
                let route = bill.item(accountNames: accountNames).detail
                if bill.isTransfer { ev.title = "\(bill.name) — \(amount)" + (route.map { " (\($0))" } ?? "") }
                else { ev.title = bill.isIncome ? "\(bill.name) — +\(amount)" : "\(bill.name) — \(amount)" }
                ev.isAllDay = true
                ev.startDate = due
                ev.endDate = due
                ev.calendar = cal
                ev.notes = "Category: \(bill.category)\n\(Self.marker)"
                try store.save(ev, span: .thisEvent, commit: false)
                created += 1
            }
        }
        try store.commit()
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

    /// Expenses (negative amounts) in the period, summed per category, biggest first. Transfers are skipped.
    static func byCategory(_ rows: [Row], period: DashboardPeriod, now: Date = Date(), calendar: Calendar = .current) -> [CategorySpend] {
        var totals: [String: (amount: Double, count: Int)] = [:]
        for r in rows where r.category != Categorizer.transfer && r.amount < 0 && period.contains(r.date, now: now, calendar: calendar) {
            let cur = totals[r.category] ?? (0, 0)
            totals[r.category] = (cur.amount + abs(r.amount), cur.count + 1)
        }
        return totals.map { CategorySpend(category: $0.key, amount: $0.value.amount, count: $0.value.count) }
            .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.category < $1.category }
    }

    /// Money in and money out within the period, excluding transfers between your accounts.
    static func totals(_ rows: [Row], period: DashboardPeriod, now: Date = Date(), calendar: Calendar = .current) -> (income: Double, expenses: Double) {
        var income = 0.0, expenses = 0.0
        for r in rows where r.category != Categorizer.transfer && period.contains(r.date, now: now, calendar: calendar) {
            if r.amount < 0 { expenses += abs(r.amount) } else { income += r.amount }
        }
        return (income, expenses)
    }
}

// MARK: - Transactions filters

enum TransactionFlow: String, CaseIterable, Identifiable {
    case all = "All"
    case income = "Income (no transfers)"
    case spending = "Spending (no transfers)"
    var id: String { rawValue }
}

/// Everything the Transactions screen can be filtered by. Owned by ContentView so
/// other screens (Dashboard, Accounts, Budget) can open Transactions pre-filtered.
struct TransactionFilters: Equatable {
    var accountId: String? = nil        // one account (OFX accountId)
    var accountIds: Set<String>? = nil  // restrict to a set, e.g. checking accounts
    var category: String = "All"
    var period: DashboardPeriod = .allTime
    var month: Date? = nil              // a specific month; takes priority over `period`
    var flow: TransactionFlow = .all

    func matches(accountId acct: String, category cat: String, date: Date, amount: Double,
                 now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if let accountId, accountId != acct { return false }
        if let accountIds, !accountIds.contains(acct) { return false }
        if category != "All", category != cat { return false }
        if let month {
            if !calendar.isDate(date, equalTo: month, toGranularity: .month) { return false }
        } else if period != .allTime, !period.contains(date, now: now, calendar: calendar) {
            return false
        }
        switch flow {
        case .all: break
        case .income: if amount < 0 || cat == Categorizer.transfer { return false }
        case .spending: if amount >= 0 || cat == Categorizer.transfer { return false }
        }
        return true
    }
}

// MARK: - Bulk delete

@MainActor
enum TransactionDeletionService {
    /// Delete transactions. Hand-entered ones also undo their effect on the account balance (imported ones
    /// leave the bank's balance alone). Transfer links from surviving transactions are cleared.
    /// Returns how many were deleted.
    @discardableResult
    static func delete(_ txs: [TransactionRecord], accounts: [Account], all: [TransactionRecord], in context: ModelContext) -> Int {
        let ids = Set(txs.map(\.id))
        for other in all where !ids.contains(other.id) {
            if let peer = other.transferPeerId, ids.contains(peer) { other.transferPeerId = nil }
        }
        for t in txs {
            if ManualTransactionService.isManual(t) { accounts.first { $0.accountId == t.accountId }?.balance -= t.amount }
            context.delete(t)
        }
        try? context.save()
        return txs.count
    }
}

// MARK: - Backup & restore

/// Everything in the data file as plain Codable values, so it can be saved to a file,
/// kept elsewhere, and loaded back (here or on another Mac). Passwords are never included.
struct BackupFile: Codable, Equatable {
    struct AccountRow: Codable, Equatable { var id: UUID; var name: String; var typeRaw: String; var accountId: String; var bankName: String; var balance: Double }
    struct TransactionRow: Codable, Equatable {
        var id: UUID; var fitid: String; var accountId: String; var accountName: String; var date: Date
        var name: String; var amount: Double; var typeRaw: String; var category: String; var memo: String; var transferPeerId: UUID?
    }
    struct EnvelopeRow: Codable, Equatable { var id: UUID; var category: String; var year: Int; var month: Int; var allocated: Double }
    struct ScheduleRow: Codable, Equatable {
        var id: UUID; var name: String; var amount: Double; var dueDay: Int; var category: String; var isActive: Bool
        var lastPaid: Date?; var kindRaw: String; var fromAccountId: String?; var toAccountId: String?
        var frequencyRaw: String; var secondDay: Int; var anchorDate: Date?; var occurrenceLogRaw: String
        var accountId: String?; var trackedSince: Date?; var endDate: Date?
    }
    struct ProfileRow: Codable, Equatable { var id: UUID; var bankName: String; var ofxHomeURL: String; var username: String; var accountId: String; var clientUID: String; var lastSync: Date? }
    struct RuleRow: Codable, Equatable { var merchantKey: String; var category: String; var createdAt: Date; var updatedAt: Date }
    struct CategoryRow: Codable, Equatable { var name: String; var createdAt: Date }
    struct SubscriptionMarkRow: Codable, Equatable { var merchantKey: String; var cadenceRaw: String; var amount: Double; var statusRaw: String; var updatedAt: Date }

    var format: Int = 1
    var createdAt: Date
    var accounts: [AccountRow]
    var transactions: [TransactionRow]
    var envelopes: [EnvelopeRow]
    var schedules: [ScheduleRow]
    var profiles: [ProfileRow]
    var rules: [RuleRow]
    var categories: [CategoryRow]
    /// Your confirmed / dismissed subscriptions. Optional so backups made before it existed still load.
    var subscriptionMarks: [SubscriptionMarkRow]? = nil

    var summary: String {
        "\(accounts.count) accounts, \(transactions.count) transactions, \(schedules.count) scheduled, \(envelopes.count) budget lines"
    }
}

@MainActor
enum BackupService {
    static func snapshot(in context: ModelContext, now: Date = Date()) -> BackupFile {
        func all<T: PersistentModel>(_: T.Type) -> [T] { (try? context.fetch(FetchDescriptor<T>())) ?? [] }
        return BackupFile(
            createdAt: now,
            accounts: all(Account.self).map { .init(id: $0.id, name: $0.name, typeRaw: $0.typeRaw, accountId: $0.accountId, bankName: $0.bankName, balance: $0.balance) },
            transactions: all(TransactionRecord.self).map { .init(id: $0.id, fitid: $0.fitid, accountId: $0.accountId, accountName: $0.accountName, date: $0.date, name: $0.name, amount: $0.amount, typeRaw: $0.typeRaw, category: $0.category, memo: $0.memo, transferPeerId: $0.transferPeerId) },
            envelopes: all(Envelope.self).map { .init(id: $0.id, category: $0.category, year: $0.year, month: $0.month, allocated: $0.allocated) },
            schedules: all(RecurringBill.self).map { .init(id: $0.id, name: $0.name, amount: $0.amount, dueDay: $0.dueDay, category: $0.category, isActive: $0.isActive, lastPaid: $0.lastPaid, kindRaw: $0.kindRaw, fromAccountId: $0.fromAccountId, toAccountId: $0.toAccountId, frequencyRaw: $0.frequencyRaw, secondDay: $0.secondDay, anchorDate: $0.anchorDate, occurrenceLogRaw: $0.occurrenceLogRaw, accountId: $0.accountId, trackedSince: $0.trackedSince, endDate: $0.endDate) },
            profiles: all(OFXProfile.self).map { .init(id: $0.id, bankName: $0.bankName, ofxHomeURL: $0.ofxHomeURL, username: $0.username, accountId: $0.accountId, clientUID: $0.clientUID, lastSync: $0.lastSync) },
            rules: all(CategoryRule.self).map { .init(merchantKey: $0.merchantKey, category: $0.category, createdAt: $0.createdAt, updatedAt: $0.updatedAt) },
            categories: all(CustomCategory.self).map { .init(name: $0.name, createdAt: $0.createdAt) },
            subscriptionMarks: all(SubscriptionMark.self).map { .init(merchantKey: $0.merchantKey, cadenceRaw: $0.cadenceRaw, amount: $0.amount, statusRaw: $0.statusRaw, updatedAt: $0.updatedAt) })
    }

    static func encode(_ file: BackupFile) throws -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(file)
    }
    static func decode(_ data: Data) throws -> BackupFile {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(BackupFile.self, from: data)
    }

    /// Delete every record (this also removes it from iCloud and the phone).
    static func wipe(in context: ModelContext) {
        func clear<T: PersistentModel>(_: T.Type) { for x in (try? context.fetch(FetchDescriptor<T>())) ?? [] { context.delete(x) } }
        clear(TransactionRecord.self); clear(Account.self); clear(Envelope.self); clear(RecurringBill.self)
        clear(OFXProfile.self); clear(CategoryRule.self); clear(CustomCategory.self); clear(SubscriptionMark.self)
        try? context.save()
    }

    /// Replace everything with the contents of `file`.
    static func restore(_ file: BackupFile, in context: ModelContext) {
        wipe(in: context)
        for a in file.accounts { context.insert(Account(id: a.id, name: a.name, type: AccountType(rawValue: a.typeRaw) ?? .checking, accountId: a.accountId, bankName: a.bankName, balance: a.balance)) }
        for t in file.transactions {
            let r = TransactionRecord(id: t.id, fitid: t.fitid, accountId: t.accountId, accountName: t.accountName, date: t.date, name: t.name, amount: t.amount, type: TransactionType(rawValue: t.typeRaw) ?? .debit, category: t.category, memo: t.memo)
            r.transferPeerId = t.transferPeerId; context.insert(r)
        }
        for e in file.envelopes { context.insert(Envelope(id: e.id, category: e.category, year: e.year, month: e.month, allocated: e.allocated)) }
        for s in file.schedules {
            let b = RecurringBill(id: s.id, name: s.name, amount: s.amount, dueDay: s.dueDay, category: s.category, isActive: s.isActive)
            b.lastPaid = s.lastPaid; b.kindRaw = s.kindRaw; b.fromAccountId = s.fromAccountId; b.toAccountId = s.toAccountId
            b.frequencyRaw = s.frequencyRaw; b.secondDay = s.secondDay; b.anchorDate = s.anchorDate
            b.occurrenceLogRaw = s.occurrenceLogRaw; b.accountId = s.accountId; b.trackedSince = s.trackedSince; b.endDate = s.endDate
            context.insert(b)
        }
        for p in file.profiles {
            let o = OFXProfile(id: p.id, bankName: p.bankName, ofxHomeURL: p.ofxHomeURL, username: p.username, accountId: p.accountId)
            o.clientUID = p.clientUID; o.lastSync = p.lastSync; context.insert(o)
        }
        for r in file.rules { context.insert(CategoryRule(merchantKey: r.merchantKey, category: r.category, now: r.createdAt)); }
        for c in file.categories { context.insert(CustomCategory(name: c.name, createdAt: c.createdAt)) }
        for m in file.subscriptionMarks ?? [] {
            let mark = SubscriptionMark(merchantKey: m.merchantKey, cadence: .monthly, amount: m.amount, status: .confirmed, now: m.updatedAt)
            mark.cadenceRaw = m.cadenceRaw; mark.statusRaw = m.statusRaw; context.insert(mark)
        }
        try? context.save()
    }

    /// Fresh, empty data file: wipes everything and re-seeds the standard category list.
    static func startNew(in context: ModelContext) {
        wipe(in: context)
        CategoryService.seedIfNeeded(in: context, defaults: UserDefaults(suiteName: "finance.fresh.\(UUID().uuidString)") ?? .standard)
    }

    static func suggestedName(now: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"; f.locale = Locale(identifier: "en_US_POSIX")
        return "Finance Backup \(f.string(from: now)).json"
    }
}

// MARK: - iCloud sync status

/// Watches SwiftData's CloudKit sync so the apps can show when changes last went up / came down,
/// and lets the person ask for an immediate check for changes made on another device.
@MainActor
final class CloudSyncMonitor: ObservableObject {
    @Published var lastExport: Date?      // this device sent changes to iCloud
    @Published var lastImport: Date?      // this device received changes from iCloud
    @Published var lastError: String?
    @Published var working = false
    /// True from a "check now" (or the app coming to the front) until iCloud reports an import, or a timeout.
    @Published private(set) var checking = false
    /// Result of the last check, shown in the tooltip.
    @Published private(set) var checkNote: String?
    private var checkStarted: Date?
    private var timeout: Task<Void, Never>?
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            let type = event.type, end = event.endDate, ok = event.succeeded
            let message = event.error?.localizedDescription
            MainActor.assumeIsolated { self?.record(type: type, end: end, ok: ok, error: message) }
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    private func record(type: NSPersistentCloudKitContainer.EventType, end: Date?, ok: Bool, error: String?) {
        working = end == nil
        guard let end else { return }
        if ok {
            switch type {
            case .export: lastExport = end
            case .import: lastImport = end
            default: break
            }
            lastError = nil
        } else if let error {
            lastError = error
        }
        if type == .import, checking { finishCheck(note: ok ? "Checked iCloud at \(Self.clock(end))." : nil) }
    }

    /// Ask iCloud for changes now (e.g. a transaction added on the iPhone).
    ///
    /// SwiftData has no public "sync now" call. NSPersistentCloudKitContainer imports when the app
    /// launches, when it's activated, and when CloudKit pushes a change. So this:
    /// 1. saves any pending edits here, which starts an export;
    /// 2. (re)registers for CloudKit's push notifications, so later changes arrive on their own;
    /// 3. if `nudge` is set, re-sends the app-activated notification, which schedules an import.
    /// The icon shows a syncing state until iCloud reports that import, or 20 seconds pass.
    /// Without `nudge` (the app just came to the front) it only shows that state, because the
    /// system schedules the activation import itself.
    func checkNow(context: ModelContext?, nudge: Bool = true) {
        guard !checking else { return }
        if let context, context.hasChanges { try? context.save() }
        checking = true
        checkNote = nil
        checkStarted = Date()
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        if nudge { NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared) }
        #elseif canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        if nudge { NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared) }
        #endif
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.checking else { return }
            self.finishCheck(note: "iCloud hasn't answered yet (asked \(Self.clock(self.checkStarted ?? Date()))). "
                             + "If a change from your other device is still missing, quit and reopen Finance.")
        }
    }

    private func finishCheck(note: String?) {
        checking = false
        checkNote = note
        timeout?.cancel(); timeout = nil
    }

    private static func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    private func ago(_ d: Date?) -> String {
        guard let d else { return "not yet this session" }
        return d.formatted(.relative(presentation: .named))
    }
    /// One-line summary for a tooltip or footer.
    var summary: String {
        if let lastError { return "iCloud problem: \(lastError)" }
        if checking { return "Checking iCloud for changes…" }
        let base = "Sent to iCloud: \(ago(lastExport)). Received from iCloud: \(ago(lastImport))."
        return checkNote.map { base + " " + $0 } ?? base
    }
    var hasProblem: Bool { lastError != nil }
    /// SF Symbol for the current state.
    func symbol(receiving: Bool) -> String {
        if hasProblem { return "exclamationmark.icloud" }
        if checking { return "arrow.clockwise.icloud" }
        if working { return receiving ? "icloud.and.arrow.down" : "icloud.and.arrow.up" }
        return "icloud"
    }
}
