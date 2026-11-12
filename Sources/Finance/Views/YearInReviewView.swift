import SwiftUI
import SwiftData
import Charts

/// A look back at one year: money in and out, how much you kept, where it went, your biggest months,
/// how net worth moved, what subscriptions and fees cost.
struct YearInReviewView: View {
    @Query(sort: \Account.name) private var accounts: [Account]
    @Query(sort: \TransactionRecord.date, order: .reverse) private var transactions: [TransactionRecord]
    @Query private var marks: [SubscriptionMark]

    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var accountIds: Set<String>? = nil
    @State private var showAccounts = false

    /// Called with a category name and the year when a category is double-clicked.
    var onOpenCategory: (String, Int) -> Void = { _, _ in }

    var body: some View {
        let cal = Calendar.current
        let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? Date()
        let range = ReportRange.containing(start, kind: .year)
        let filter = ReportFilter(accountIds: accountIds)
        let r = ReportService.build(transactions: transactions, accounts: accounts, marks: marks, range: range, filter: filter)
        let prior = ReportService.report(rows: transactions.map(ReportRow.init), range: range.shifted(-1, kind: .year), filter: filter)
        let years = ReportService.years(in: transactions.map(ReportRow.init))
        let isThisYear = range.contains(Date())

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(String(year)) in review").font(.largeTitle.bold())
                        Text(isThisYear ? "January 1 to today" : "The whole year").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Year", selection: $year) {
                        ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                    }.labelsHidden().frame(width: 100)
                    Button { showAccounts.toggle() } label: {
                        Label(accountIds.map { "\($0.count) of \(accounts.count) accounts" } ?? "All accounts", systemImage: "building.columns")
                    }
                    .popover(isPresented: $showAccounts, arrowEdge: .bottom) {
                        MultiPicker(title: "Accounts in the review", all: accounts.map { ($0.accountId, $0.name) }, selection: $accountIds)
                    }
                }

                if r.rows.isEmpty {
                    ContentUnavailableView("No transactions in \(String(year))", systemImage: "calendar",
                                           description: Text("Pick another year, or import your history."))
                } else {
                    HStack(spacing: 14) {
                        // Only compare with last year when it has most of a year of history.
                        let comparable = prior.months.filter { $0.income > 0 || $0.spending > 0 }.count >= 9
                        KpiCard(title: "Money in", value: money(r.income), icon: "arrow.down.circle",
                                caption: comparable ? compare(r.income, prior.income) : nil)
                        KpiCard(title: "Money out", value: money(r.spending), icon: "arrow.up.circle",
                                caption: comparable ? compare(r.spending, prior.spending) : "\(money(r.averageMonthlySpending)) a month on average")
                        KpiCard(title: "Savings rate", value: r.savingsRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                                icon: "percent", caption: "Kept \(money(r.net))", tint: r.net < 0 ? .red : .green)
                        KpiCard(title: "Net worth", value: r.netWorthChange.map(signed) ?? "—", icon: "wallet.bifold",
                                caption: r.netWorthStart.flatMap { a in r.netWorthEnd.map { "\(short(a)) → \(short($0))" } },
                                tint: (r.netWorthChange ?? 0) < 0 ? .red : .green)
                    }

                    ReportCard("Money in and out, month by month") {
                        IncomeSpendingChart(months: r.months).frame(height: 190)
                        Text("Transfers between your own accounts aren't counted.").font(.caption2).foregroundStyle(.secondary)
                    }

                    HStack(alignment: .top, spacing: 14) {
                        ReportCard("Top categories") {
                            ForEach(r.byCategory.prefix(8)) { c in
                                ShareRow(name: c.category, amount: c.amount, share: r.spending > 0 ? c.amount / r.spending : 0)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { onOpenCategory(c.category, year) }
                                    .help("Double-click to see these transactions")
                            }
                        }
                        ReportCard("Top merchants") {
                            ForEach(r.byMerchant.prefix(8)) { m in
                                ShareRow(name: m.name, amount: m.amount, share: r.spending > 0 ? m.amount / r.spending : 0)
                            }
                        }
                    }

                    HStack(alignment: .top, spacing: 14) {
                        ReportCard("Biggest months") {
                            ForEach(Array(r.biggestMonths().enumerated()), id: \.offset) { i, m in
                                HStack(alignment: .firstTextBaseline) {
                                    Text("\(i + 1)").font(.title3.bold()).foregroundStyle(.secondary).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(m.month.formatted(.dateTime.month(.wide))).bold()
                                        if let top = topCategory(in: m.month, rows: r.rows) {
                                            Text("Mostly \(top.name) (\(short(top.amount)))").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(money(m.spending)).monospacedDigit()
                                }
                            }
                            Divider()
                            HStack {
                                Text("Average month").foregroundStyle(.secondary)
                                Spacer()
                                Text(money(r.averageMonthlySpending)).monospacedDigit()
                            }.font(.callout)
                        }
                        ReportCard("Subscriptions") {
                            HStack {
                                Text("Paid in \(String(year))").foregroundStyle(.secondary)
                                Spacer()
                                Text(money(r.subscriptionsPaid)).bold().monospacedDigit()
                            }
                            HStack {
                                Text("\(r.subscriptionCount) still running, per year").foregroundStyle(.secondary)
                                Spacer()
                                Text(money(r.subscriptionsAnnual)).monospacedDigit()
                            }
                            Text("From recurring charges the app found (minus any you dismissed). Review them under Subscriptions.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        ReportCard("Fees and interest") {
                            HStack {
                                Text("Paid in \(String(year))").foregroundStyle(.secondary)
                                Spacer()
                                Text(money(r.feesTotal)).bold().monospacedDigit().foregroundStyle(r.feesTotal > 0 ? .red : .primary)
                            }
                            if r.fees.isEmpty {
                                Text("None found. Nice.").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(r.fees.prefix(5)) { t in
                                HStack {
                                    Text(t.date, format: .dateTime.month(.abbreviated).day()).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                                    Text(t.name).lineLimit(1)
                                    Spacer()
                                    Text(money(-t.amount)).monospacedDigit()
                                }.font(.caption)
                            }
                            if r.fees.count > 5 { Text("and \(r.fees.count - 5) more (see Reports)").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Year in Review")
        .toolbar {
            ToolbarItem {
                ReportExportMenu(report: r, title: "\(String(year)) in Review",
                                 filterLine: ReportService.filterLine(filter, accounts: accounts), accounts: accounts, yearInReview: true)
            }
        }
    }

    private func short(_ v: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.maximumFractionDigits = 0; f.locale = .current
        return f.string(from: NSNumber(value: v)) ?? ""
    }

    /// "12% more than 2025", or nil when there's nothing to compare with.
    private func compare(_ now: Double, _ before: Double) -> String? {
        guard before > 0 else { return nil }
        let change = (now - before) / before * 100
        if abs(change) < 0.5 { return "About the same as \(String(year - 1))" }
        return String(format: "%.0f%% %@ than %@", abs(change), change > 0 ? "more" : "less", String(year - 1))
    }

    private func topCategory(in month: Date, rows: [ReportRow]) -> (name: String, amount: Double)? {
        var totals: [String: Double] = [:]
        for t in rows where !t.isTransfer && t.amount < 0 && Calendar.current.isDate(t.date, equalTo: month, toGranularity: .month) {
            totals[t.category, default: 0] -= t.amount
        }
        return totals.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
}
