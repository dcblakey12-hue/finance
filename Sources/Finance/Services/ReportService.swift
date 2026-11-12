import Foundation

// MARK: - Reports: a date range, optional account / category filters, and what happened in it.
// Plain values only, so the maths can be tested without SwiftData and shared with the iPhone.

/// The kind of date range a report covers.
enum ReportPeriodKind: String, CaseIterable, Identifiable {
    case month = "Month", quarter = "Quarter", year = "Year", custom = "Custom"
    var id: String { rawValue }
}

/// A half-open date range [start, end) with a readable label.
struct ReportRange: Equatable {
    let start: Date
    let end: Date
    let label: String

    /// The month, quarter or year that contains `anchor`.
    static func containing(_ anchor: Date, kind: ReportPeriodKind, calendar: Calendar = .current) -> ReportRange {
        let year = calendar.component(.year, from: anchor)
        switch kind {
        case .month:
            let i = calendar.dateInterval(of: .month, for: anchor)!
            return ReportRange(start: i.start, end: i.end, label: anchor.formatted(.dateTime.month(.wide).year()))
        case .quarter:
            let m = calendar.component(.month, from: anchor)
            let q = (m - 1) / 3
            let start = calendar.date(from: DateComponents(year: year, month: q * 3 + 1, day: 1))!
            let end = calendar.date(byAdding: .month, value: 3, to: start)!
            return ReportRange(start: start, end: end, label: "Q\(q + 1) \(year)")
        case .year, .custom:
            let i = calendar.dateInterval(of: .year, for: anchor)!
            return ReportRange(start: i.start, end: i.end, label: String(year))
        }
    }

    /// From the start of `from`'s day to the end of `through`'s day.
    static func custom(from: Date, through: Date, calendar: Calendar = .current) -> ReportRange {
        let a = calendar.startOfDay(for: min(from, through))
        let b = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, through)))!
        let f = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        return ReportRange(start: a, end: b, label: "\(a.formatted(f)) – \(max(from, through).formatted(f))")
    }

    /// The same kind of range just before (offset -1) or after (+1) this one.
    func shifted(_ offset: Int, kind: ReportPeriodKind, calendar: Calendar = .current) -> ReportRange {
        switch kind {
        case .month: return .containing(calendar.date(byAdding: .month, value: offset, to: start)!, kind: .month, calendar: calendar)
        case .quarter: return .containing(calendar.date(byAdding: .month, value: 3 * offset, to: start)!, kind: .quarter, calendar: calendar)
        case .year: return .containing(calendar.date(byAdding: .year, value: offset, to: start)!, kind: .year, calendar: calendar)
        case .custom:
            let days = calendar.dateComponents([.day], from: start, to: end).day ?? 1
            let s = calendar.date(byAdding: .day, value: days * offset, to: start)!
            let e = calendar.date(byAdding: .day, value: days * offset - 1, to: end)!
            return .custom(from: s, through: e, calendar: calendar)
        }
    }

    func contains(_ d: Date) -> Bool { d >= start && d < end }
}

/// What a report includes. Nil = everything.
struct ReportFilter: Equatable {
    var accountIds: Set<String>? = nil
    var categories: Set<String>? = nil
    var isEmpty: Bool { accountIds == nil && categories == nil }
}

/// One transaction, as plain values.
struct ReportRow: Identifiable, Equatable {
    var id: UUID = UUID()
    var date: Date
    var name: String
    var amount: Double
    var category: String = Categorizer.uncategorized
    var accountId: String = ""
    var accountName: String = ""
    /// Linked to the other side of a transfer between your accounts.
    var isLinkedTransfer: Bool = false

    /// Money moving between your own accounts: left out of income and spending.
    var isTransfer: Bool { isLinkedTransfer || category == Categorizer.transfer }
}

struct MerchantSpend: Identifiable, Equatable {
    let name: String
    let amount: Double   // positive total spent
    let count: Int
    var id: String { name }
}

