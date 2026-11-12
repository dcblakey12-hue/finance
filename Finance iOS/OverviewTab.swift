import SwiftUI
import SwiftData
import Charts

/// The phone's overview: where you stand today, what the next 30 days look like (tap the chart for a
/// day's balance and what moves it), net worth over time, and where the last 30 days went.
struct OverviewTab: View {
    @Query(sort: \Account.name) private var allAccounts: [Account]
    @Query(sort: \TransactionRecord.date, order: .reverse) private var allTransactions: [TransactionRecord]
    @Query private var bills: [RecurringBill]
    @Query private var subscriptionMarks: [SubscriptionMark]

    /// Accounts the overview covers (comma-separated accountIds; empty = all).
    @AppStorage("overview.accountIds") private var accountIdsRaw = ""
    @State private var pickedDay: Date?
    @StateObject private var cloud = CloudSyncMonitor()
    @Environment(\.modelContext) private var context
    /// Your card order, saved on this phone (comma separated OverviewCard names).
    @AppStorage("overviewCardOrder") private var cardOrderRaw = ""
    @State private var reorderingCards = false
    @AppStorage(DemoMode.flagKey, store: .standard) private var demo = false
    @State private var confirmingDemo = false
    private var cardOrder: [OverviewCard] {
        let saved = cardOrderRaw.split(separator: ",").compactMap { OverviewCard(rawValue: String($0)) }
        var seen = Set<OverviewCard>(), out: [OverviewCard] = []
        for c in saved where !seen.contains(c) { seen.insert(c); out.append(c) }
        for c in OverviewCard.allCases where !seen.contains(c) { out.append(c) }
        return out
    }
    /// Opens the tab-order sheet (provided by the root view).
    var onReorderTabs: () -> Void = {}

