import SwiftUI
import SwiftData

struct DashboardView: View {
    @Query(sort: \Account.name) var accounts: [Account]
    @Query(sort: \TransactionRecord.date, order: .reverse) var transactions: [TransactionRecord]
    @Query var bills: [RecurringBill]

    /// Called with an account's OFX accountId when its row is double-clicked.
    var onOpenAccount: (String) -> Void = { _ in }
    /// Called with a category name and the selected period when a category row is double-clicked.
    var onOpenCategory: (String, DashboardPeriod) -> Void = { _, _ in }

    @AppStorage("finance.dashboard.period") private var periodRaw = DashboardPeriod.thisMonth.rawValue
    private var period: DashboardPeriod { DashboardPeriod(rawValue: periodRaw) ?? .thisMonth }

    private var rows: [SpendingReport.Row] { transactions.map { ($0.category, $0.amount, $0.date) } }
    private var totals: (income: Double, expenses: Double) { SpendingReport.totals(rows, period: period) }
    private var categorySpend: [CategorySpend] { SpendingReport.byCategory(rows, period: period) }
    var netWorth: Double { accounts.reduce(0) { $0 + $1.balance } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Overview").font(.largeTitle.bold())
                    Spacer()
                    Picker("Period", selection: $periodRaw) {
                        ForEach(DashboardPeriod.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .frame(width: 190)
                }
                HStack(spacing: 16) {
                    KpiCard(title: "Net worth", value: currency.string(from: NSNumber(value: netWorth)) ?? "$0", icon: "wallet.bifold")
                    KpiCard(title: "Income (\(period.rawValue.lowercased()))", value: currency.string(from: NSNumber(value: totals.income)) ?? "$0", icon: "arrow.down.circle")
                    KpiCard(title: "Spent (\(period.rawValue.lowercased()))", value: currency.string(from: NSNumber(value: totals.expenses)) ?? "$0", icon: "arrow.up.circle")
                    KpiCard(title: "Upcoming bills", value: "\(bills.filter { $0.isActive }.count)", icon: "calendar.badge.clock")
                }

                Text("Spending by category — \(period.rawValue)").font(.headline)
                Text("Double-click a category to see its transactions. Transfers between your accounts (category “Transfer”) are not counted.").font(.caption).foregroundStyle(.secondary)
                if categorySpend.isEmpty {
                    Text("No spending in this period.").foregroundStyle(.secondary)
                } else {
                    let maxSpend = categorySpend.first?.amount ?? 1
                    ForEach(categorySpend) { c in
                        HStack(spacing: 12) {
                            Text(c.category)
                                .frame(width: 140, alignment: .leading)
                                .foregroundStyle(c.category == Categorizer.uncategorized ? .secondary : .primary)
                            ProgressView(value: c.amount, total: maxSpend)
                            Text("\(c.count)").font(.caption).foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                            Text(percent(c.amount)).font(.caption).foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                            Text(currency.string(from: NSNumber(value: c.amount)) ?? "")
                                .monospacedDigit()
                                .frame(width: 100, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { onOpenCategory(c.category, period) }
                        .help("Double-click to see these transactions")
                    }
                    Divider()
                    HStack {
                        Text("Total").font(.headline)
                        Spacer()
                        Text(currency.string(from: NSNumber(value: categorySpend.reduce(0) { $0 + $1.amount })) ?? "")
                            .font(.headline.monospacedDigit())
                    }
                }

                if accounts.isEmpty {
                    ContentUnavailableView(
                        "No accounts yet",
                        systemImage: "building.columns",
                        description: Text("Import an OFX file from Import & Sync to get started.")
                    )
                } else {
                    Text("Accounts").font(.headline)
                    Text("Double-click an account to see its transactions.").font(.caption).foregroundStyle(.secondary)
                    ForEach(accounts) { a in
                        HStack {
                            VStack(alignment: .leading) { Text(a.name).font(.headline); Text("\(a.bankName) •••\(a.accountId.suffix(4))").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(currency.string(from: NSNumber(value: a.balance)) ?? "$0").font(.title3.monospacedDigit())
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { onOpenAccount(a.accountId) }
                        .help("Double-click to see this account's transactions")
                    }
                }
                Text("Recent transactions").font(.headline)
                if transactions.isEmpty {
                    Text("Import an OFX file to see transactions here.").foregroundStyle(.secondary)
                } else {
                    ForEach(transactions.prefix(8)) { t in
                        HStack {
                            VStack(alignment: .leading) { Text(t.name); Text(t.date, style: .date).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(currency.string(from: NSNumber(value: t.amount)) ?? "$0")
                                .foregroundStyle(t.isExpense ? .red : .green)
                                .monospacedDigit()
                        }
                        Divider()
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Dashboard")
    }

    private func percent(_ amount: Double) -> String {
        let total = totals.expenses
        guard total > 0 else { return "" }
        return String(format: "%.0f%%", amount / total * 100)
    }
}

struct KpiCard: View {
    let title: String, value: String, icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