struct ReportMonth: Identifiable, Equatable {
    let month: Date      // first day of the month
    let income: Double
    let spending: Double
    var net: Double { income - spending }
    var id: Date { month }
}

struct PeriodReport {
    let range: ReportRange
    let filter: ReportFilter
    let income: Double
    let spending: Double
    var net: Double { income - spending }
    /// Share of income kept (nil when there was no income).
    var savingsRate: Double? { income > 0 ? net / income : nil }
    let byCategory: [CategorySpend]
    let byMerchant: [MerchantSpend]
    let months: [ReportMonth]
    /// Bank fees and interest you paid, newest first.
    let fees: [ReportRow]
    var feesTotal: Double { fees.reduce(0) { $0 + abs($1.amount) } }
    /// Net worth at the start and end of the range (nil when a category filter makes it meaningless).
    let netWorthStart: Double?
    let netWorthEnd: Double?
    var netWorthChange: Double? {
        guard let a = netWorthStart, let b = netWorthEnd else { return nil }
        return b - a
    }
    /// Paid to recurring subscriptions in the range, and what the ones still running cost a year.
    var subscriptionsPaid: Double = 0
    var subscriptionsAnnual: Double = 0
    var subscriptionCount: Int = 0
    /// Every transaction in the range that passes the filter (transfers included), newest first.
    let rows: [ReportRow]

    /// Months with the most spending, biggest first.
    func biggestMonths(_ n: Int = 3) -> [ReportMonth] {
        Array(months.filter { $0.spending > 0 }.sorted { $0.spending > $1.spending }.prefix(n))
    }
    var averageMonthlySpending: Double {
        let counted = months.filter { $0.income > 0 || $0.spending > 0 }
        return counted.isEmpty ? 0 : spending / Double(counted.count)
    }
}

enum ReportService {
    /// Words that mark a charge as a fee or interest (matched as whole words in the payee).
    static let feeWords: Set<String> = ["FEE", "FEES", "INTEREST", "OVERDRAFT", "NSF"]
    static let feePhrases = ["FINANCE CHARGE", "SERVICE CHARGE"]

    /// A bank fee or interest charge: money out, not a transfer, and either in a fees / interest
    /// category or with a payee like "MONTHLY SERVICE FEE" or "INTEREST CHARGE ON PURCHASES".
    static func isFeeOrInterest(_ r: ReportRow) -> Bool {
        guard r.amount < 0, !r.isTransfer else { return false }
        let cat = r.category.lowercased()
        if cat.contains("fee") || cat.contains("interest") { return true }
        let upper = r.name.uppercased()
        if feePhrases.contains(where: { upper.contains($0) }) { return true }
        let words = upper.split(whereSeparator: { !$0.isLetter })
        return words.contains { feeWords.contains(String($0)) }
    }

    /// Readable merchant for grouping ("SQ *CORNER BISTRO 1234" → "Corner Bistro").
    static func merchant(_ name: String) -> String {
        let key = MerchantNormalizer.key(for: name)
        return key.isEmpty ? name : SubscriptionService.displayName(key)
    }

