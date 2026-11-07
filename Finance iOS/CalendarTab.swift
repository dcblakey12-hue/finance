import SwiftUI
import SwiftData

/// Month calendar of scheduled items with a projected balance, like the Mac app.
struct CalendarTab: View {
    @Query(sort: \RecurringBill.dueDay) private var bills: [RecurringBill]
    @Query private var accounts: [Account]
    @Query private var transactions: [TransactionRecord]

    @State private var month = Date()
    @State private var selected: Date?
    @State private var includeAll = false

    private var calendar: Calendar { .current }
    private var included: [Account] {
        let cash: Set<AccountType> = [.checking, .savings, .cash]
        return accounts.filter { includeAll || cash.contains($0.type) }
    }
    private var names: [String: String] { Dictionary(accounts.map { ($0.accountId, $0.name) }, uniquingKeysWith: { a, _ in a }) }
    private var startingBalance: Double { included.reduce(0) { $0 + $1.balance } }
    private var actualNet: [Date: Double] {
        let ids = Set(included.map(\.accountId))
        var out: [Date: Double] = [:]
        for t in transactions where ids.contains(t.accountId) { out[calendar.startOfDay(for: t.date), default: 0] += t.amount }
        return out
    }
    private var days: [CalendarDay] {
        CashCalendar.grid(month: month,
                          schedules: bills.filter(\.isActive).map { $0.item(accountNames: names) },
                          balanceToday: startingBalance, actualNetByDay: actualNet,
                          cashAccountIds: Set(included.map(\.accountId)), ledger: ledgerEntries)
    }
    private var ledgerEntries: [LedgerEntry] {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date()
        return transactions.filter { $0.date >= tomorrow }.map {
            LedgerEntry(date: $0.date, name: $0.name, amount: $0.amount, accountId: $0.accountId, category: $0.category,
                        isTransfer: $0.transferPeerId != nil || $0.category == Categorizer.transfer)
        }
    }
    private var summary: CalendarMonthSummary { CashCalendar.summary(of: days) }

    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }
    private func short(_ v: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.maximumFractionDigits = 0; f.locale = .current
        return f.string(from: NSNumber(value: v)) ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    stats
                    weekdayHeader
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                        ForEach(days) { cell($0) }
                    }
                    if let sel = selected { detail(sel) }
                    Toggle("Include credit cards & other accounts", isOn: $includeAll).font(.caption)
                }
                .padding(.horizontal, 8)
            }
            .navigationTitle(month.formatted(.dateTime.month(.wide).year()))
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    Button("Today") { month = Date(); selected = calendar.startOfDay(for: Date()) }
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                }
            }
        }
    }

    private var stats: some View {
        let low = summary.low.map { l -> String in
            let d = summary.lowDate.map { " (\($0.formatted(.dateTime.month(.abbreviated).day())))" } ?? ""
            return money(l) + d
        } ?? "—"
        return VStack(spacing: 4) {
            HStack { stat("Today", money(startingBalance)); stat("Month end", summary.closing.map(money) ?? "—") }
            HStack { stat("Lowest", low); stat("Bills / income", "\(money(summary.expenses)) / \(money(summary.income))") }
        }
    }
    private func stat(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.footnote.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var weekdayHeader: some View {
        let sym = calendar.veryShortStandaloneWeekdaySymbols
        let k = calendar.firstWeekday - 1
        let ordered = Array(sym[k...] + sym[..<k])
        return HStack(spacing: 2) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, s in
                Text(s).font(.caption2.bold()).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }

    private func cell(_ day: CalendarDay) -> some View {
        let isToday = calendar.isDateInToday(day.date)
        let isSel = selected.map { calendar.isDate($0, inSameDayAs: day.date) } ?? false
        return VStack(spacing: 2) {
            Text("\(calendar.component(.day, from: day.date))")
                .font(.caption2.bold())
                .padding(.horizontal, 4)
                .background(isToday ? Color.accentColor : .clear, in: Capsule())
                .foregroundStyle(isToday ? Color.white : Color.primary)
            HStack(spacing: 2) {
                ForEach(day.events.prefix(3)) { e in
                    Circle().fill(e.isTransfer ? .blue : (e.isIncome ? .green : .red)).frame(width: 5, height: 5)
                }
            }.frame(height: 6)
            if let b = day.closing {
                Text(short(b)).font(.system(size: 8)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    .foregroundStyle(b < 0 ? .red : .secondary)
            } else { Text(" ").font(.system(size: 8)) }
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(day.inMonth ? Color.gray.opacity(0.12) : Color.gray.opacity(0.03), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(isSel ? Color.accentColor : .clear, lineWidth: 2))
        .opacity(day.inMonth ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture { selected = day.date }
    }

    private func detail(_ date: Date) -> some View {
        let day = days.first { calendar.isDate($0.date, inSameDayAs: date) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(date.formatted(date: .complete, time: .omitted)).font(.headline)
            if day?.events.isEmpty ?? true { Text("Nothing scheduled.").foregroundStyle(.secondary) }
            ForEach(day?.events ?? []) { e in
                HStack {
                    VStack(alignment: .leading) { Text(e.name); Text(e.detail ?? e.category).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(money(e.isTransfer ? e.gross : e.amount)).monospacedDigit()
                        .foregroundStyle(e.isIncome ? .green : (e.isTransfer ? .blue : .primary))
                }
            }
            if let b = day?.closing {
                Divider()
                HStack { Text("Projected balance").foregroundStyle(.secondary); Spacer()
                    Text(money(b)).bold().monospacedDigit().foregroundStyle(b < 0 ? .red : .primary) }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func shift(_ d: Int) { month = calendar.date(byAdding: .month, value: d, to: month) ?? month }
}
