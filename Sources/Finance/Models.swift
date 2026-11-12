import Foundation
import SwiftData

/// Shared currency formatter (used by both the Mac and iPhone apps).
let currency: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .currency; f.locale = .current; return f
}()

enum AccountType: String, Codable, CaseIterable { case checking, savings, creditCard, mortgage, investment, cash, property }

/// Accounts of one type, for sectioned lists.
struct AccountGroup<Item> {
    let type: AccountType
    let items: [Item]
}

extension AccountType {
    /// Order sections appear in: checking first, then savings, cards, mortgage, investments, cash.
    static let displayOrder: [AccountType] = [.checking, .savings, .creditCard, .mortgage, .investment, .cash, .property]

    /// A home or other property whose value you update by hand. It counts in net worth, but it is
    /// not cash: it is left out of cash balances, running balances and the cash flow forecast.
    var isPropertyValue: Bool { self == .property }

    /// Whether a new account of this type counts toward spending, income and cash flow until you
    /// change it. Mortgages (escrow, property tax) and property values are left out by default.
    var countsInCashFlowByDefault: Bool { self != .mortgage && self != .property }

    /// Group items by account type in `displayOrder`, skipping types with no accounts.
    /// Items keep their incoming order within each group.
    static func grouped<Item>(_ items: [Item], by type: (Item) -> AccountType) -> [AccountGroup<Item>] {
        displayOrder.compactMap { t in
            let matching = items.filter { type($0) == t }
            return matching.isEmpty ? nil : AccountGroup(type: t, items: matching)
        }
    }
}
enum TransactionType: String, Codable { case debit, credit }

@Model
final class Account {
    var id: UUID = UUID()
    var name: String = ""
    var typeRaw: String = "checking"
    var accountId: String = ""  // OFX ACCTID
    var bankName: String = ""
    var balance: Double = 0
    /// Your choice for "Include in spending & cash flow". Nil = the account type's default
    /// (see `AccountType.countsInCashFlowByDefault`). Optional so older data and backups need no migration.
    var cashFlowOverride: Bool? = nil
    /// When a Plaid sync last brought this account fully up to date. Set on the Mac only after the sync
    /// worked and was saved; the phone reads it through iCloud. Nil for accounts not linked to Plaid.
    var plaidLastSync: Date? = nil
    /// When the latest Plaid sync attempt for this account failed, and why. Cleared by the next good sync.
    var plaidSyncFailedAt: Date? = nil
    var plaidSyncError: String? = nil

    init(id: UUID = UUID(), name: String, type: AccountType, accountId: String, bankName: String, balance: Double = 0,
         cashFlowOverride: Bool? = nil) {
        self.id = id; self.name = name; self.typeRaw = type.rawValue
        self.accountId = accountId; self.bankName = bankName; self.balance = balance
        self.cashFlowOverride = cashFlowOverride
    }
    var type: AccountType { AccountType(rawValue: typeRaw) ?? .checking }

    /// Whether this account's transactions count in spending, income, category totals, budgets,
    /// forecasts and subscriptions. Net worth, balances and account lists always include every account.
    var countsInCashFlow: Bool {
        get { cashFlowOverride ?? type.countsInCashFlowByDefault }
        set { cashFlowOverride = newValue == type.countsInCashFlowByDefault ? nil : newValue }
    }
}

/// What to show under a Plaid-linked account about its last sync. Nil for accounts Plaid doesn't feed.
struct PlaidSyncStatus: Equatable {
    enum Level: Equatable { case ok, stale, failed }
    /// A sync older than this gets a warning.
    static let staleAfter: TimeInterval = 3 * 24 * 60 * 60

    var level: Level
    var lastSync: Date?
    var failedAt: Date?
    var error: String?

    @MainActor init?(_ a: Account, now: Date = Date()) {
        self.init(lastSync: a.plaidLastSync, failedAt: a.plaidSyncFailedAt, error: a.plaidSyncError, now: now)
    }

    init?(lastSync: Date?, failedAt: Date?, error: String?, now: Date = Date()) {
        // A failure older than the last good sync no longer matters.
        let failed = failedAt.flatMap { f in (lastSync.map { f > $0 } ?? true) ? f : nil }
        guard lastSync != nil || failed != nil else { return nil }
        self.lastSync = lastSync; self.failedAt = failed; self.error = failed == nil ? nil : error
        if failed != nil { level = .failed }
        else if let l = lastSync, now.timeIntervalSince(l) > Self.staleAfter { level = .stale }
        else { level = .ok }
    }

