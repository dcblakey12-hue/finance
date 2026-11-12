import SwiftUI
import SwiftData
import Charts
import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Reports: pick a month, quarter, year or your own dates, narrow to some accounts or categories,
/// and see (and export) income, spending, categories, merchants and every transaction.
struct ReportsView: View {
    @Query(sort: \Account.name) private var accounts: [Account]
    @Query(sort: \TransactionRecord.date, order: .reverse) private var transactions: [TransactionRecord]
    @Query private var marks: [SubscriptionMark]
    @Query private var customCategories: [CustomCategory]

    @AppStorage("finance.reports.kind") private var kindRaw = ReportPeriodKind.month.rawValue
    @State private var anchor = Date()
    @State private var customFrom = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
    @State private var customThrough = Date()
    @State private var filter = ReportFilter()
    @State private var showAccounts = false
    @State private var showCategories = false
    @State private var showAllTransactions = false

    private var kind: ReportPeriodKind { ReportPeriodKind(rawValue: kindRaw) ?? .month }
    private var range: ReportRange {
        kind == .custom ? .custom(from: customFrom, through: customThrough) : .containing(anchor, kind: kind)
    }
    private var categoryChoices: [String] {
        let used = Set(transactions.map(\.category))
        return BudgetService.allCategories(stored: customCategories.map(\.name) + Array(used))
    }

