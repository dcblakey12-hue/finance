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
    @State private var startDate = Calendar.current.startOfDay(for: Date())

    /// Balance at the start of `startDate`: today's total, wound back by everything posted since.
    var startingBalance: Double {
        let now = accounts.reduce(0) { $0 + $1.balance }
        let start = Calendar.current.startOfDay(for: startDate)
        guard start < Calendar.current.startOfDay(for: Date()) else { return now }
        return now - transactions.filter { $0.date >= start }.reduce(0) { $0 + $1.amount }
    }

    var forecast: [ForecastMonth] {
        CashFlowForecastService.forecast(
            bills: bills, envelopes: envelopes, transactions: transactions,
            options: ForecastOptions(
                months: monthsToShow, includeEnvelopes: includeEnvelopes,
                fallbackAverageVariable: fallbackAverage, inferIncomeFromHistory: inferIncome,
                startingBalance: startingBalance, from: startDate
            )
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
        HStack(spacing: 16) {
            Picker("Horizon", selection: $monthsToShow) {
                Text("3 months").tag(3); Text("6 months").tag(6); Text("12 months").tag(12); Text("24 months").tag(24)
            }.pickerStyle(.segmented).frame(width: 330)
            DatePicker("Start", selection: $startDate, in: ...Date(), displayedComponents: .date).font(.caption)
            Button("Today") { startDate = Calendar.current.startOfDay(for: Date()) }.font(.caption).disabled(Calendar.current.isDateInToday(startDate))
            Toggle("Include envelopes", isOn: $includeEnvelopes).font(.caption)
            Toggle("Fallback avg", isOn: $fallbackAverage).font(.caption)
            Toggle("Estimate income", isOn: $inferIncome).font(.caption)
        }
        .font(.caption).foregroundStyle(.secondary)
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
                Chart(forecast) { m in
                    BarMark(
                        x: .value("Month", m.monthDate, unit: .month),
                        y: .value("Net", m.net)
                    ).foregroundStyle(m.net >= 0 ? Color.green.opacity(0.55) : Color.red.opacity(0.55))
                    LineMark(
                        x: .value("Month", m.monthDate, unit: .month),
                        y: .value("Balance", m.closingBalance)
                    ).lineStyle(StrokeStyle(lineWidth: 2.5)).foregroundStyle(.blue)
                    PointMark(
                        x: .value("Month", m.monthDate, unit: .month),
                        y: .value("Balance", m.closingBalance)
                    ).foregroundStyle(.blue)
                    RuleMark(y: .value("Zero", 0)).lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(.secondary)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .month, count: 3)) { _ in
                    AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month()) } }
                .frame(height: 220)
                .accessibilityLabel("Projected balance line chart with monthly net bars")
                HStack(spacing: 16) {
                    Label("Closing balance", systemImage: "line.3.horizontal").font(.caption)
                    Label("Monthly net (bar)", systemImage: "chart.bar").font(.caption)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var monthList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Month by month").font(.headline)
            ForEach(forecast) { m in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(monthLabel(m.monthDate)).font(.headline)
                        if m.goesNegative {
                            Text("LOW").font(.caption2.bold()).padding(3).background(Color.red, in: Capsule()).foregroundStyle(.white)
                        }
                        Spacer()
                        Text(fmt(m.closingBalance)).font(.title3.monospacedDigit())
                            .foregroundStyle(m.closingBalance < 0 ? .red : .primary)
                    }
                    Text("Open \(fmt(m.openingBalance)) • In \(fmt(m.scheduledIncome)) • Bills \(fmt(m.scheduledExpenses)) • Envelopes \(fmt(m.envelopeSpend)) • Net \(fmt(m.net))")
                        .font(.caption).foregroundStyle(.secondary)
                    if !m.events.isEmpty {
                        Text(m.events.map { "\($0.isIncome ? "+" : "−")\(fmt(abs($0.amount))) \($0.name) (\($0.dueDayLabel))" }.joined(separator: "  •  "))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
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

    private func fmt(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "$\(String(format: "%.2f", v))" }
    private func monthLabel(_ d: Date) -> String { DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .none) }
}

private extension ForecastEvent {
    var dueDayLabel: String {
        let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .none
        return df.string(from: date)
    }
}