    var isWarning: Bool { level != .ok }

    /// One line for the account list, e.g. "Synced today, 3:41 PM" or "Last sync failed · synced Nov 8, 3:41 PM".
    func summary(now: Date = Date(), calendar: Calendar = .current) -> String {
        let when = lastSync.map { Self.when($0, now: now, calendar: calendar) }
        switch level {
        case .ok, .stale: return "Synced " + (when ?? "")
        case .failed: return "Last sync failed · " + (when.map { "synced " + $0 } ?? "never synced")
        }
    }

    /// Longer text for a tooltip or detail line.
    func detail(now: Date = Date(), calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if let l = lastSync {
            parts.append("Last synced with the bank \(l.formatted(date: .complete, time: .shortened)).")
            if level == .stale { parts.append("That's over 3 days ago; open Finance on your Mac to sync.") }
        } else { parts.append("Not synced with the bank yet.") }
        if let f = failedAt {
            parts.append("The last try, \(Self.when(f, now: now, calendar: calendar)), failed" + (error.map { ": \($0)" } ?? "."))
        }
        return parts.joined(separator: " ")
    }

    static func when(_ d: Date, now: Date, calendar: Calendar) -> String {
        let time = d.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(d, inSameDayAs: now) { return "today, \(time)" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return "yesterday, \(time)" }
        let sameYear = calendar.component(.year, from: d) == calendar.component(.year, from: now)
        let day = sameYear ? d.formatted(.dateTime.month(.abbreviated).day()) : d.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(day), \(time)"
    }
}

/// What a failed Plaid sync means in plain words, and what fixes it. Read from the stored error text,
/// which ends with Plaid's code in brackets, e.g. "the login details of this item have changed (ITEM_LOGIN_REQUIRED)".
struct PlaidProblem: Equatable {
    enum Fix: Equatable {
        /// Sign in to the bank again through Plaid (update mode): same connection, history kept.
        case reconnect
        /// Nothing to change on your side: try the sync again later.
        case retry
        /// The Plaid keys in Settings are wrong or for the other environment.
        case checkKeys
        /// The connection is gone at Plaid: remove it in Settings and connect the bank again.
        case replace
    }

    var code: String?
    var message: String
    var fix: Fix

    init(error: String?) {
        let code = Self.code(in: error)
        self.code = code
        switch code {
        case "ITEM_LOGIN_REQUIRED", "PENDING_EXPIRATION", "PENDING_DISCONNECT", "ITEM_CONSENT_EXPIRED",
             "INVALID_CREDENTIALS", "INVALID_MFA", "INVALID_UPDATED_USERNAME", "ITEM_LOCKED",
             "USER_SETUP_REQUIRED", "USER_INPUT_TIMEOUT", "MFA_NOT_SUPPORTED":
            message = "Your bank needs you to sign in again before Plaid can download anything."
            fix = .reconnect
        case "ACCESS_NOT_GRANTED", "NO_ACCOUNTS", "USER_PERMISSION_REVOKED", "NO_AUTH_ACCOUNTS":
            message = "The bank stopped sharing these accounts with Plaid. Reconnect and allow access to them again."
            fix = .reconnect
        case "INSTITUTION_DOWN", "INSTITUTION_NOT_RESPONDING", "INSTITUTION_NOT_AVAILABLE", "INSTITUTION_NO_LONGER_SUPPORTED",
             "INTERNAL_SERVER_ERROR", "PLANNED_MAINTENANCE", "RATE_LIMIT_EXCEEDED", "PRODUCT_NOT_READY",
             "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION", "ITEM_PRODUCT_NOT_READY":
            message = "The bank or Plaid is having trouble right now. Nothing to fix on your side; try again later."
            fix = .retry
        case "INVALID_API_KEYS", "INVALID_SECRET", "INVALID_CLIENT_ID", "UNAUTHORIZED_ENVIRONMENT":
            message = "Plaid didn't accept your keys. Check the client ID, secret and environment in Settings."
            fix = .checkKeys
        case "INVALID_ACCESS_TOKEN", "ITEM_NOT_FOUND":
            message = "Plaid no longer knows this bank connection. Remove it in Settings and connect the bank again."
            fix = .replace
        default:
            if error?.contains("missing its access token") == true {
                message = "This Mac has lost the key for this bank connection. Remove it in Settings and connect the bank again."
                fix = .replace
            } else if error?.lowercased().contains("internet") == true || error?.lowercased().contains("timed out") == true
                        || error?.lowercased().contains("network") == true {
                message = "Couldn't reach Plaid. Check the internet connection and try again."
                fix = .retry
            } else {
                message = "The last sync didn't work. Try again; if it keeps failing, reconnect the bank."
                fix = .retry
            }
        }
    }