    private static let cashTypes: Set<AccountType> = [.checking, .savings, .cash]

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

    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }
    private func short(_ v: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.maximumFractionDigits = 0; f.locale = .current
        return f.string(from: NSNumber(value: v)) ?? ""
    }
    private func day(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }

    var body: some View {
        let sel = selectedIds
        let accounts = allAccounts.filter { sel?.contains($0.accountId) ?? true }
        let transactions = sel == nil ? allTransactions : allTransactions.filter { sel!.contains($0.accountId) }
        let book = BalanceBook(transactions: transactions)
        let cashAccounts = accounts.filter { Self.cashTypes.contains($0.type) }
        let cashToday = book.today(cashAccounts)
        let netWorth = book.today(accounts)
        let debts = book.today(accounts.filter { $0.type == .creditCard || $0.type == .mortgage })
        let assets = netWorth - debts
        let names = Dictionary(allAccounts.map { ($0.accountId, $0.name) }, uniquingKeysWith: { a, _ in a })
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let ledger = transactions.filter { $0.date >= tomorrow }.map {
            LedgerEntry(date: $0.date, name: $0.name, amount: $0.amount, accountId: $0.accountId, category: $0.category,
                        isTransfer: $0.transferPeerId != nil || $0.category == Categorizer.transfer)
        }
        let proj = DashboardMath.projection(days: 30, schedules: bills.filter(\.isActive).map { $0.item(accountNames: names) },
                                            balanceToday: cashToday, cashAccountIds: Set(cashAccounts.map(\.accountId)), ledger: ledger)
        let low = proj.points.min { $0.balance < $1.balance }
        let nextPay = proj.upcoming.first { $0.isIncome }
        let history = DashboardMath.netWorthHistory(currentTotal: netWorth,
                                                    transactions: transactions.map { (date: $0.date, amount: $0.amount) }, months: 12)
        // Spending leaves out accounts excluded from cash flow (e.g. a mortgage paying escrow); net worth still counts them.
        let flowTransactions = CashFlowScope.transactions(transactions, accounts: allAccounts)
        let rows: [SpendingReport.Row] = flowTransactions.map { ($0.category, $0.amount, $0.date) }
        let spend = SpendingReport.byCategory(rows, period: .last30Days)
        let spent = SpendingReport.totals(rows, period: .last30Days).expenses
        let picked = pickedDay.flatMap { d in proj.points.first { Calendar.current.isDate($0.date, inSameDayAs: d) } }

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(cardOrder) { c in
                        switch c {
                        case .tiles:
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            tile("Cash today", money(cashToday), cashAccounts.isEmpty ? "No checking or savings" : "\(cashAccounts.count) account\(cashAccounts.count == 1 ? "" : "s")",
                                 tint: cashToday < 0 ? .red : nil)
                            NavigationLink {
                                NetWorthDetail(accounts: accounts, book: book)
                            } label: {
                                tile("Net worth", money(netWorth), "Assets \(short(assets)) • Debts \(short(debts)) ›")
                            }
                            .buttonStyle(.plain)
                            tile("Lowest in 30 days", low.map { money($0.balance) } ?? "—", low.map { "on \(day($0.date))" } ?? "",
                                 tint: (low?.balance ?? 0) < 0 ? .red : nil)
                            tile("Next payday", nextPay.map { money($0.amount) } ?? "—", nextPay.map { "\($0.name) • \(day($0.date))" } ?? "None in 30 days")
                        }
                        case .cash:
                        card("Cash — next 30 days") {
                            if proj.points.isEmpty {
                                Text("Add accounts and scheduled items to see a projection.").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Chart {
                                    ForEach(proj.points) { p in
                                        AreaMark(x: .value("Day", p.date, unit: .day), y: .value("Balance", p.balance)).foregroundStyle(.blue.opacity(0.15))
                                        LineMark(x: .value("Day", p.date, unit: .day), y: .value("Balance", p.balance))
                                            .interpolationMethod(.stepEnd).foregroundStyle(.blue)
                                    }
                                    RuleMark(y: .value("Zero", 0)).foregroundStyle(.red.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                                    if let picked {
                                        RuleMark(x: .value("Day", picked.date, unit: .day)).foregroundStyle(.secondary.opacity(0.5))
                                        PointMark(x: .value("Day", picked.date, unit: .day), y: .value("Balance", picked.balance)).symbolSize(90)
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
                                if let picked {
                                    dayDetail(picked, days: proj.days, points: proj.points, startBalance: cashToday)
                                } else {
                                    Text("Tap the line to see a day's balance and what moves it.").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        case .coming:
                        card("Coming up") {
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
                        case .netWorth:
                        card("Net worth — last 12 months") {
                            Chart(history) { p in
                                LineMark(x: .value("Date", p.date), y: .value("Net worth", p.balance)).foregroundStyle(.green)
                                PointMark(x: .value("Date", p.date), y: .value("Net worth", p.balance)).foregroundStyle(.green)
                            }
                            .chartYScale(domain: .automatic(includesZero: false))
                            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(short(d)) } } } }
                            .frame(height: 140)
                        }
                        case .spending:
                        card("Spent in the last 30 days") {
                            if spend.isEmpty {
                                Text("No spending in this period.").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(money(spent)).font(.title3.bold().monospacedDigit())
                                ForEach(spend.prefix(6), id: \.category) { c in
                                    NavigationLink {
                                        CategoryTransactionsList(category: c.category, transactions: flowTransactions)
                                    } label: {
                                    HStack {
                                        Text(c.category).lineLimit(1)
                                        Spacer()
                                        Text(short(c.amount)).monospacedDigit().foregroundStyle(.secondary)
                                        if spent > 0 { Text(String(format: "%.0f%%", c.amount / spent * 100)).font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing) }
                                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                    }.font(.callout)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        case .subscriptions:
                        card("Subscriptions") {
                            // Every account, not just the ones picked for the overview: a subscription is yours either way.
                            let subs = SubscriptionService.detect(transactions: CashFlowScope.transactions(allTransactions, accounts: allAccounts), marks: subscriptionMarks)
                            let totals = SubscriptionService.totals(subs)
                            let toReview = subs.filter { $0.status == .unreviewed }.count
                            NavigationLink {
                                SubscriptionsList()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(money(totals.monthly))/mo").font(.title3.bold().monospacedDigit())
                                        Text(subs.isEmpty ? "No recurring charges found yet"
                                             : "\(money(totals.annual)) a year" + (toReview > 0 ? " • \(toReview) to review" : ""))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        case .cloud:
                        card("iCloud sync") {
                            Button { cloud.checkNow(context: context) } label: {
                                Label(cloud.summary, systemImage: cloud.symbol(receiving: true))
                                    .font(.caption).foregroundStyle(cloud.hasProblem ? Color.orange : Color.secondary)
                                    .symbolEffect(.pulse, isActive: cloud.checking || cloud.working)
                            }.buttonStyle(.plain)
                            Text("Both devices must use the same Apple ID with iCloud on. Open the Mac app after a Plaid sync, and give the phone a moment with the app open. Tap the line above to check now.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .navigationTitle("Overview")
            .sheet(isPresented: $reorderingCards) {
                CardOrderSheet(order: cardOrder) { cardOrderRaw = $0.map(\.rawValue).joined(separator: ",") }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(allAccounts) { a in Toggle(a.name, isOn: isIncluded(a)) }
                        Divider()
                        Button("All accounts") { accountIdsRaw = "" }
                        Divider()
                        Button("Reorder Cards…") { reorderingCards = true }
                        Button("Reorder Tabs…", action: onReorderTabs)
                        Divider()
                        Button(demo ? "Leave Demo Mode…" : "Show Demo Data…", systemImage: "theatermasks") { confirmingDemo = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .confirmationDialog(demo ? "Leave the demo?" : "Show demo data?", isPresented: $confirmingDemo, titleVisibility: .visible) {
                Button(demo ? "Leave Demo" : "Show Demo") { demo.toggle() }
            } message: {
                Text(demo
                     ? "Finance will go back to your own data. Nothing from the demo is added to it."
                     : DemoMode.isShared
                        ? "Finance will show a made-up household instead of your own. The demo has its own iCloud space, so your real data isn't touched. Turn on demo mode on your Mac too (File ▸ Show Demo Data…) and both will show the same demo. Tap Leave on the orange bar to come back."
                        : "Finance will show a made-up household instead of your own. Your real data isn't touched. Tap Leave on the orange bar to come back.")
            }
        }
    }

    // MARK: - Pieces

    private func tile(_ title: String, _ value: String, _ caption: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(tint ?? .primary).minimumScaleFactor(0.7).lineLimit(1)
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func dayDetail(_ sel: CashPoint, days: [CalendarDay], points: [CashPoint], startBalance: Double) -> some View {
        let idx = points.firstIndex { $0.id == sel.id } ?? 0
        let opening = idx > 0 ? points[idx - 1].balance : startBalance
        let events = (days.first { Calendar.current.isDate($0.date, inSameDayAs: sel.date) }?.events ?? [])
            .filter { $0.amount != 0 || $0.isTransfer }
        Divider()
        HStack {
            Text(sel.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.subheadline.bold())
            Spacer()
            Text(money(sel.balance)).bold().monospacedDigit().foregroundStyle(sel.balance < 0 ? .red : .primary)
        }
        Text(idx == 0 ? "Starting from \(money(opening)) today" : "Previous day \(money(opening))")
            .font(.caption2).foregroundStyle(.secondary)
        if events.isEmpty { Text("Nothing moves the balance on this day.").font(.caption).foregroundStyle(.secondary) }
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
        Button("Clear") { pickedDay = nil }.font(.caption)
    }
}

enum OverviewCard: String, CaseIterable, Identifiable {
    case tiles, cash, coming, netWorth, spending, subscriptions, cloud
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tiles: return "Balance tiles"
        case .cash: return "Cash — next 30 days"
        case .coming: return "Coming up"
        case .netWorth: return "Net worth"
        case .spending: return "Spent in the last 30 days"
        case .subscriptions: return "Subscriptions"
        case .cloud: return "iCloud sync"
        }
    }
}

/// Drag the handles to put the overview cards in the order you want.
struct CardOrderSheet: View {
    @State var order: [OverviewCard]
    let onSave: ([OverviewCard]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(order) { Text($0.title) }
                    .onMove { order.move(fromOffsets: $0, toOffset: $1); onSave(order) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Card Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

/// What makes up net worth: assets and debts listed separately, with totals.
struct NetWorthDetail: View {
    let accounts: [Account]
    let book: BalanceBook

    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }
    private var debts: [Account] { accounts.filter { $0.type == .creditCard || $0.type == .mortgage } }
    private var assets: [Account] { accounts.filter { !($0.type == .creditCard || $0.type == .mortgage) } }

    private func section(_ title: String, _ items: [Account]) -> some View {
        Section {
            ForEach(AccountType.grouped(items, by: { $0.type }), id: \.type) { group in
                ForEach(group.items) { a in
                    NavigationLink {
                        TransactionsTab(accountId: a.accountId, title: a.name)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(a.name)
                                Text(typeLabel(group.type)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(money(book.today(a))).monospacedDigit().foregroundStyle(book.today(a) < 0 ? .red : .primary)
                        }
                    }
                }
            }
        } header: {
            HStack { Text(title); Spacer(); Text(money(book.today(items))).monospacedDigit() }
        }
    }

    private func typeLabel(_ t: AccountType) -> String {
        switch t {
        case .checking: return "Checking"
        case .savings: return "Savings"
        case .creditCard: return "Credit card"
        case .mortgage: return "Mortgage"
        case .investment: return "Investment"
        case .cash: return "Cash"
        case .property: return "Property"
        }
    }

    var body: some View {
        List {
            section("Assets", assets)
            section("Debts", debts)
            Section {
                HStack {
                    Text("Net worth").bold()
                    Spacer()
                    let total = book.today(accounts)
                    Text(money(total)).bold().monospacedDigit().foregroundStyle(total < 0 ? .red : .primary)
                }
            }
        }
        .navigationTitle("Net Worth")
        .navigationBarTitleDisplayMode(.inline)
    }
}


/// The last-30-days expenses behind one category row on the Overview.
struct CategoryTransactionsList: View {
    let category: String
    let transactions: [TransactionRecord]
    @Query private var customCategories: [CustomCategory]
    @Environment(\.modelContext) private var context

    private var rows: [TransactionRecord] {
        transactions.filter {
            $0.category == category && $0.amount < 0 && DashboardPeriod.last30Days.contains($0.date)
        }.sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            Section {
                ForEach(rows) { t in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(t.name).lineLimit(1)
                            Text("\(t.date.formatted(.dateTime.month(.abbreviated).day())) • \(t.accountName)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(currency.string(from: NSNumber(value: t.amount)) ?? "").monospacedDigit()
                        Menu {
                            ForEach(allCategoryChoices(customCategories), id: \.self) { c in
                                Button(c) {
                                    guard c != t.category else { return }
                                    if t.transferPeerId != nil && c != Categorizer.transfer {
                                        TransferLinkService.detach(t, among: transactions)
                                    }
                                    CategorizationService.learn(from: t, category: c, in: context)
                                }
                            }
                        } label: {
                            Image(systemName: "tag").padding(6).background(.quaternary, in: Capsule())
                        }
                    }
                }
            } header: {
                Text("\(rows.count) transactions • \(currency.string(from: NSNumber(value: -rows.reduce(0) { $0 + $1.amount })) ?? "")")
            }
        }
        .navigationTitle(category)
        .navigationBarTitleDisplayMode(.inline)
    }
}
