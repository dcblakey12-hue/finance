import SwiftUI
import SwiftData

struct BudgetView: View {
    @Query(sort: \TransactionRecord.date, order: .reverse) var transactions: [TransactionRecord]
    @Query var envelopes: [Envelope]
    @Query var accounts: [Account]
    @Query var customCategories: [CustomCategory]
    @Environment(\.modelContext) private var context

    @State private var now = Date()
    @State private var editAmounts: [String: String] = [:]
    @State private var editedCategory: String = ""

    var year: Int { Calendar.current.component(.year, from: now) }
    var month: Int { Calendar.current.component(.month, from: now) }
    var thisMonth: [Envelope] {
        envelopes.filter { $0.year == year && $0.month == month }.sorted { $0.category < $1.category }
    }
    /// Income comes from checking accounts only. With no checking account, every account counts.
    private var checkingAccountIds: Set<String>? {
        let ids = Set(accounts.filter { $0.type == .checking }.map(\.accountId))
        return ids.isEmpty ? nil : ids
    }
    var summary: MonthlySummary {
        BudgetService.summary(year: year, month: month, transactions: transactions, incomeAccountIds: checkingAccountIds)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Envelope Budget — \(monthShort)").font(.largeTitle.bold())
                    Spacer()
                    Button("‹") { now = Calendar.current.date(byAdding: .month, value: -1, to: now)! }
                    DatePicker("Month", selection: $now, displayedComponents: .date).labelsHidden()
                    Button("›") { now = Calendar.current.date(byAdding: .month, value: 1, to: now)! }
                }
                HStack(spacing: 16) {
                    KpiCard(title: checkingAccountIds == nil ? "Income" : "Income (checking)", value: currency.string(from: NSNumber(value: summary.income)) ?? "", icon: "arrow.down.circle")
                    KpiCard(title: "Spent", value: currency.string(from: NSNumber(value: summary.expenses)) ?? "", icon: "arrow.up.circle")
                    KpiCard(title: "Left to budget", value: currency.string(from: NSNumber(value: summary.income - thisMonth.reduce(0) { $0 + $1.allocated })) ?? "", icon: "envelope")
                }
                Text("Tap an amount to edit. Spent updates automatically from transactions in that category.").font(.caption).foregroundStyle(.secondary)

                ForEach(BudgetService.allCategories(stored: customCategories.map(\.name)), id: \.self) { cat in
                    let env = thisMonth.first { $0.category == cat }
                    let allocated = env?.allocated ?? 0
                    let spent = BudgetService.spent(for: cat, year: year, month: month, transactions: transactions)
                    let progress = allocated > 0 ? min(spent / allocated, 1) : 0
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cat).font(.headline)
                            ProgressView(value: progress).tint(spent > allocated && allocated > 0 ? .red : .accentColor)
                        }
                        Spacer()
                        Text("\(currency.string(from: NSNumber(value: spent)) ?? "") / \(currency.string(from: NSNumber(value: allocated)) ?? "")").font(.caption).monospacedDigit()
                        TextField("Allocated", text: Binding(
                            get: { editAmounts[cat] ?? (allocated == 0 ? "" : String(format: "%.0f", allocated)) },
                            set: { v in editAmounts[cat] = v; upsert(env: env, category: cat, amount: Double(v) ?? 0) }
                        )).textFieldStyle(.roundedBorder).frame(width: 90).multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, 2)
                    Divider()
                }
            }.padding()
        }
        .navigationTitle("Budget")
    }
    private var monthShort: String {
        let df = DateFormatter(); df.dateFormat = "MMMM yyyy"; return df.string(from: now)
    }
    private func upsert(env: Envelope?, category: String, amount: Double) {
        if let env { env.allocated = amount }
        else { context.insert(Envelope(category: category, year: year, month: month, allocated: amount)) }
        try? context.save()
    }
}