    /// The Plaid error code at the end of the message, if there is one.
    static func code(in error: String?) -> String? {
        guard let e = error?.trimmingCharacters(in: .whitespaces), e.hasSuffix(")"),
              let open = e.lastIndex(of: "(") else { return nil }
        let c = e[e.index(after: open)..<e.index(before: e.endIndex)]
        guard !c.isEmpty, c.allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }) else { return nil }
        return String(c)
    }
}

extension PlaidSyncStatus {
    /// Set when the last sync failed: what went wrong and how to fix it.
    var problem: PlaidProblem? { level == .failed ? PlaidProblem(error: error) : nil }

    /// Accounts whose last bank sync failed, for the Overview banner.
    @MainActor static func needingAttention(_ accounts: [Account], now: Date = Date()) -> [Account] {
        accounts.filter { PlaidSyncStatus($0, now: now)?.level == .failed }
    }
}

/// Keeps accounts you've left out of cash flow (e.g. a mortgage paying escrow and property tax)
/// out of spending, income and forecasts, while net worth still counts them.
enum CashFlowScope {
    /// OFX accountIds of accounts left out of spending and cash flow.
    @MainActor static func excludedIds(_ accounts: [Account]) -> Set<String> {
        Set(accounts.filter { !$0.countsInCashFlow }.map(\.accountId))
    }
    /// The transactions that count toward spending, income and cash flow.
    @MainActor static func transactions(_ txs: [TransactionRecord], accounts: [Account]) -> [TransactionRecord] {
        let out = excludedIds(accounts)
        return out.isEmpty ? txs : txs.filter { !out.contains($0.accountId) }
    }
    /// The accounts a forecast should cover: `selected` (nil = all) minus excluded ones.
    /// Nil when nothing is excluded and nothing is picked, meaning every account.
    @MainActor static func accountIds(selected: Set<String>?, accounts: [Account]) -> Set<String>? {
        let out = excludedIds(accounts)
        guard !out.isEmpty else { return selected }
        return (selected ?? Set(accounts.map(\.accountId))).subtracting(out)
    }
}

@Model
final class TransactionRecord {
    var id: UUID = UUID()
    var fitid: String = ""       // OFX FITID - unique per bank/account (enforced by import + DedupeService)
    var accountId: String = ""
    var accountName: String = ""
    var date: Date = Date()
    var name: String = ""
    var amount: Double = 0
    var typeRaw: String = "debit"
    var category: String = "Uncategorized"
    var memo: String = ""
    /// The other side of a transfer between two of your accounts (e.g. the card payment
    /// that matches a bank debit). Nil when not linked.
    var transferPeerId: UUID? = nil

    init(id: UUID = UUID(), fitid: String, accountId: String, accountName: String, date: Date, name: String, amount: Double, type: TransactionType, category: String = "Uncategorized", memo: String = "") {
        self.id = id; self.fitid = fitid; self.accountId = accountId; self.accountName = accountName
        self.date = date; self.name = name; self.amount = amount; self.typeRaw = type.rawValue
        self.category = category; self.memo = memo
    }
    var type: TransactionType { TransactionType(rawValue: typeRaw) ?? .debit }
    var isExpense: Bool { amount < 0 }
}

// Envelope budgeting: one allocation per category per month.
@Model
final class Envelope {
    var id: UUID = UUID()
    var category: String = ""
    var year: Int = 0
    var month: Int = 0
    var allocated: Double = 0

    init(id: UUID = UUID(), category: String, year: Int, month: Int, allocated: Double) {
        self.id = id; self.category = category; self.year = year; self.month = month; self.allocated = allocated
    }
    var key: String { "\(year)-\(String(format: "%02d", month))-\(category)" }
}

