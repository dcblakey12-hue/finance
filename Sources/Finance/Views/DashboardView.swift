import SwiftUI
import SwiftData
import Charts

/// The overview: where you stand today (cash, net worth), what's coming (next 30 days, forecast),
/// and where the money went.
struct DashboardView: View {
    @Query(sort: \Account.name) var allAccounts: [Account]
    @Query(sort: \TransactionRecord.date, order: .reverse) var allTransactions: [TransactionRecord]
    /// Accounts the dashboard covers (comma-separated OFX accountIds; empty = all).
    @AppStorage("finance.dashboard.accountIds") private var accountIdsRaw = ""
    @State private var showAccountPicker = false
    /// The day clicked on the cash chart (start of day).
    @State private var pickedDay: Date?

    private var selectedIds: Set<String>? {
        let ids = Set(accountIdsRaw.split(separator: ",").map(String.init)).intersection(allAccounts.map(\.accountId))
        return ids.isEmpty || ids.count == allAccounts.count ? nil : ids
    }
    private func isIncluded(_ a: Account) -> Binding<Bool> {
        Binding(get: { selectedIds?.contains(a.accountId) ?? true },
                set: { on in
                    var ids = selectedIds ?? Set(allAccounts.map(\.accountId))
                    if on { ids.insert(a.accountId) } else if ids.count > 1 { ids.remove(a.accountId) }
                    accountIdsRaw = ids.count == allAccounts.count ? "" : ids.sorted().joined(separator: ",")
                })
    }
    @Query var bills: [RecurringBill]
    @Query var envelopes: [Envelope]

    /// Called with an account's OFX accountId when its row is double-clicked.
    var onOpenAccount: (String) -> Void = { _ in }
    /// Called with a category name and the selected period when a category row is double-clicked.
    var onOpenCategory: (String, DashboardPeriod) -> Void = { _, _ in }

    @AppStorage("finance.dashboard.period.v2") private var periodRaw = DashboardPeriod.last30Days.rawValue
    private var period: DashboardPeriod { DashboardPeriod(rawValue: periodRaw) ?? .last30Days }

