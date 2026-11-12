import SwiftUI
import SwiftData
import Charts
import UIKit

/// The phone's Year in Review (`yearInReview: true`) and Reports screens: the same numbers as the Mac,
/// with CSV and PDF export through the share sheet (which also prints).
struct ReportsScreen: View {
    var yearInReview: Bool

    @Query(sort: \Account.name) private var accounts: [Account]
    @Query(sort: \TransactionRecord.date, order: .reverse) private var transactions: [TransactionRecord]
    @Query private var marks: [SubscriptionMark]

    @State private var kind: ReportPeriodKind = .month
    @State private var anchor = Date()
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var customFrom = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
    @State private var customThrough = Date()
    @State private var accountId: String? = nil
    @State private var category: String? = nil
    @State private var shareURL: URL?

    private var range: ReportRange {
        if yearInReview {
            return .containing(Calendar.current.date(from: DateComponents(year: year, month: 1, day: 1)) ?? Date(), kind: .year)
        }
        return kind == .custom ? .custom(from: customFrom, through: customThrough) : .containing(anchor, kind: kind)
    }
    private var filter: ReportFilter {
        ReportFilter(accountIds: accountId.map { [$0] }, categories: category.map { [$0] })
    }

    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }
    private func signed(_ v: Double) -> String { (v > 0 ? "+" : "") + money(v) }

    var body: some View {
        let r = ReportService.build(transactions: transactions, accounts: accounts, marks: marks, range: range, filter: filter)
        List {
            Section { controls(r) }
            Section("Summary") {
                line("Money in", money(r.income), color: .green)
                line("Money out", money(r.spending))
                line("Net", money(r.net), color: r.net < 0 ? .red : nil)
                if let s = r.savingsRate { line("Savings rate", String(format: "%.0f%%", s * 100)) }
                if let c = r.netWorthChange { line("Net worth change", signed(c), color: c < 0 ? .red : .green) }
                line("Fees and interest", money(r.feesTotal), color: r.feesTotal > 0 ? .red : nil)
                line("Paid to subscriptions", money(r.subscriptionsPaid))
                if yearInReview { line("Subscriptions now, per year", money(r.subscriptionsAnnual)) }
            }
            if r.months.count > 1 {
                Section("By month") {
                    Chart {
                        ForEach(r.months) { m in
                            BarMark(x: .value("Month", m.month, unit: .month), y: .value("Amount", m.income))
                                .foregroundStyle(by: .value("Kind", "In")).position(by: .value("Kind", "In"))
                            BarMark(x: .value("Month", m.month, unit: .month), y: .value("Amount", m.spending))
                                .foregroundStyle(by: .value("Kind", "Out")).position(by: .value("Kind", "Out"))
                        }
                    }
                    .chartForegroundStyleScale(["In": Color.green.opacity(0.7), "Out": Color.orange.opacity(0.75)])
                    .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.narrow), centered: true) } }
                    .frame(height: 160)
                    if yearInReview {
                        ForEach(r.biggestMonths()) { m in
                            line("Biggest: \(m.month.formatted(.dateTime.month(.wide)))", money(m.spending))
                        }
                    }
                }
            }
            Section("Top categories") {
                if r.byCategory.isEmpty { Text("No spending").foregroundStyle(.secondary) }
                ForEach(r.byCategory.prefix(yearInReview ? 8 : 20)) { c in share(c.category, c.amount, of: r.spending) }
            }
            Section("Top merchants") {
                if r.byMerchant.isEmpty { Text("No spending").foregroundStyle(.secondary) }
                ForEach(r.byMerchant.prefix(yearInReview ? 8 : 20)) { m in share(m.name, m.amount, of: r.spending) }
            }
            if !r.fees.isEmpty {
                Section("Fees and interest") {
                    ForEach(r.fees) { t in tx(t) }
                }
            }
            if !yearInReview {
                Section("Transactions (\(r.rows.count))") {
                    ForEach(r.rows.prefix(200)) { t in tx(t) }
                    if r.rows.count > 200 { Text("Export to see all \(r.rows.count).").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle(yearInReview ? "\(String(year)) in Review" : "Reports")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { export(r, pdf: false) } label: { Label("Export CSV", systemImage: "tablecells") }
                    Button { export(r, pdf: true) } label: { Label("Export or Print PDF", systemImage: "doc.richtext") }
                } label: { Image(systemName: "square.and.arrow.up") }
            }
        }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL { ActivitySheet(items: [shareURL]).ignoresSafeArea() }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func controls(_ r: PeriodReport) -> some View {
        if yearInReview {
            Picker("Year", selection: $year) {
                ForEach(ReportService.years(in: transactions.map(ReportRow.init)), id: \.self) { Text(String($0)).tag($0) }
            }
        } else {
            Picker("Period", selection: $kind) {
                ForEach(ReportPeriodKind.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if kind == .custom {
                DatePicker("From", selection: $customFrom, displayedComponents: .date)
                DatePicker("Through", selection: $customThrough, displayedComponents: .date)
            } else {
                HStack {
                    Button { anchor = range.shifted(-1, kind: kind).start } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless)
                    Spacer()
                    Text(r.range.label).font(.headline)
                    Spacer()
                    Button { anchor = range.shifted(1, kind: kind).start } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless)
                }
            }
            Picker("Category", selection: $category) {
                Text("All categories").tag(String?.none)
                ForEach(BudgetService.allCategories(stored: transactions.map(\.category)), id: \.self) { Text($0).tag(Optional($0)) }
            }
        }
        Picker("Account", selection: $accountId) {
            Text("All accounts").tag(String?.none)
            ForEach(accounts) { Text($0.name).tag(Optional($0.accountId)) }
        }
    }

    private func line(_ k: String, _ v: String, color: Color? = nil) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).monospacedDigit().foregroundStyle(color ?? .primary)
        }
    }

    private func share(_ name: String, _ amount: Double, of total: Double) -> some View {
        HStack {
            Text(name).lineLimit(1)
            Spacer()
            Text(money(amount)).monospacedDigit()
            if total > 0 { Text(String(format: "%.0f%%", amount / total * 100)).font(.caption).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing) }
        }
    }

    private func tx(_ t: ReportRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(t.name).lineLimit(1)
                Text("\(t.date.formatted(.dateTime.month(.abbreviated).day())) • \(t.category)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(money(t.amount)).monospacedDigit().foregroundStyle(t.isTransfer ? .blue : (t.amount < 0 ? .primary : .green))
        }
    }

    @MainActor
    private func export(_ r: PeriodReport, pdf: Bool) {
        let name = ReportService.fileName(r, ext: pdf ? "pdf" : "csv", yearInReview: yearInReview)
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        let title = yearInReview ? "\(String(year)) in Review" : "Finance Report"
        let data: Data
        if pdf {
            data = ReportPDF.make(r, title: title, filterLine: ReportService.filterLine(r.filter, accounts: accounts))
        } else {
            let names = r.filter.accountIds.map { ids in accounts.filter { ids.contains($0.accountId) }.map(\.name) } ?? []
            data = Data(ReportService.csv(r, accountNames: names, categoryNames: r.filter.categories.map { $0.sorted() } ?? []).utf8)
        }
        do { try data.write(to: url, options: .atomic); shareURL = url } catch { shareURL = nil }
    }
}

/// The system share sheet (save to Files, AirDrop, Mail, Print…).
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