@Model
final class RecurringBill {
    var id: UUID = UUID()
    var name: String = ""
    var amount: Double = 0
    var dueDay: Int = 1          // 1..31; a day past the end of a short month lands on its last day
    var category: String = ""
    var isActive: Bool = true
    var lastPaid: Date?
    // "debit" = expense/out, "credit" = income/in. Default keeps legacy rows as expenses.
    var kindRaw: String = "debit"      // "debit" | "credit" | "transfer"
    /// For transfers: OFX accountIds the money leaves and arrives in. Nil otherwise.
    var fromAccountId: String? = nil
    var toAccountId: String? = nil
    /// "monthly" | "semimonthly" | "weekly" | "biweekly" (see ScheduleFrequency). Existing rows are monthly.
    var frequencyRaw: String = "monthly"
    /// Second day of the month for twice-a-month schedules.
    var secondDay: Int = 15
    /// A date a weekly / every-2-weeks schedule lands on; the repeat counts from it.
    var anchorDate: Date? = nil
    /// Occurrences already dealt with: "yyyy-MM-dd|e" (entered) or "|s" (skipped), comma separated.
    var occurrenceLogRaw: String = ""
    /// Account used last time this schedule was entered (default for next time).
    var accountId: String? = nil
    /// Payments dated before this day are never treated as overdue (set when the schedule is created).
    var trackedSince: Date? = nil
    /// Last day this schedule can land on (nil = repeats forever), e.g. the final payment of a loan.
    var endDate: Date? = nil

    init(id: UUID = UUID(), name: String, amount: Double, dueDay: Int, category: String, isActive: Bool = true, isIncome: Bool = false) {
        self.id = id; self.name = name; self.amount = amount; self.dueDay = dueDay
        self.category = category; self.isActive = isActive
        self.kindRaw = isIncome ? "credit" : "debit"
    }
    var isIncome: Bool { kindRaw == "credit" }
    var isTransfer: Bool { kindRaw == "transfer" }
    var isExpense: Bool { !isIncome && !isTransfer }
    /// + income, - expense. A transfer has no direction on its own, so this is its positive size.
    var signedAmount: Double { isIncome || isTransfer ? abs(amount) : -abs(amount) }
}

@Model
final class OFXProfile {
    var id: UUID = UUID()
    var bankName: String = ""
    var ofxHomeURL: String = ""   // e.g. https://ofx.example.com/OFXHome.axd
    var username: String = ""
    var accountId: String = ""
    var clientUID: String = ""    // generated per profile
    var lastSync: Date?

    init(id: UUID = UUID(), bankName: String, ofxHomeURL: String, username: String, accountId: String) {
        self.id = id; self.bankName = bankName; self.ofxHomeURL = ofxHomeURL
        self.username = username; self.accountId = accountId
        self.clientUID = UUID().uuidString
    }
}

// Plain DTOs used by OFX layer (not persisted directly)
struct OFXTransaction: Identifiable, Hashable {
    var id: String { fitid }
    let fitid: String
    let accountId: String
    let date: Date
    let name: String
    let amount: Double
    let type: TransactionType
    let memo: String
}

struct ParsedOFXFile {
    var bankId: String
    var accountId: String
    var accountName: String
    var balance: Double?
    var transactions: [OFXTransaction]
    /// Financial institution from the file's <FI> block, when present.
    /// These identify the bank (e.g. for looking up its OFX server) but are not a server URL.
    var institutionOrg: String? = nil
    var institutionFid: String? = nil
    /// True when the statement was a credit card statement (CCSTMTRS).
    var isCreditCard: Bool = false
}

struct MonthlySummary {
    var income: Double
    var expenses: Double
    var net: Double
}

// MARK: - Cash-flow forecast DTOs (plain values, not persisted; actuals come from SwiftData)

struct ForecastEvent: Identifiable {
    let id: UUID
    let date: Date          // exact due date within the month
    let name: String
    let amount: Double      // signed: + income, - expense
    let isIncome: Bool
    let category: String
    /// Moves money between your own accounts. `amount` is then its effect on the balance being
    /// shown (maybe 0); `gross` is the size of the transfer itself.
    let isTransfer: Bool
    let gross: Double
    let detail: String?     // e.g. "Checking → Visa"
    /// The scheduled transaction (RecurringBill.id) this event comes from, when there is one.
    let billId: UUID?