    var body: some View {
        let r = ReportService.build(transactions: transactions, accounts: accounts, marks: marks, range: range, filter: filter)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(r)
                if transactions.isEmpty {
                    ContentUnavailableView("Nothing to report yet", systemImage: "doc.text.magnifyingglass",
                                           description: Text("Import an OFX file or connect a bank to see reports."))
                } else {
                    kpis(r)
                    if r.months.count > 1 { monthsCard(r) }
                    HStack(alignment: .top, spacing: 14) {
                        ReportCard("Spending by category") { categoryTable(r) }
                        ReportCard("Top merchants") { merchantTable(r) }
                    }
                    if !r.fees.isEmpty {
                        ReportCard("Fees and interest • \(money(r.feesTotal))") {
                            ForEach(r.fees) { t in txRow(t) }
                        }
                    }
                    ReportCard("Transactions (\(r.rows.count))") {
                        let shown = showAllTransactions ? r.rows : Array(r.rows.prefix(50))
                        if r.rows.isEmpty { Text("No transactions in this period.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(shown) { t in txRow(t) }
                        if r.rows.count > 50 {
                            Button(showAllTransactions ? "Show fewer" : "Show all \(r.rows.count)") { showAllTransactions.toggle() }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Reports")
        .toolbar {
            ToolbarItem { ReportExportMenu(report: r, title: "Finance Report", filterLine: ReportService.filterLine(filter, accounts: accounts), accounts: accounts) }
        }
    }

    // MARK: - Pieces

    private func header(_ r: PeriodReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Reports").font(.largeTitle.bold())
                Spacer()
            }
            HStack(spacing: 12) {
                Picker("Period", selection: $kindRaw) {
                    ForEach(ReportPeriodKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                if kind == .custom {
                    DatePicker("From", selection: $customFrom, displayedComponents: .date).labelsHidden()
                    Text("to").foregroundStyle(.secondary)
                    DatePicker("Through", selection: $customThrough, displayedComponents: .date).labelsHidden()
                } else {
                    Button { anchor = range.shifted(-1, kind: kind).start } label: { Image(systemName: "chevron.left") }
                    Text(r.range.label).font(.headline).frame(minWidth: 140)
                    Button { anchor = range.shifted(1, kind: kind).start } label: { Image(systemName: "chevron.right") }
                    Button("Today") { anchor = Date() }.disabled(range.contains(Date()))
                }
                Spacer()
                Button { showAccounts.toggle() } label: {
                    Label(filter.accountIds.map { "\($0.count) of \(accounts.count) accounts" } ?? "All accounts", systemImage: "building.columns")
                }
                .popover(isPresented: $showAccounts, arrowEdge: .bottom) {
                    MultiPicker(title: "Accounts in the report", all: accounts.map { ($0.accountId, $0.name) }, selection: $filter.accountIds)
                }
                Button { showCategories.toggle() } label: {
                    Label(filter.categories.map { $0.count == 1 ? $0.first! : "\($0.count) categories" } ?? "All categories", systemImage: "tag")
                }
                .popover(isPresented: $showCategories, arrowEdge: .bottom) {
                    MultiPicker(title: "Categories in the report", all: categoryChoices.map { ($0, $0) }, selection: $filter.categories, startEmpty: true)
                }
                if !filter.isEmpty { Button("Clear filters") { filter = ReportFilter() }.buttonStyle(.link) }
            }
        }
    }

    private func kpis(_ r: PeriodReport) -> some View {
        HStack(spacing: 14) {
            KpiCard(title: "Income", value: money(r.income), icon: "arrow.down.circle")
            KpiCard(title: "Spending", value: money(r.spending), icon: "arrow.up.circle",
                    caption: r.months.count > 1 ? "\(money(r.averageMonthlySpending)) a month on average" : nil)
            KpiCard(title: "Net", value: money(r.net), icon: "plus.forwardslash.minus",
                    caption: r.savingsRate.map { String(format: "Savings rate %.0f%%", $0 * 100) }, tint: r.net < 0 ? .red : .green)
            KpiCard(title: "Net worth change", value: r.netWorthChange.map(signed) ?? "—", icon: "wallet.bifold",
                    caption: r.netWorthEnd.map { "Now \(money($0))" } ?? (filter.categories != nil ? "Not shown with a category filter" : nil),
                    tint: (r.netWorthChange ?? 0) < 0 ? .red : nil)
        }
    }

    private func monthsCard(_ r: PeriodReport) -> some View {
        ReportCard("Income and spending by month") {
            IncomeSpendingChart(months: r.months).frame(height: 180)
        }
    }

    private func categoryTable(_ r: PeriodReport) -> some View {
        VStack(spacing: 4) {
            if r.byCategory.isEmpty { Text("No spending.").font(.caption).foregroundStyle(.secondary) }
            ForEach(r.byCategory) { c in
                ShareRow(name: c.category, amount: c.amount, share: r.spending > 0 ? c.amount / r.spending : 0, detail: "\(c.count)")
            }
        }
    }

    private func merchantTable(_ r: PeriodReport) -> some View {
        VStack(spacing: 4) {
            if r.byMerchant.isEmpty { Text("No spending.").font(.caption).foregroundStyle(.secondary) }
            ForEach(r.byMerchant.prefix(15)) { m in
                ShareRow(name: m.name, amount: m.amount, share: r.spending > 0 ? m.amount / r.spending : 0, detail: "\(m.count)")
            }
        }
    }

    private func txRow(_ t: ReportRow) -> some View {
        HStack {
            Text(t.date, format: .dateTime.month(.abbreviated).day().year(.twoDigits)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(t.name).lineLimit(1)
            Spacer()
            Text(t.category).foregroundStyle(.secondary).lineLimit(1).frame(width: 120, alignment: .leading)
            Text(t.accountName).foregroundStyle(.secondary).lineLimit(1).frame(width: 140, alignment: .leading)
            Text(money(t.amount)).monospacedDigit().frame(width: 90, alignment: .trailing)
                .foregroundStyle(t.isTransfer ? .blue : (t.amount < 0 ? .primary : .green))
        }.font(.callout)
    }
}

// MARK: - Shared pieces (Year in Review uses these too)

func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }
func signed(_ v: Double) -> String { (v > 0 ? "+" : "") + money(v) }

struct ReportCard<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Name, a thin bar for its share, the amount.
struct ShareRow: View {
    let name: String, amount: Double, share: Double
    var detail: String? = nil
    var body: some View {
        HStack(spacing: 8) {
            Text(name).lineLimit(1).frame(minWidth: 120, alignment: .leading)
            GeometryReader { g in
                Capsule().fill(Color.accentColor.opacity(0.6)).frame(width: max(2, g.size.width * min(1, share)), height: 6)
                    .frame(maxHeight: .infinity, alignment: .center)
            }.frame(height: 14)
            Text(money(amount)).monospacedDigit().frame(width: 90, alignment: .trailing)
            Text(String(format: "%.0f%%", share * 100)).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }.font(.callout)
    }
}

struct IncomeSpendingChart: View {
    let months: [ReportMonth]
    var body: some View {
        Chart {
            ForEach(months) { m in
                BarMark(x: .value("Month", m.month, unit: .month), y: .value("Amount", m.income))
                    .foregroundStyle(by: .value("Kind", "Income")).position(by: .value("Kind", "Income"))
                BarMark(x: .value("Month", m.month, unit: .month), y: .value("Amount", m.spending))
                    .foregroundStyle(by: .value("Kind", "Spending")).position(by: .value("Kind", "Spending"))
            }
        }
        .chartForegroundStyleScale(["Income": Color.green.opacity(0.7), "Spending": Color.orange.opacity(0.75)])
        .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.narrow), centered: true) } }
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(d, format: .currency(code: currency.currencyCode ?? "USD").precision(.fractionLength(0))) } } } }
    }
}

