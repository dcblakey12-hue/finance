import SwiftUI
import SwiftData

struct TransactionsView: View {
    @Query(sort: \TransactionRecord.date, order: .reverse) var transactions: [TransactionRecord]
    @Query(sort: \Account.name) var accounts: [Account]
    @Query var customCategories: [CustomCategory]
    @Environment(\.modelContext) private var context
    /// OFX accountId to show; nil = all accounts. Owned by ContentView so
    /// double-clicking an account in Accounts can preselect it.
    @Binding var accountFilter: String?
    @State private var search = ""
    @State private var categoryFilter: String = "All"
    @State private var status: String?
    @State private var scheduleEditor: ScheduleEditor?
    /// Transaction waiting for a newly created category.
    @State private var newCategoryFor: TransactionRecord?

    var filtered: [TransactionRecord] {
        transactions.filter { t in
            (accountFilter == nil || t.accountId == accountFilter) &&
            (categoryFilter == "All" || t.category == categoryFilter) &&
            (search.isEmpty || t.name.localizedCaseInsensitiveContains(search) || t.memo.localizedCaseInsensitiveContains(search))
        }
    }
    /// Categories in use, for the filter menu.
    var usedCategories: [String] { Array(Set(transactions.map { $0.category })).sorted() }
    /// Every category a transaction can be set to.
    var assignableCategories: [String] {
        BudgetService.allCategories(custom: customCategories.map(\.name)) + ["Income", Categorizer.uncategorized]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Account", selection: $accountFilter) {
                    Text("All accounts").tag(String?.none)
                    ForEach(accounts) { a in Text(a.name).tag(String?.some(a.accountId)) }
                }
                .frame(maxWidth: 220)
                TextField("Search transactions", text: $search).textFieldStyle(.roundedBorder)
                Picker("Category", selection: $categoryFilter) {
                    Text("All").tag("All")
                    ForEach(usedCategories, id: \.self) { c in Text(c).tag(c) }
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
                        set: { setCategory($0, on: tx) }
                    )) {
                        ForEach(Array(Set(assignableCategories + [tx.category])).sorted(), id: \.self) { c in Text(c).tag(c) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Text(currency.string(from: NSNumber(value: tx.amount)) ?? "$0")
                        .foregroundStyle(tx.isExpense ? .red : .green)
                        .monospacedDigit()
                        .frame(width: 100, alignment: .trailing)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Schedule as Recurring…") {
                        scheduleEditor = ScheduleEditor(existing: nil, draft: ScheduleService.draft(
                            fromName: tx.name, amount: tx.amount, date: tx.date, category: tx.category))
                    }
                    Menu("Set Category") {
                        ForEach(assignableCategories, id: \.self) { c in
                            Button(c) { setCategory(c, on: tx) }
                        }
                        Divider()
                        Button("New Category…") { newCategoryFor = tx }
                    }
                }
            }
        }
        .navigationTitle(accounts.first { $0.accountId == accountFilter }?.name ?? "Transactions")
        .sheet(item: $scheduleEditor) { ed in
            ScheduleEditorSheet(editor: ed, categories: BudgetService.allCategories(custom: customCategories.map(\.name))) { draft in
                ScheduleEditor.save(draft, existing: nil, in: context)
                scheduleEditor = nil
                status = "Scheduled \(draft.name) for the \(draft.dueDay)\(ordinalSuffix(draft.dueDay)) of each month. See Scheduled Transactions."
            } onCancel: { scheduleEditor = nil }
        }
        .sheet(item: $newCategoryFor) { tx in
            NewCategorySheet(existing: BudgetService.allCategories(custom: customCategories.map(\.name))) { name in
                newCategoryFor = nil
                setCategory(name, on: tx)
            } onCancel: { newCategoryFor = nil }
        }
    }

    private func setCategory(_ newCat: String, on tx: TransactionRecord) {
        guard newCat != tx.category else { return }
        let n = CategorizationService.learn(from: tx, category: newCat, in: context)
        guard newCat != Categorizer.uncategorized else { return }
        let merchant = MerchantNormalizer.key(for: tx.name)
        status = n > 0
            ? "Remembered \(merchant) → \(newCat) and updated \(n) other transaction\(n == 1 ? "" : "s")."
            : "Remembered \(merchant) → \(newCat) for future imports."
    }

    private func ordinalSuffix(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "th" }
        switch n % 10 { case 1: return "st"; case 2: return "nd"; case 3: return "rd"; default: return "th" }
    }
}
