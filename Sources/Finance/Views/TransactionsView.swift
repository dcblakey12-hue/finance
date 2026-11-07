import SwiftUI
import SwiftData

struct TransactionsView: View {
    @Query(sort: \TransactionRecord.date, order: .reverse) var transactions: [TransactionRecord]
    @State private var search = ""
    @State private var categoryFilter: String = "All"

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
            }.padding()
            List(filtered) { tx in
                HStack {
                    VStack(alignment: .leading) {
                        Text(tx.name).font(.headline)
                        Text(tx.date, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Category", selection: Binding(
                        get: { tx.category },
                        set: { newCat in tx.category = newCat; try? context.save() }
                    )) {
                        ForEach(Array(Set(BudgetService.defaultCategories + [tx.category])).sorted(), id: \.self) { c in Text(c).tag(c) }
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
