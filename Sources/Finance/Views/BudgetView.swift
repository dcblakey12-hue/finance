import SwiftUI
import SwiftData

struct BudgetView: View {
    @Query(sort: \TransactionRecord.date, order: .reverse) var transactions: [TransactionRecord]
    @Query var envelopes: [Envelope]
    @Query var schedules: [RecurringBill]
    @Query var accounts: [Account]
    @Query var customCategories: [CustomCategory]
    @Environment(\.modelContext) private var context

    /// Opens Transactions pre-filtered (Income / Spent cards, on double-click).
    var onOpenTransactions: (TransactionFilters) -> Void = { _ in }

    @State private var now = Date()
    @State private var editAmounts: [String: String] = [:]
    @State private var editedCategory: String = ""
    @State private var applied: Int?

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
    private var scheduleItems: [ScheduleItem] { schedules.filter(\.isActive).map(\.item) }
    private var scheduledByCategory: [String: Double] { BudgetSync.scheduledExpenses(scheduleItems) }
    private var scheduledIncome: Double { BudgetSync.scheduledIncome(scheduleItems) }
    /// Spending and income leave out accounts excluded from cash flow (e.g. a mortgage's escrow).
    private var flowTransactions: [TransactionRecord] { CashFlowScope.transactions(transactions, accounts: accounts) }
    var summary: MonthlySummary {
        BudgetService.summary(year: year, month: month, transactions: flowTransactions, incomeAccountIds: checkingAccountIds)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Envelope Budget — \(monthShort)").font(.largeTitle.bold())
                    Spacer()
                    Button("‹") { now = Calendar.current.date(byAdding: .month, value: -1, to: now)! }
                        .help("Previous month")
                    Picker("Month", selection: monthBinding) {
                        ForEach(monthOptions, id: \.self) { Text(Self.monthLabel($0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    Button("›") { now = Calendar.current.date(byAdding: .month, value: 1, to: now)! }
                        .help("Next month")
                }
                HStack(spacing: 16) {
                    KpiCard(title: checkingAccountIds == nil ? "Income" : "Income (checking)", value: currency.string(from: NSNumber(value: summary.income)) ?? "", icon: "arrow.down.circle",
                            onDoubleClick: {
                                onOpenTransactions(TransactionFilters(accountIds: checkingAccountIds, month: selectedMonthStart, flow: .income))
                            })
                    KpiCard(title: "Spent", value: currency.string(from: NSNumber(value: summary.expenses)) ?? "", icon: "arrow.up.circle",
                            onDoubleClick: {
                                onOpenTransactions(TransactionFilters(month: selectedMonthStart, flow: .spending))
                            })
                    KpiCard(title: "Balance (income − spent)", value: currency.string(from: NSNumber(value: summary.net)) ?? "", icon: "scalemass")
                    KpiCard(title: scheduledIncome > summary.income ? "Left to budget (planned income)" : "Left to budget", value: currency.string(from: NSNumber(value: max(summary.income, scheduledIncome) - thisMonth.reduce(0) { $0 + $1.allocated })) ?? "", icon: "envelope")
                }
                if !schedules.isEmpty {
                    HStack {
                        Text("Scheduled each month: income \(currency.string(from: NSNumber(value: scheduledIncome)) ?? ""), bills \(currency.string(from: NSNumber(value: scheduledByCategory.values.reduce(0, +))) ?? "").")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Add scheduled bills to budget") { applied = BudgetSync.apply(in: context) }
                            .font(.caption).buttonStyle(.link)
                            .help("Raises each category's envelope to at least its scheduled bills (this month and later). Never lowers one.")
                        if let n = applied { Text(n == 0 ? "Already covered." : "Updated \(n).").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Text("Tap an amount to edit. Spent updates automatically from transactions in that category.").font(.caption).foregroundStyle(.secondary)

                ForEach(BudgetService.allCategories(stored: customCategories.map(\.name)), id: \.self) { cat in
                    let env = thisMonth.first { $0.category == cat }
                    let allocated = env?.allocated ?? 0
                    let spent = BudgetService.spent(for: cat, year: year, month: month, transactions: flowTransactions)
                    let progress = allocated > 0 ? min(spent / allocated, 1) : 0
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(cat).font(.headline)
                                if let sch = scheduledByCategory[cat] {
                                    Text("scheduled \(currency.string(from: NSNumber(value: sch)) ?? "")")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
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
    private var selectedMonthStart: Date { Calendar.current.dateInterval(of: .month, for: now)?.start ?? now }
    private var monthOptions: [Date] {
        BudgetService.monthOptions(earliest: transactions.last?.date, now: Date(), selected: selectedMonthStart)
    }
    private var monthBinding: Binding<Date> {
        Binding(get: { selectedMonthStart }, set: { now = $0 })
    }
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()
    private static func monthLabel(_ d: Date) -> String { monthFormatter.string(from: d) }

    private var monthShort: String {
        let df = DateFormatter(); df.dateFormat = "MMMM yyyy"; return df.string(from: now)
    }
    private func upsert(env: Envelope?, category: String, amount: Double) {
        if let env { env.allocated = amount }
        else { context.insert(Envelope(category: category, year: year, month: month, allocated: amount)) }
        try? context.save()
    }
}