    private static let cashTypes: Set<AccountType> = [.checking, .savings, .cash]

    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "$0" }
    private func short(_ v: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.maximumFractionDigits = 0; f.locale = .current
        return f.string(from: NSNumber(value: v)) ?? ""
    }
    private func day(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }

    var body: some View {
        // Work everything out once per redraw, for the chosen accounts only.
        let sel = selectedIds
        let accounts = allAccounts.filter { sel?.contains($0.accountId) ?? true }
        let transactions = sel == nil ? allTransactions : allTransactions.filter { sel!.contains($0.accountId) }
        let book = BalanceBook(transactions: transactions)
        let cashAccounts = accounts.filter { Self.cashTypes.contains($0.type) }
        let cashToday = book.today(cashAccounts)
        let netWorth = book.today(accounts)
        let debts = book.today(accounts.filter { $0.type == .creditCard || $0.type == .mortgage })
        let assets = netWorth - debts
        let names = Dictionary(accounts.map { ($0.accountId, $0.name) }, uniquingKeysWith: { a, _ in a })
        let cashIds = Set(cashAccounts.map(\.accountId))
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let ledger = transactions.filter { $0.date >= tomorrow }.map {
            LedgerEntry(date: $0.date, name: $0.name, amount: $0.amount, accountId: $0.accountId, category: $0.category,
                        isTransfer: $0.transferPeerId != nil || $0.category == Categorizer.transfer)
        }
        let proj = DashboardMath.projection(days: 30, schedules: bills.filter(\.isActive).map { $0.item(accountNames: names) },
                                            balanceToday: cashToday, cashAccountIds: cashIds, ledger: ledger)
        let low = proj.points.min { $0.balance < $1.balance }
        let nextPay = proj.upcoming.first { $0.isIncome }
        let overdue = ScheduleService.overdue(bills)
        let history = DashboardMath.netWorthHistory(currentTotal: netWorth, transactions: transactions.map { (date: $0.date, amount: $0.amount) }, months: 12)
        // Spending, income and the forecast leave out accounts you've excluded from cash flow
        // (e.g. a mortgage paying escrow); net worth above still counts them.
        let flowTransactions = CashFlowScope.transactions(transactions, accounts: allAccounts)
        let forecast = CashFlowForecastService.forecast(
            bills: bills, envelopes: envelopes, transactions: flowTransactions,
            options: ForecastOptions(months: 6, includeEnvelopes: true, fallbackAverageVariable: true, inferIncomeFromHistory: true,
                                     startingBalance: accounts.filter { !$0.type.isPropertyValue && $0.countsInCashFlow }.reduce(0) { $0 + $1.balance }),
            accountIds: CashFlowScope.accountIds(selected: sel, accounts: allAccounts))
        let rows: [SpendingReport.Row] = flowTransactions.map { ($0.category, $0.amount, $0.date) }
        let totals = SpendingReport.totals(rows, period: period)
        let spend = SpendingReport.byCategory(rows, period: period)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Overview").font(.largeTitle.bold())
                    Spacer()
                    Button { showAccountPicker.toggle() } label: {
                        Label(sel == nil ? "All accounts" : "\(accounts.count) of \(allAccounts.count) accounts", systemImage: "checklist")
                    }
                    .popover(isPresented: $showAccountPicker, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Show on the dashboard").font(.headline)
                            ForEach(allAccounts) { a in Toggle(a.name, isOn: isIncluded(a)) }
                            Divider()
                            Button("All accounts") { accountIdsRaw = "" }.disabled(sel == nil)
                        }.padding(12).frame(minWidth: 240)
                    }
                    .disabled(allAccounts.isEmpty)
                }

                if !overdue.isEmpty {
                    Label("\(overdue.count) scheduled payment\(overdue.count == 1 ? " is" : "s are") overdue — open Scheduled Transactions to enter or skip \(overdue.count == 1 ? "it" : "them").",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 14) {
                    KpiCard(title: "Cash today", value: money(cashToday), icon: "banknote",
                            caption: cashAccounts.isEmpty ? "No checking or savings accounts" : "\(cashAccounts.count) cash account\(cashAccounts.count == 1 ? "" : "s")",
                            tint: cashToday < 0 ? .red : nil)
                    KpiCard(title: "Net worth", value: money(netWorth), icon: "wallet.bifold",
                            caption: "Assets \(short(assets)) • Debts \(short(debts))")
                    KpiCard(title: "Lowest in 30 days", value: low.map { money($0.balance) } ?? "—", icon: "arrow.down.circle",
                            caption: low.map { "on \(day($0.date))" } ?? "Add scheduled items to see this",
                            tint: (low?.balance ?? 0) < 0 ? .red : nil)
                    KpiCard(title: "Next payday", value: nextPay.map { money($0.amount) } ?? "—", icon: "arrow.down.circle.fill",
                            caption: nextPay.map { "\($0.name) • \(day($0.date))" } ?? "None scheduled in 30 days")
                }

                HStack(alignment: .top, spacing: 14) {
                    card("Cash — next 30 days") {
                        if proj.points.isEmpty {
                            Text("Add accounts and scheduled items to see a projection.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Chart {
                                ForEach(proj.points) { p in
                                    AreaMark(x: .value("Day", p.date, unit: .day), y: .value("Balance", p.balance))
                                        .foregroundStyle(.blue.opacity(0.15))
                                    LineMark(x: .value("Day", p.date, unit: .day), y: .value("Balance", p.balance))
                                        .interpolationMethod(.stepEnd).foregroundStyle(.blue)
                                }
                                RuleMark(y: .value("Zero", 0)).foregroundStyle(.red.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                                if let low { PointMark(x: .value("Day", low.date, unit: .day), y: .value("Balance", low.balance)).foregroundStyle(.orange) }
                                if let sel = pickedPoint(in: proj.points) {
                                    RuleMark(x: .value("Day", sel.date, unit: .day)).foregroundStyle(.secondary.opacity(0.5))
                                    PointMark(x: .value("Day", sel.date, unit: .day), y: .value("Balance", sel.balance))
                                        .symbolSize(90).foregroundStyle(.blue)
                                }
                            }
                            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(short(d)) } } } }
                            .chartOverlay { proxy in
                                GeometryReader { geo in
                                    Rectangle().fill(.clear).contentShape(Rectangle())
                                        .onTapGesture { location in
                                            guard let frame = proxy.plotFrame else { return }
                                            let x = location.x - geo[frame].origin.x
                                            if let d: Date = proxy.value(atX: x) {
                                                let day = Calendar.current.startOfDay(for: d)
                                                pickedDay = (pickedDay == day) ? nil : day
                                            }
                                        }
                                }
                            }
                            .frame(height: 170)
                            Text(pickedDay == nil ? "Click the line to see a day's balance and what moves it." : "Click the same day again, or Show all, to clear.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    card(pickedDay == nil ? "Coming up" : "Day detail") {
                        if let sel = pickedPoint(in: proj.points) {
                            dayDetail(sel, days: proj.days, points: proj.points, startBalance: cashToday)
                        } else {
                            let list = Array(proj.upcoming.prefix(8))
                            if list.isEmpty { Text("Nothing scheduled in the next 30 days.").font(.caption).foregroundStyle(.secondary) }
                            ForEach(list) { e in
                                HStack {
                                    Text(day(e.date)).font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                                    Text(e.name).lineLimit(1)
                                    Spacer()
                                    Text(money(e.isTransfer ? e.gross : e.amount)).monospacedDigit()
                                        .foregroundStyle(e.isTransfer ? .blue : (e.amount > 0 ? .green : .primary))
                                }.font(.callout)
                            }
                        }
                    }
                    .frame(width: 300)
                }

                HStack(alignment: .top, spacing: 14) {
                    card("Net worth — last 12 months") {
                        Chart(history) { p in
                            LineMark(x: .value("Date", p.date), y: .value("Net worth", p.balance)).foregroundStyle(.green)
                            PointMark(x: .value("Date", p.date), y: .value("Net worth", p.balance)).foregroundStyle(.green)
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(short(d)) } } } }
                        .frame(height: 150)
                        Text("Worked back from today's balances using your transactions.").font(.caption2).foregroundStyle(.secondary)
                    }
                    card("Balance forecast — next 6 months") {
                        if forecast.isEmpty || forecast.allSatisfy({ $0.scheduledIncome == 0 && $0.totalExpenses == 0 }) {
                            Text("Add scheduled items or import history to see a forecast.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Chart(forecast) { m in
                                BarMark(x: .value("Month", m.monthDate, unit: .month), y: .value("Closing", m.closingBalance))
                                    .foregroundStyle(m.closingBalance < 0 ? Color.red.opacity(0.6) : Color.blue.opacity(0.5))
                            }
                            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(short(d)) } } } }
                            .frame(height: 150)
                            Text("Month-end balance across all accounts. Details in Cash Flow Forecast.").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                spendingCard(totals: totals, spend: spend)

                if accounts.isEmpty {
                    ContentUnavailableView("No accounts yet", systemImage: "building.columns",
                                           description: Text("Import an OFX file or connect a bank in Settings to get started."))
                } else {
                    card("Accounts") {
                        Text("Double-click an account to see its transactions.").font(.caption).foregroundStyle(.secondary)
                        ForEach(AccountType.grouped(accounts, by: \.type), id: \.type) { group in
                            HStack {
                                Text(group.type.rawValue.capitalized).font(.caption.bold()).foregroundStyle(.secondary)
                                Spacer()
                                Text(money(book.today(group.items))).font(.caption.bold().monospacedDigit()).foregroundStyle(.secondary)
                            }.padding(.top, 4)
                            ForEach(group.items) { a in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(a.name)
                                        Text("\(a.bankName) •••\(a.accountId.suffix(4))").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(money(book.today(a))).monospacedDigit().foregroundStyle(book.today(a) < 0 ? .red : .primary)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { onOpenAccount(a.accountId) }
                                .help("Double-click to see this account's transactions")
                            }
                        }
                    }
                }

                card("Recent transactions") {
                    if transactions.isEmpty {
                        Text("Import an OFX file or sync a bank to see transactions here.").foregroundStyle(.secondary)
                    }
                    ForEach(transactions.filter { $0.date < tomorrow }.prefix(8)) { t in
                        HStack {
                            Text(t.date, format: .dateTime.month(.abbreviated).day()).font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                            Text(t.name).lineLimit(1)
                            Spacer()
                            Text(money(t.amount)).foregroundStyle(t.isExpense ? .red : .green).monospacedDigit()
                        }.font(.callout)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Dashboard")
    }

    // MARK: - Pieces

    /// The chart point for the clicked day.
    private func pickedPoint(in points: [CashPoint]) -> CashPoint? {
        guard let pickedDay else { return nil }
        return points.first { Calendar.current.isDate($0.date, inSameDayAs: pickedDay) }
    }

    /// Balance and the items that move it on one day of the cash chart.
    @ViewBuilder
    private func dayDetail(_ sel: CashPoint, days: [CalendarDay], points: [CashPoint], startBalance: Double) -> some View {
        let idx = points.firstIndex { $0.id == sel.id } ?? 0
        let opening = idx > 0 ? points[idx - 1].balance : startBalance
        let events = (days.first { Calendar.current.isDate($0.date, inSameDayAs: sel.date) }?.events ?? [])
            .filter { $0.amount != 0 || $0.isTransfer }
        HStack {
            Text(sel.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.subheadline.bold())
            Spacer()
            Button("Show all") { pickedDay = nil }.buttonStyle(.link).font(.caption)
        }
        HStack {
            Text("Balance").foregroundStyle(.secondary)
            Spacer()
            Text(money(sel.balance)).bold().monospacedDigit().foregroundStyle(sel.balance < 0 ? .red : .primary)
        }.font(.callout)
        if idx > 0 || !events.isEmpty {
            Text(idx == 0 ? "Starting from \(money(opening)) today" : "Previous day \(money(opening))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        Divider()
        if events.isEmpty {
            Text("Nothing moves the balance on this day.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(events) { e in
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.name).lineLimit(1)
                    if let d = e.detail { Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Text(money(e.amount)).monospacedDigit().foregroundStyle(e.amount > 0 ? .green : .primary)
            }.font(.callout)
        }
    }


    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Where the money went, kept short: one stacked bar plus the top categories as chips.
    private func spendingCard(totals: (income: Double, expenses: Double), spend: [CategorySpend]) -> some View {
        let top = Array(spend.prefix(6))
        let rest = spend.dropFirst(6).reduce(0) { $0 + $1.amount }
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .gray]
        let slices: [(name: String, amount: Double)] = top.map { ($0.category, $0.amount) } + (rest > 0 ? [("Other categories", rest)] : [])
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Where the money went").font(.headline)
                Spacer()
                Text("Income \(money(totals.income)) • Spent \(money(totals.expenses))").font(.caption).foregroundStyle(.secondary)
                Picker("Period", selection: $periodRaw) {
                    ForEach(DashboardPeriod.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }.labelsHidden().frame(width: 130)
            }
            if spend.isEmpty {
                Text("No spending in this period.").font(.caption).foregroundStyle(.secondary)
            } else {
                Chart(Array(slices.enumerated()), id: \.offset) { i, s in
                    BarMark(x: .value("Spent", s.amount)).foregroundStyle(palette[min(i, palette.count - 1)])
                }
                .chartXAxis(.hidden).chartLegend(.hidden).frame(height: 18)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 4) {
                    ForEach(Array(slices.enumerated()), id: \.offset) { i, s in
                        HStack(spacing: 6) {
                            Circle().fill(palette[min(i, palette.count - 1)]).frame(width: 8, height: 8)
                            Text(s.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(short(s.amount)).monospacedDigit().foregroundStyle(.secondary)
                            if totals.expenses > 0 { Text(String(format: "%.0f%%", s.amount / totals.expenses * 100)).font(.caption2).foregroundStyle(.secondary) }
                        }
                        .font(.caption)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if i < top.count { onOpenCategory(top[i].category, period) } }
                        .help(i < top.count ? "Double-click to see these transactions" : "")
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct KpiCard: View {
    let title: String, value: String, icon: String
    /// When set, double-clicking the card calls this.
    var onDoubleClick: (() -> Void)? = nil
    /// Small line under the value.
    var caption: String? = nil
    var tint: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit()).foregroundStyle(tint ?? .primary)
            if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(count: 2) { onDoubleClick?() }
        .help(onDoubleClick == nil ? "" : "Double-click to see these transactions")
    }
}