/// Tick the items to include. All ticked (or none, with `startEmpty`) means no filter (nil).
struct MultiPicker: View {
    let title: String
    let all: [(id: String, name: String)]
    @Binding var selection: Set<String>?
    /// When true, "no filter" shows everything unticked and ticking one narrows to it (handy for categories).
    var startEmpty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(all, id: \.id) { item in Toggle(item.name, isOn: binding(item.id)) }
                }
            }.frame(maxHeight: 360)
            Divider()
            Button(startEmpty ? "All (no filter)" : "All") { selection = nil }.disabled(selection == nil)
        }
        .padding(12).frame(minWidth: 240)
    }

    private func binding(_ id: String) -> Binding<Bool> {
        let everything = Set(all.map(\.id))
        return Binding(
            get: { selection?.contains(id) ?? !startEmpty },
            set: { on in
                var s = selection ?? (startEmpty ? [] : everything)
                if on { s.insert(id) } else { s.remove(id) }
                selection = (s.isEmpty || s == everything) ? nil : s
            })
    }
}

/// Export the report as CSV or PDF, or print it.
struct ReportExportMenu: View {
    let report: PeriodReport
    let title: String
    let filterLine: String
    let accounts: [Account]
    var yearInReview = false

    var body: some View {
        Menu {
            Button("Export CSV…") { exportCSV() }
            Button("Export PDF…") { exportPDF() }
            Divider()
            Button("Print…") { printPDF() }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .help("Save this report as a spreadsheet (CSV) or a printable PDF")
    }

    private func save(_ data: Data, ext: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ReportService.fileName(report, ext: ext, yearInReview: yearInReview)
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) }
        catch {
            let a = NSAlert(); a.messageText = "Couldn't save the report: \(error.localizedDescription)"; a.runModal()
        }
    }

    private func exportCSV() {
        let names = report.filter.accountIds.map { ids in accounts.filter { ids.contains($0.accountId) }.map(\.name).sorted() } ?? []
        let csv = ReportService.csv(report, accountNames: names, categoryNames: report.filter.categories.map { $0.sorted() } ?? [])
        save(Data(csv.utf8), ext: "csv", type: .commaSeparatedText)
    }

    @MainActor private func exportPDF() {
        save(ReportPDF.make(report, title: title, filterLine: filterLine), ext: "pdf", type: .pdf)
    }

    @MainActor private func printPDF() {
        guard let doc = PDFDocument(data: ReportPDF.make(report, title: title, filterLine: filterLine)) else { return }
        let info = NSPrintInfo.shared
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        doc.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true)?
            .runModal(for: NSApp.keyWindow ?? NSApp.windows.first!, delegate: nil, didRun: nil, contextInfo: nil)
    }
}