    init(date: Date, name: String, amount: Double, isIncome: Bool, category: String,
         isTransfer: Bool = false, gross: Double? = nil, detail: String? = nil, billId: UUID? = nil) {
        self.billId = billId
        self.id = UUID(); self.date = date; self.name = name
        self.amount = amount; self.isIncome = isIncome; self.category = category
        self.isTransfer = isTransfer; self.gross = gross ?? abs(amount); self.detail = detail
    }
}

/// One line of what makes up a month's "Envelopes" figure.
struct EnvelopeLine: Identifiable {
    let id = UUID()
    let name: String
    let allocated: Double   // envelope size (or the trailing average for the fallback line)
    let billed: Double      // already covered by scheduled bills in the same category
    let remainder: Double   // what the forecast adds (after any pro-rating)
}

struct ForecastMonth: Identifiable {
    let id: Date            // first day of the month
    let monthDate: Date
    let openingBalance: Double
    let scheduledIncome: Double
    let scheduledExpenses: Double
    let envelopeSpend: Double   // variable remainder after subtracting same-category bills
    var totalExpenses: Double { scheduledExpenses + envelopeSpend }
    let net: Double
    let closingBalance: Double
    let intraMonthLow: Double   // lowest balance mid-month after timing events by dueDay
    let events: [ForecastEvent]
    var envelopeLines: [EnvelopeLine] = []
    /// Share of the month still ahead (1 = whole month); envelope lines are scaled by this.
    var envelopeScale: Double = 1

    var goesNegative: Bool { closingBalance < 0 || intraMonthLow < 0 }

    init(monthDate: Date, openingBalance: Double, scheduledIncome: Double, scheduledExpenses: Double,
         envelopeSpend: Double, net: Double, closingBalance: Double, intraMonthLow: Double,
         events: [ForecastEvent], envelopeLines: [EnvelopeLine] = [], envelopeScale: Double = 1) {
        self.envelopeLines = envelopeLines; self.envelopeScale = envelopeScale
        self.id = monthDate; self.monthDate = monthDate
        self.openingBalance = openingBalance; self.scheduledIncome = scheduledIncome
        self.scheduledExpenses = scheduledExpenses; self.envelopeSpend = envelopeSpend
        self.net = net; self.closingBalance = closingBalance
        self.intraMonthLow = intraMonthLow; self.events = events
    }
}

struct ForecastOptions {
    var months: Int
    var includeEnvelopes: Bool
    var fallbackAverageVariable: Bool
    var inferIncomeFromHistory: Bool
    var startingBalance: Double
    var from: Date

    init(months: Int = 12, includeEnvelopes: Bool = true, fallbackAverageVariable: Bool = true,
         inferIncomeFromHistory: Bool = true, startingBalance: Double, from: Date = Date()) {
        self.months = months; self.includeEnvelopes = includeEnvelopes
        self.fallbackAverageVariable = fallbackAverageVariable
        self.inferIncomeFromHistory = inferIncomeFromHistory
        self.startingBalance = startingBalance; self.from = from
    }
}

// MARK: - Balances as of today

/// An account's balance includes transactions you've booked ahead of time (dated after today).
/// `BalanceBook` takes those out, so a bank's balance reads as it stands today.
struct BalanceBook {
    private let ahead: [String: Double]
    init(transactions: [TransactionRecord], today: Date = Date(), calendar: Calendar = .current) {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today)) ?? today
        var m: [String: Double] = [:]
        for t in transactions where t.date >= tomorrow { m[t.accountId, default: 0] += t.amount }
        ahead = m
    }
    /// Sum of the future-dated amounts booked in an account.
    func booked(ahead id: String) -> Double { ahead[id] ?? 0 }
    func today(_ a: Account) -> Double { a.balance - (ahead[a.accountId] ?? 0) }
    func today(_ accounts: [Account]) -> Double { accounts.reduce(0) { $0 + today($1) } }
}

// MARK: - User-defined categories

/// A category the user added on top of `BudgetService.defaultCategories`.
@Model
final class CustomCategory {
    var name: String = ""
    var createdAt: Date = Date()

    init(name: String, createdAt: Date = Date()) {
        self.name = name; self.createdAt = createdAt
    }
}
