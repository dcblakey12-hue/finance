import SwiftUI
import SwiftData

struct DashboardView: View {
    @Query(sort: \Account.name) var accounts: [Account]
    @Query(sort: \TransactionRecord.date, order: .reverse) var transactions: [TransactionRecord]
    @Query var bills: [RecurringBill]

    var monthlySummary: MonthlySummary {
        let now = Date()
        return BudgetService.summary(year: Calendar.current.component(.year, from: now), month: Calendar.current.component(.month, from: now), transactions: transactions)
    }
    var netWorth: Double { accounts.reduce(0) { $0 + $1.balance } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Overview").font(.largeTitle.bold())
                HStack(spacing: 16) {
                    KpiCard(title: "Net worth", value: currency.string(from: NSNumber(value: netWorth)) ?? "$0", icon: "wallet.bifold")
                    KpiCard(title: "Income (this month)", value: currency.string(from: NSNumber(value: monthlySummary.income)) ?? "$0", icon: "arrow.down.circle")
                    KpiCard(title: "Spent (this month)", value: currency.string(from: NSNumber(value: monthlySummary.expenses)) ?? "$0", icon: "arrow.up.circle")
                    KpiCard(title: "Upcoming bills", value: "\(bills.filter { $0.isActive }.count)", icon: "calendar.badge.clock")
                }
                if accounts.isEmpty {
                    ContentUnavailableView(
                        "No accounts yet",
                        systemImage: "building.columns",
                        description: Text("Import an OFX file from Import & Sync to get started.")
                    )
                } else {
                    Text("Accounts").font(.headline)
                    ForEach(accounts) { a in
                        HStack {
                            VStack(alignment: .leading) { Text(a.name).font(.headline); Text("\(a.bankName) •••\(a.accountId.suffix(4))").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(currency.string(from: NSNumber(value: a.balance)) ?? "$0").font(.title3.monospacedDigit())
                        }
                        .padding(.vertical, 4)
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