    /// Build a report.
    /// - Parameters:
    ///   - rows: every transaction (all accounts); the filter is applied here.
    ///   - netWorthToday: today's net worth of the accounts in the filter (nil to skip net worth).
    static func report(rows all: [ReportRow], range: ReportRange, filter: ReportFilter = ReportFilter(),
                       netWorthToday: Double? = nil, subscriptions: [DetectedSubscription] = [],
                       today: Date = Date(), calendar: Calendar = .current) -> PeriodReport {
        let inAccounts = all.filter { filter.accountIds?.contains($0.accountId) ?? true }
        let rows = inAccounts.filter { range.contains($0.date) && (filter.categories?.contains($0.category) ?? true) }
            .sorted { $0.date > $1.date }

        var income = 0.0, spending = 0.0
        var cats: [String: (Double, Int)] = [:]
        var merchants: [String: (Double, Int)] = [:]
        var monthly: [Date: (Double, Double)] = [:]
        for r in rows where !r.isTransfer {
            let m = calendar.dateInterval(of: .month, for: r.date)!.start
            var mt = monthly[m] ?? (0, 0)
            if r.amount < 0 {
                spending += -r.amount
                mt.1 += -r.amount
                let c = cats[r.category] ?? (0, 0); cats[r.category] = (c.0 - r.amount, c.1 + 1)
                let key = merchant(r.name)
                let mm = merchants[key] ?? (0, 0); merchants[key] = (mm.0 - r.amount, mm.1 + 1)
            } else {
                income += r.amount
                mt.0 += r.amount
            }
            monthly[m] = mt
        }
        // Every month in the range shows, even an empty one (but not months after today).
        var months: [ReportMonth] = []
        var m = calendar.dateInterval(of: .month, for: range.start)!.start
        let last = min(range.end, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today))!)
        while m < last {
            let v = monthly[m] ?? (0, 0)
            months.append(ReportMonth(month: m, income: v.0, spending: v.1))
            m = calendar.date(byAdding: .month, value: 1, to: m)!
        }

        // Net worth: work back from today by undoing everything posted since (as the dashboard does).
        var nwStart: Double?, nwEnd: Double?
        if let netWorthToday, filter.categories == nil {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today))!
            let posted = inAccounts.filter { $0.date < tomorrow }
            func value(before d: Date) -> Double {
                netWorthToday - posted.filter { $0.date >= d }.reduce(0) { $0 + $1.amount }
            }
            if range.start < tomorrow {
                nwStart = value(before: range.start)
                nwEnd = value(before: min(range.end, tomorrow))
            }
        }

        // Subscriptions: what was paid to them in the range, and the yearly cost of the ones still running.
        let counted = subscriptions.filter { $0.status != .dismissed }
            .filter { s in filter.accountIds?.contains(s.accountId) ?? true }
            .filter { s in filter.categories?.contains(s.category) ?? true }
        let subIds = Set(counted.flatMap(\.transactionIds))
        let subsPaid = rows.filter { subIds.contains($0.id) }.reduce(0) { $0 - $1.amount }
        let running = counted.filter { !$0.mayHaveStopped }

        var report = PeriodReport(
            range: range, filter: filter, income: income, spending: spending,
            byCategory: cats.map { CategorySpend(category: $0.key, amount: $0.value.0, count: $0.value.1) }
                .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.category < $1.category },
            byMerchant: merchants.map { MerchantSpend(name: $0.key, amount: $0.value.0, count: $0.value.1) }
                .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.name < $1.name },
            months: months,
            fees: rows.filter(isFeeOrInterest),
            netWorthStart: nwStart, netWorthEnd: nwEnd,
            rows: rows)
        report.subscriptionsPaid = subsPaid
        report.subscriptionsAnnual = running.reduce(0) { $0 + $1.annualCost }
        report.subscriptionCount = running.count
        return report
    }

    /// Years that have transactions, newest first (always includes this year).
    static func years(in rows: [ReportRow], today: Date = Date(), calendar: Calendar = .current) -> [Int] {
        var ys = Set(rows.map { calendar.component(.year, from: $0.date) })
        ys.insert(calendar.component(.year, from: today))
        return ys.sorted(by: >)
    }

    // MARK: - CSV

    /// A spreadsheet-friendly CSV: a summary block, then categories, merchants, months and every transaction.
    static func csv(_ r: PeriodReport, accountNames: [String] = [], categoryNames: [String] = []) -> String {
        var lines: [String] = []
        func row(_ fields: [String]) { lines.append(fields.map(escape).joined(separator: ",")) }
        func n(_ v: Double) -> String { String(format: "%.2f", v) }
        func iso(_ d: Date) -> String {
            let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }

        row(["Report", r.range.label])
        row(["From", iso(r.range.start)])
        row(["Through", iso(r.range.end.addingTimeInterval(-1))])
        row(["Accounts", accountNames.isEmpty ? "All" : accountNames.joined(separator: "; ")])
        row(["Categories", categoryNames.isEmpty ? "All" : categoryNames.joined(separator: "; ")])
        lines.append("")
        row(["Summary", "Amount"])
        row(["Income", n(r.income)])
        row(["Spending", n(r.spending)])
        row(["Net", n(r.net)])
        if let s = r.savingsRate { row(["Savings rate", String(format: "%.1f%%", s * 100)]) }
        if let a = r.netWorthStart, let b = r.netWorthEnd {
            row(["Net worth at start", n(a)]); row(["Net worth at end", n(b)]); row(["Net worth change", n(b - a)])
        }
        row(["Fees and interest", n(r.feesTotal)])
        row(["Paid to subscriptions", n(r.subscriptionsPaid)])
        row(["Subscriptions, yearly cost now", n(r.subscriptionsAnnual)])
        lines.append("")
        row(["Month", "Income", "Spending", "Net"])
        for m in r.months {
            let c = Calendar.current.dateComponents([.year, .month], from: m.month)
            row([String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0), n(m.income), n(m.spending), n(m.net)])
        }
        lines.append("")
        row(["Category", "Spent", "Transactions"])
        for c in r.byCategory { row([c.category, n(c.amount), String(c.count)]) }
        lines.append("")
        row(["Merchant", "Spent", "Transactions"])
        for m in r.byMerchant { row([m.name, n(m.amount), String(m.count)]) }
        lines.append("")
        row(["Date", "Payee", "Category", "Account", "Amount", "Transfer"])
        for t in r.rows { row([iso(t.date), t.name, t.category, t.accountName, n(t.amount), t.isTransfer ? "yes" : ""]) }
        return lines.joined(separator: "\n") + "\n"
    }

    static func escape(_ s: String) -> String {
        // Guard against spreadsheet formulas in payee names.
        var v = s
        if let f = v.first, "=+-@".contains(f), Double(v) == nil { v = "'" + v }
        if v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }

    /// File name for an export, e.g. "Finance Report 2026.csv".
    static func fileName(_ r: PeriodReport, ext: String, yearInReview: Bool = false) -> String {
        let safe = r.range.label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(yearInReview ? "Year in Review" : "Finance Report") \(safe).\(ext)"
    }
}

