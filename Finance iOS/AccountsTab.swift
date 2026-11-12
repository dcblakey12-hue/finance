import SwiftUI
import SwiftData

struct AccountsTab: View {
    @Query(sort: \Account.name) private var accounts: [Account]
    @Query private var transactions: [TransactionRecord]
    @Environment(\.modelContext) private var context
    private var book: BalanceBook { BalanceBook(transactions: transactions) }

    private var groups: [AccountGroup<Account>] { AccountType.grouped(accounts, by: { $0.type }) }
    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.type) { group in
                    Section {
                        ForEach(group.items) { a in
                            NavigationLink {
                                TransactionsTab(accountId: a.accountId, title: a.name)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(a.name)
                                        if !a.bankName.isEmpty { Text(a.bankName).font(.caption).foregroundStyle(.secondary) }
                                        if let sync = PlaidSyncStatus(a) {
                                            HStack(spacing: 3) {
                                                if sync.isWarning { Image(systemName: "exclamationmark.triangle.fill") }
                                                Text(sync.summary())
                                            }
                                            .font(.caption2).foregroundStyle(sync.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                        }
                                        if !a.countsInCashFlow {
                                            Text("Not in spending or cash flow").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(money(book.today(a))).monospacedDigit()
                                        .foregroundStyle(book.today(a) < 0 ? .red : .primary)
                                }
                            }
                            .contextMenu {
                                if let sync = PlaidSyncStatus(a) {
                                    Section {
                                        Text(sync.detail())
                                        if let p = sync.problem { Text(p.message + " Fix it in Finance on your Mac.") }
                                    }
                                }
                                Toggle("Include in spending & cash flow", isOn: Binding(
                                    get: { a.countsInCashFlow }, set: { a.countsInCashFlow = $0; try? context.save() }))
                            }
                        }
                    } header: {
                        HStack { Text(label(group.type)); Spacer()
                            Text(money(book.today(group.items))).monospacedDigit() }
                    }
                }
                if !accounts.isEmpty {
                    Section {} footer: {
                        Text("Touch and hold an account to choose whether it counts in spending and cash flow, or to see details of its last bank sync. Net worth always includes every account.")
                    }
                }
                if accounts.isEmpty {
                    ContentUnavailableView("No accounts yet", systemImage: "building.columns",
                        description: Text("Import a bank file in the Mac app and it will appear here once iCloud has synced."))
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text("Total balance").font(.headline)
                    Spacer()
                    let total = book.today(accounts)
                    Text(money(total)).font(.headline.monospacedDigit()).foregroundStyle(total < 0 ? .red : .primary)
                }
                .padding(.horizontal).padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle("Accounts")
        }
    }

    private func label(_ t: AccountType) -> String {
        switch t {
        case .checking: return "Checking"
        case .savings: return "Savings"
        case .creditCard: return "Credit cards"
        case .mortgage: return "Mortgage"
        case .investment: return "Investments"
        case .cash: return "Cash"
        case .property: return "Property"
        }
    }
}
