import SwiftUI
import SwiftData

struct TransactionsView: View {
    @Query(sort: \TransactionRecord.date, order: .reverse) var transactions: [TransactionRecord]
    @State private var search = ""
    @State private var categoryFilter: String = "All"
    @State private var status: String?

    var filtered: [TransactionRecord] {
        transactions.filter { t in
            (categoryFilter == "All" || t.category == categoryFilter) &&
            (search.isEmpty || t.name.localizedCaseInsensitiveContains(search) || t.memo.localizedCaseInsensitiveContains(search))
        }
    }
    var categories: [String] { Array(Set(transactions.map { $0.category })).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search transactions", text: $search).textFieldStyle(.roundedBorder)
                Picker("Category", selection: $categoryFilter) {
                    Text("All").tag("All")
                    ForEach(categories, id: \.self) { c in Text(c).tag(c) }
                }
                Button("Auto-categorize") {
                    let n = CategorizationService.categorizeUncategorized(in: context)
                    status = n == 0 ? "No uncategorized transactions matched a rule." : "Categorized \(n) transaction\(n == 1 ? "" : "s")."
                }
                .help("Apply learned merchant rules and built-in keywords to uncategorized transactions")
            }.padding()
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.bottom, 6)
            }
            List(filtered) { tx in
                HStack {
                    VStack(alignment: .leading) {
                        Text(tx.name).font(.headline)
                        Text(tx.date, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Category", selection: Binding(
                        get: { tx.category },
                        set: { newCat in
                            guard newCat != tx.category else { return }
                            let n = CategorizationService.learn(from: tx, category: newCat, in: context)
                            if newCat != Categorizer.uncategorized {
                                let merchant = MerchantNormalizer.key(for: tx.name)
                                status = n > 0
                                    ? "Remembered \(merchant) → \(newCat) and updated \(n) other transaction\(n == 1 ? "" : "s")."
                                    : "Remembered \(merchant) → \(newCat) for future imports."
                            }
                        }
                    )) {
                        ForEach(Array(Set(BudgetService.defaultCategories + ["Income", Categorizer.uncategorized, tx.category])).sorted(), id: \.self) { c in Text(c).tag(c) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Text(currency.string(from: NSNumber(value: tx.amount)) ?? "$0")
                        .foregroundStyle(tx.isExpense ? .red : .green)
                        .monospacedDigit()
                        .frame(width: 100, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Transactions")
    }
    @Environment(\.modelContext) private var context
}
