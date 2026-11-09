import SwiftUI
import SwiftData
import Charts

struct ForecastView: View {
    @Query var accounts: [Account]
    @Query var bills: [RecurringBill]
    @Query var envelopes: [Envelope]
    @Query var transactions: [TransactionRecord]

    @State private var monthsToShow: Int = 12
    @State private var includeEnvelopes = true
    @State private var fallbackAverage = true
    @State private var inferIncome = true
    @State private var selectedMonthID: Date?
    @State private var openEnvelopes = Set<Date>()
    @State private var startDate = Calendar.current.startOfDay(for: Date())
    /// Accounts included in the forecast (comma-separated OFX accountIds; empty = all accounts).
    @AppStorage("forecastAccountIds") private var accountIdsRaw = ""

    private var selectedIds: Set<String>? {
        let ids = Set(accountIdsRaw.split(separator: ",").map(String.init)).intersection(accounts.map(\.accountId))
        return ids.isEmpty || ids.count == accounts.count ? nil : ids
    }
    private var includedAccounts: [Account] { accounts.filter { selectedIds?.contains($0.accountId) ?? true } }
    private func isIncluded(_ a: Account) -> Binding<Bool> {
        Binding(get: { selectedIds?.contains(a.accountId) ?? true },
                set: { on in
                    var ids = selectedIds ?? Set(accounts.map(\.accountId))
                    if on { ids.insert(a.accountId) } else if ids.count > 1 { ids.remove(a.accountId) }
                    accountIdsRaw = ids.count == accounts.count ? "" : ids.sorted().joined(separator: ",")
                })
    }
    private var accountsLabel: String {
        guard let ids = selectedIds else { return "All accounts" }
        return ids.count == 1 ? (includedAccounts.first?.name ?? "1 account") : "\(ids.count) of \(accounts.count) accounts"
    }

    /// Balance at the start of `startDate`: today's total, wound back by everything posted since.
    var startingBalance: Double {
        let now = includedAccounts.filter { !$0.type.isPropertyValue }.reduce(0) { $0 + $1.balance }
        let start = Calendar.current.startOfDay(for: startDate)
        guard start < Calendar.current.startOfDay(for: Date()) else { return now }
        return now - transactions.filter { $0.date >= start && (selectedIds?.contains($0.accountId) ?? true) }.reduce(0) { $0 + $1.amount }
    }

    var forecast: [ForecastMonth] {
        CashFlowForecastService.forecast(
            bills: bills, envelopes: envelopes, transactions: transactions,
            options: ForecastOptions(
                months: monthsToShow, includeEnvelopes: includeEnvelopes,
                fallbackAverageVariable: fallbackAverage, inferIncomeFromHistory: inferIncome,
                startingBalance: startingBalance, from: startDate
            ),
            accountIds: selectedIds
        )
    }

