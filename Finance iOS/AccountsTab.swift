import SwiftUI
import SwiftData

struct AccountsTab: View {
    @Query(sort: \Account.name) private var accounts: [Account]
    @Query private var transactions: [TransactionRecord]
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
                                    }
                                    Spacer()
                                    Text(money(book.today(a))).monospacedDigit()
                                        .foregroundStyle(book.today(a) < 0 ? .red : .primary)
                                }
                            }
                        }
                    } header: {
                        HStack { Text(label(group.type)); Spacer()
                            Text(money(book.today(group.items))).monospacedDigit() }
                    }
                }
                if accounts.isEmpty {
                    ContentUnavailableView("No accounts yet", systemImage: "building.columns",
                        description: Text("Import a bank file in the Mac app and it will appear here once iCloud has synced."))
                }
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
