import Foundation
import SwiftData

enum AccountType: String, Codable, CaseIterable { case checking, savings, creditCard, mortgage, investment, cash }

/// Accounts of one type, for sectioned lists.
struct AccountGroup<Item> {
    let type: AccountType
    let items: [Item]
}

extension AccountType {
    /// Order sections appear in: checking first, then savings, cards, mortgage, investments, cash.
    static let displayOrder: [AccountType] = [.checking, .savings, .creditCard, .mortgage, .investment, .cash]

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
    @Attribute(.unique) var id: UUID
    var name: String
    var typeRaw: String
    var accountId: String  // OFX ACCTID
    var bankName: String
    var balance: Double

    init(id: UUID = UUID(), name: String, type: AccountType, accountId: String, bankName: String, balance: Double = 0) {
        self.id = id; self.name = name; self.typeRaw = type.rawValue
        self.accountId = accountId; self.bankName = bankName; self.balance = balance
    }
    var type: AccountType { AccountType(rawValue: typeRaw) ?? .checking }
}

@Model
final class TransactionRecord {
    @Attribute(.unique) var id: UUID
    var fitid: String       // OFX FITID - unique per bank/account
    var accountId: String
    var accountName: String
    var date: Date
    var name: String
    var amount: Double
    var typeRaw: String
    var category: String
    var memo: String
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
    @Attribute(.unique) var id: UUID
    var category: String
    var year: Int
    var month: Int
    var allocated: Double

    init(id: UUID = UUID(), category: String, year: Int, month: Int, allocated: Double) {
        self.id = id; self.category = category; self.year = year; self.month = month; self.allocated = allocated
    }
    var key: String { "\(year)-\(String(format: "%02d", month))-\(category)" }
}

@Model
final class RecurringBill {
    @Attribute(.unique) var id: UUID
    var name: String
    var amount: Double
    var dueDay: Int          // 1..28 (avoid month-end edge cases for v1)
    var category: String
    var isActive: Bool
    var lastPaid: Date?
    // "debit" = expense/out, "credit" = income/in. Default keeps legacy rows as expenses.
    var kindRaw: String = "debit"      // "debit" | "credit" | "transfer"
    /// For transfers: OFX accountIds the money leaves and arrives in. Nil otherwise.
    var fromAccountId: String? = nil
    var toAccountId: String? = nil

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
    @Attribute(.unique) var id: UUID
    var bankName: String
    var ofxHomeURL: String   // e.g. https://ofx.example.com/OFXHome.axd
    var username: String
    var accountId: String
    var clientUID: String    // generated per profile
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

    init(date: Date, name: String, amount: Double, isIncome: Bool, category: String,
         isTransfer: Bool = false, gross: Double? = nil, detail: String? = nil) {
        self.id = UUID(); self.date = date; self.name = name
        self.amount = amount; self.isIncome = isIncome; self.category = category
        self.isTransfer = isTransfer; self.gross = gross ?? abs(amount); self.detail = detail
    }
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

    var goesNegative: Bool { closingBalance < 0 || intraMonthLow < 0 }

    init(monthDate: Date, openingBalance: Double, scheduledIncome: Double, scheduledExpenses: Double,
         envelopeSpend: Double, net: Double, closingBalance: Double, intraMonthLow: Double,
         events: [ForecastEvent]) {
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

// MARK: - User-defined categories

/// A category the user added on top of `BudgetService.defaultCategories`.
@Model
final class CustomCategory {
    @Attribute(.unique) var name: String
    var createdAt: Date

    init(name: String, createdAt: Date = Date()) {
        self.name = name; self.createdAt = createdAt
    }
}
