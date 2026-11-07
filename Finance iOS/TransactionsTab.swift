import SwiftUI
import SwiftData

/// Transaction list. Used as a tab (all accounts) or pushed from an account (accountId set).
struct TransactionsTab: View {
    var accountId: String? = nil
    var title: String = "Transactions"

    @Query(sort: \TransactionRecord.date, order: .reverse) private var transactions: [TransactionRecord]
    @Query private var customCategories: [CustomCategory]
    @Query(sort: \Account.name) private var accounts: [Account]
    @Environment(\.modelContext) private var context

    @State private var search = ""
    @State private var accountFilter: String?     // used only when not pushed from an account
    @State private var categoryFilter = "All"

    private var effectiveAccount: String? { accountId ?? accountFilter }
    private var rows: [TransactionRecord] {
        transactions.filter { t in
            if let a = effectiveAccount, t.accountId != a { return false }
            if categoryFilter != "All", t.category != categoryFilter { return false }
            if !search.isEmpty, !t.name.localizedCaseInsensitiveContains(search) { return false }
            return true
        }
    }
    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }

    var body: some View {
        if accountId == nil { NavigationStack { content } } else { content }
    }

    private var content: some View {
        List(rows.prefix(500)) { t in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(t.name).lineLimit(1)
                    Spacer()
                    Text(money(t.amount)).monospacedDigit().foregroundStyle(t.amount < 0 ? Color.primary : .green)
                }
                HStack {
                    Text(t.date, format: .dateTime.month(.abbreviated).day().year())
                    if accountId == nil { Text("• \(t.accountName)") }
                    Spacer()
                    categoryMenu(for: t)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
        .searchable(text: $search)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if accountId == nil {
                        Picker("Account", selection: $accountFilter) {
                            Text("All accounts").tag(String?.none)
                            ForEach(accounts) { Text($0.name).tag(Optional($0.accountId)) }
                        }
                    }
                    Picker("Category", selection: $categoryFilter) {
                        Text("All categories").tag("All")
                        ForEach(allCategoryChoices(customCategories), id: \.self) { Text($0).tag($0) }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            }
        }
        .overlay {
            if rows.isEmpty { ContentUnavailableView("No transactions", systemImage: "list.bullet") }
        }
    }

    private func categoryMenu(for t: TransactionRecord) -> some View {
        Menu {
            ForEach(allCategoryChoices(customCategories), id: \.self) { c in
                Button(c) { set(c, on: t) }
            }
        } label: {
            Text(t.category).padding(.horizontal, 8).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }

    /// Same behavior as the Mac app: remember the merchant and update look-alikes.
    private func set(_ category: String, on t: TransactionRecord) {
        guard category != t.category else { return }
        if t.transferPeerId != nil && category != Categorizer.transfer {
            TransferLinkService.detach(t, among: transactions)
        }
        CategorizationService.learn(from: t, category: category, in: context)
    }
}