extension ReportRow {
    init(_ t: TransactionRecord) {
        self.init(id: t.id, date: t.date, name: t.name, amount: t.amount, category: t.category,
                  accountId: t.accountId, accountName: t.accountName, isLinkedTransfer: t.transferPeerId != nil)
    }
}

extension ReportService {
    /// Build a report straight from stored data.
    static func build(transactions: [TransactionRecord], accounts: [Account], marks: [SubscriptionMark],
                      range: ReportRange, filter: ReportFilter = ReportFilter(), today: Date = Date()) -> PeriodReport {
        let included = accounts.filter { filter.accountIds?.contains($0.accountId) ?? true }
        let ids = Set(included.map(\.accountId))
        let book = BalanceBook(transactions: transactions.filter { ids.contains($0.accountId) }, today: today)
        let subs = SubscriptionService.detect(transactions: transactions, marks: marks, today: today)
        return report(rows: transactions.map(ReportRow.init), range: range, filter: filter,
                      netWorthToday: book.today(included), subscriptions: subs, today: today)
    }

    /// One line describing the filter, for exports.
    static func filterLine(_ f: ReportFilter, accounts: [Account]) -> String {
        let a = f.accountIds.map { ids in accounts.filter { ids.contains($0.accountId) }.map(\.name).sorted().joined(separator: ", ") } ?? "All accounts"
        let c = f.categories.map { $0.sorted().joined(separator: ", ") } ?? "All categories"
        return "\(a) • \(c)"
    }
}
