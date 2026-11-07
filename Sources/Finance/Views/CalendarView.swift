import SwiftUI
import SwiftData

/// Month calendar of scheduled transactions with a projected balance on each day,
/// plus an option to copy the schedule into a Mac Calendar ("Finance Bills").
struct CalendarView: View {
    @Query(sort: \RecurringBill.dueDay) var bills: [RecurringBill]
    @Query var accounts: [Account]
    @Query var transactions: [TransactionRecord]
    @State private var calService = CalendarService()
    @State private var month = Date()
    @State private var selected: Date?
    @State private var includeAllAccounts = false
    @State private var status = ""

    private var calendar: Calendar { .current }

    /// Cash on hand: checking, savings and cash accounts (or every account if toggled).
    private var includedAccounts: [Account] {
        let cash: Set<AccountType> = [.checking, .savings, .cash]
        return accounts.filter { includeAllAccounts || cash.contains($0.type) }
    }
    private var startingBalance: Double { includedAccounts.reduce(0) { $0 + $1.balance } }
    /// Real transactions per day (included accounts), used to show past balances.
    private var actualNetByDay: [Date: Double] {
        let ids = Set(includedAccounts.map(\.accountId))
        var out: [Date: Double] = [:]
        for t in transactions where ids.contains(t.accountId) { out[calendar.startOfDay(for: t.date), default: 0] += t.amount }
        return out
    }
    private var items: [ScheduleItem] { bills.filter(\.isActive).map(\.item) }
    private var days: [CalendarDay] {
        CashCalendar.grid(month: month, schedules: items, balanceToday: startingBalance, actualNetByDay: actualNetByDay)
    }
    private var lowText: String {
        guard let low = summary.low else { return "—" }
        guard let d = summary.lowDate else { return money(low) }
        return "\(money(low)) (\(d.formatted(.dateTime.month(.abbreviated).day())))"
    }
    private var summary: CalendarMonthSummary { CashCalendar.summary(of: days) }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()
    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }
    private func shortMoney(_ v: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.maximumFractionDigits = 0; f.locale = .current
        return f.string(from: NSNumber(value: v)) ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if bills.isEmpty {
                    Text("No scheduled transactions yet. Add bills and paydays in Scheduled Transactions (or right-click a transaction → Schedule as Recurring…) and they will show up here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                stats
                weekdayHeader
                grid
                if let sel = selected { dayDetail(sel) }
                macCalendarBox
            }.padding()
        }
        .navigationTitle("Bills & Calendar")
        .task { await calService.requestAccess() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Text(Self.monthFormatter.string(from: month)).font(.largeTitle.bold())
            Spacer()
            Button("‹") { shift(-1) }.help("Previous month")
            Button("Today") { month = Date(); selected = calendar.startOfDay(for: Date()) }
            Button("›") { shift(1) }.help("Next month")
        }
    }

    private var stats: some View {
        HStack(spacing: 16) {
            stat("Balance today", money(startingBalance), .primary)
            stat("Scheduled income", money(summary.income), .green)
            stat("Scheduled bills", money(summary.expenses), .primary)
            stat("Lowest this month", lowText, (summary.low ?? 0) < 0 ? .red : .primary)
            stat("End of month", summary.closing.map(money) ?? "—", (summary.closing ?? 0) < 0 ? .red : .primary)
        }
        .overlay(alignment: .bottomLeading) {
            Toggle("Include credit cards & other accounts in balance", isOn: $includeAllAccounts)
                .font(.caption).offset(y: 26)
        }
        .padding(.bottom, 26)
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit().foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var weekdayHeader: some View {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        let ordered = Array(symbols[shift...] + symbols[..<shift])
        return HStack(spacing: 4) {
            ForEach(ordered, id: \.self) { Text($0).font(.caption.bold()).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
            ForEach(days) { day in dayCell(day) }
        }
    }

    private func dayCell(_ day: CalendarDay) -> some View {
        let isToday = calendar.isDateInToday(day.date)
        let isSelected = selected.map { calendar.isDate($0, inSameDayAs: day.date) } ?? false
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(calendar.component(.day, from: day.date))")
                    .font(.caption.bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(isToday ? Color.accentColor : .clear, in: Capsule())
                    .foregroundStyle(isToday ? Color.white : Color.primary)
                Spacer()
            }
            ForEach(day.events.prefix(3)) { e in
                Text("\(e.name) \(shortMoney(e.amount))")
                    .font(.system(size: 10)).lineLimit(1)
                    .padding(.horizontal, 3)
                    .background((e.isIncome ? Color.green : Color.red).opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
            }
            if day.events.count > 3 { Text("+\(day.events.count - 3) more").font(.system(size: 10)).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            if let bal = day.closing {
                Text(shortMoney(bal)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(bal < 0 ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(4)
        .frame(minHeight: 92)
        .background(day.inMonth ? Color.gray.opacity(0.10) : Color.gray.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .opacity(day.inMonth ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture { selected = day.date }
    }

    private func dayDetail(_ date: Date) -> some View {
        let day = days.first { calendar.isDate($0.date, inSameDayAs: date) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(date.formatted(date: .complete, time: .omitted)).font(.headline)
            if let day {
                if day.events.isEmpty { Text("Nothing scheduled.").foregroundStyle(.secondary) }
                ForEach(day.events) { e in
                    HStack {
                        Text(e.name)
                        Text(e.category).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(money(e.amount)).monospacedDigit().foregroundStyle(e.isIncome ? .green : .primary)
                    }
                }
                if let bal = day.closing {
                    Divider()
                    HStack { Text("Projected balance at end of day").foregroundStyle(.secondary); Spacer()
                        Text(money(bal)).bold().monospacedDigit().foregroundStyle(bal < 0 ? .red : .primary) }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var macCalendarBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mac Calendar").font(.headline)
            Text("Copy your scheduled bills and paydays into a \"Finance Bills\" calendar in the Calendar app (next 12 months). Re-running replaces what the app added before, so nothing is duplicated.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if calService.isAuthorized {
                    Button("Add to Mac Calendar") { sync() }.buttonStyle(.borderedProminent)
                        .disabled(bills.filter(\.isActive).isEmpty)
                    Button("Remove from Mac Calendar") { clear() }.buttonStyle(.bordered)
                } else {
                    Button("Allow Calendar Access") { Task { await calService.requestAccess() } }.buttonStyle(.borderedProminent)
                    Text("Needs permission in System Settings → Privacy & Security → Calendars.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: - Actions

    private func shift(_ delta: Int) {
        month = calendar.date(byAdding: .month, value: delta, to: month) ?? month
    }
    private func sync() {
        do { let n = try calService.syncBills(bills); status = "Added \(n) events to the Finance Bills calendar." }
        catch { status = "Calendar sync failed: \(error.localizedDescription)" }
    }
    private func clear() {
        do { let n = try calService.clearSynced(); status = "Removed \(n) events from the Finance Bills calendar." }
        catch { status = "Couldn't remove events: \(error.localizedDescription)" }
    }
}