    var projectedMin: Double { forecast.map { $0.intraMonthLow }.min() ?? startingBalance }
    var projectedEnd: Double { forecast.last?.closingBalance ?? startingBalance }
    var firstNegative: ForecastMonth? { forecast.first { $0.goesNegative } }
    var totalIncome: Double { forecast.reduce(0) { $0 + $1.scheduledIncome } }
    var totalExpenses: Double { forecast.reduce(0) { $0 + $1.totalExpenses } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Cash Flow Forecast").font(.largeTitle.bold())
                Text("Projects your balance month by month from current balances, scheduled transactions (bills + paydays), and envelope estimates (adjusted to avoid double-counting bills).")
                    .font(.caption).foregroundStyle(.secondary)

                controls
                kpis
                chartSection
                monthList
                assumptions
            }.padding()
        }
        .navigationTitle("Cash Flow Forecast")
    }

    // MARK: - Subviews

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 16) {
            Picker("Horizon", selection: $monthsToShow) {
                Text("3 months").tag(3); Text("6 months").tag(6); Text("12 months").tag(12); Text("24 months").tag(24)
            }.pickerStyle(.segmented).frame(width: 330)
            Menu {
                Button("All accounts") { accountIdsRaw = "" }
                Divider()
                ForEach(accounts) { a in Toggle(a.name, isOn: isIncluded(a)) }
            } label: { Label(accountsLabel, systemImage: "building.columns") }
                .fixedSize()
                .help("Choose which accounts the forecast covers")
            DatePicker("Start", selection: $startDate, in: ...Date(), displayedComponents: .date).font(.caption)
            Button("Today") { startDate = Calendar.current.startOfDay(for: Date()) }.font(.caption).disabled(Calendar.current.isDateInToday(startDate))
            Spacer()
        }
        .font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 16) {
            Toggle("Include envelopes", isOn: $includeEnvelopes).font(.caption)
            Toggle("Fallback avg", isOn: $fallbackAverage).font(.caption)
            Toggle("Estimate income", isOn: $inferIncome).font(.caption)
            Spacer()
        }
        .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var kpis: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                KpiCard(title: Calendar.current.isDateInToday(startDate) ? "Starting balance" : "Balance on \(startDate.formatted(.dateTime.month(.abbreviated).day()))", value: fmt(startingBalance), icon: "wallet.bifold")
                KpiCard(title: "Projected low", value: fmt(projectedMin), icon: projectedMin < 0 ? "exclamationmark.triangle" : "arrow.down.circle")
                KpiCard(title: "Ending (\(monthsToShow)m)", value: fmt(projectedEnd), icon: "flag.checkered")
                KpiCard(title: "Net change", value: fmt(projectedEnd - startingBalance), icon: "arrow.triangle.2.circlepath")
            }
            if let neg = firstNegative {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Projected to go negative in \(monthLabel(neg.monthDate)) (lowest \(fmt(neg.intraMonthLow))). Add payday schedules, reduce a bill, or cut a category.").font(.caption)
                }
                .padding(10).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Projected balance").font(.headline)
            if forecast.isEmpty || (totalIncome == 0 && totalExpenses == 0) {
                ContentUnavailableView(
                    "No forecast data yet",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Add scheduled income or recurring bills in Bills & Calendar, or import an OFX file for history-based estimates.")
                ).frame(height: 180)
            } else {
                let lo = forecast.map(\.closingBalance).min() ?? 0
                let crossesZero = lo < 0
                Chart(forecast) { m in
                    AreaMark(x: .value("Month", m.monthDate, unit: .month), y: .value("Balance", m.closingBalance))
                        .interpolationMethod(.monotone).foregroundStyle(.blue.opacity(0.12))
                    LineMark(x: .value("Month", m.monthDate, unit: .month), y: .value("Balance", m.closingBalance))
                        .interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth: 2.5)).foregroundStyle(.blue)
                    PointMark(x: .value("Month", m.monthDate, unit: .month), y: .value("Balance", m.closingBalance))
                        .foregroundStyle(m.goesNegative ? .red : .blue)
                    if crossesZero {
                        RuleMark(y: .value("Zero", 0)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.red.opacity(0.6))
                    }
                }
                .chartYScale(domain: .automatic(includesZero: crossesZero))
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(short(d)) } } } }
                .chartXAxis { AxisMarks(values: .stride(by: .month, count: monthsToShow > 12 ? 3 : 1)) { _ in
                    AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                .frame(height: 220)
                .accessibilityLabel("Projected closing balance by month")
                Text("Monthly net change").font(.caption.bold()).foregroundStyle(.secondary)
                Chart(forecast) { m in
                    BarMark(x: .value("Month", m.monthDate, unit: .month), y: .value("Net", m.net))
                        .foregroundStyle(m.net >= 0 ? Color.green.opacity(0.7) : Color.red.opacity(0.7))
                }
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(short(d)) } } } }
                .chartXAxis { AxisMarks(values: .stride(by: .month, count: monthsToShow > 12 ? 3 : 1)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                .frame(height: 100)
            }
        }
    }

    private var monthList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Month by month").font(.headline)
            ForEach(forecast) { m in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(m.monthDate.formatted(.dateTime.month(.wide).year())).font(.headline)
                        if m.goesNegative {
                            Text("LOW").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.red, in: Capsule()).foregroundStyle(.white)
                        }
                        Spacer()
                        Text(fmt(m.closingBalance)).font(.title3.bold().monospacedDigit())
                            .foregroundStyle(m.closingBalance < 0 ? .red : .primary)
                    }
                    HStack(alignment: .top, spacing: 0) {
                        stat("Opening", fmt(m.openingBalance))
                        stat("Income", fmt(m.scheduledIncome), .green)
                        stat("Bills", fmt(m.scheduledExpenses))
                        Button {
                            if openEnvelopes.contains(m.id) { openEnvelopes.remove(m.id) } else { openEnvelopes.insert(m.id) }
                        } label: {
                            HStack(spacing: 3) {
                                stat("Envelopes", fmt(m.envelopeSpend))
                                if !m.envelopeLines.isEmpty {
                                    Image(systemName: openEnvelopes.contains(m.id) ? "chevron.down" : "chevron.right")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(m.envelopeLines.isEmpty)
                        .help("Click to see what makes up this figure")
                        stat("Net", fmt(m.net), m.net < 0 ? .red : .green)
                    }
                    if openEnvelopes.contains(m.id), !m.envelopeLines.isEmpty {
                        envelopeDetail(m)
                    }
                    if !m.events.isEmpty {
                        DisclosureGroup("\(m.events.count) scheduled items") {
                            VStack(spacing: 3) {
                                ForEach(Array(m.events.enumerated()), id: \.offset) { _, e in
                                    HStack {
                                        Text(e.date.formatted(.dateTime.month(.abbreviated).day()))
                                            .foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                                        Text(e.name).lineLimit(1)
                                        Spacer()
                                        Text("\(e.isIncome ? "+" : "−")\(fmt(abs(e.amount)))").monospacedDigit()
                                            .foregroundStyle(e.isIncome ? .green : .primary)
                                    }.font(.caption)
                                }
                            }.padding(.top, 4)
                        }.font(.caption)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func envelopeDetail(_ m: ForecastMonth) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Envelope").frame(maxWidth: .infinity, alignment: .leading)
                Text("Budget").frame(width: 80, alignment: .trailing)
                Text("Bills").frame(width: 80, alignment: .trailing)
                Text("Forecast").frame(width: 80, alignment: .trailing)
            }.font(.caption2.bold()).foregroundStyle(.secondary)
            ForEach(m.envelopeLines) { l in
                HStack {
                    Text(l.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(fmt(l.allocated)).frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
                    Text(l.billed > 0 ? fmt(l.billed) : "—").frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
                    Text(fmt(l.remainder)).frame(width: 80, alignment: .trailing)
                }.font(.caption.monospacedDigit())
            }
            Divider()
            Text(m.envelopeScale < 1
                 ? "Forecast = budget minus bills already counted in that category, then scaled to the \(Int((m.envelopeScale * 100).rounded()))% of the month still ahead. Edit amounts on the Budget page."
                 : "Forecast = budget minus bills already counted in that category, so scheduled bills aren't counted twice. Edit amounts on the Budget page.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8).background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func stat(_ title: String, _ value: String, _ tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(tint)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assumptions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How this is calculated").font(.caption.bold())
            Text("• Starting balance = sum of all accounts (for an earlier start date, wound back by what posted since, so paydays after it count again). Current month counts only events still ahead; envelope spend is pro-rated by remaining days.")
            Text("• Bills in an envelope category reduce that envelope (Rent $1,200 in Housing $1,500 → $300 variable), avoiding double count.")
            Text("• Future months reuse the most recent envelope month; with no envelopes, a trailing 3-month average is used (if enabled).")
            Text("• Estimated income is only used when you have no paycheck scheduled (if enabled).")
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func short(_ v: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.maximumFractionDigits = 0; f.locale = .current
        return f.string(from: NSNumber(value: v)) ?? ""
    }
    private func fmt(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "$\(String(format: "%.2f", v))" }
    private func monthLabel(_ d: Date) -> String { DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .none) }
}

private extension ForecastEvent {
    var dueDayLabel: String {
        let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .none
        return df.string(from: date)
    }
}
