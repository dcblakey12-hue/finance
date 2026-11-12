import SwiftUI
import CoreGraphics

/// A printable PDF of a report (US Letter): a summary page, then every transaction.
/// Shared by the Mac and iPhone apps.
enum ReportPDF {
    static let pageSize = CGSize(width: 612, height: 792)
    static let rowsPerPage = 44

    @MainActor
    static func make(_ r: PeriodReport, title: String, filterLine: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }

        let txPages = stride(from: 0, to: r.rows.count, by: rowsPerPage).map { Array(r.rows[$0..<min($0 + rowsPerPage, r.rows.count)]) }
        let pageCount = 1 + txPages.count
        func draw<V: View>(_ v: V) {
            let renderer = ImageRenderer(content: v.frame(width: pageSize.width, height: pageSize.height).environment(\.colorScheme, .light))
            renderer.proposedSize = ProposedViewSize(pageSize)
            ctx.beginPDFPage(nil)
            renderer.render { _, render in render(ctx) }
            ctx.endPDFPage()
        }
        draw(SummaryPage(r: r, title: title, filterLine: filterLine, page: 1, of: pageCount))
        for (i, rows) in txPages.enumerated() {
            draw(TransactionsPage(rows: rows, title: title, page: i + 2, of: pageCount))
        }
        ctx.closePDF()
        return data as Data
    }

    fileprivate static func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }

    private struct Footer: View {
        let title: String, page: Int, of: Int
        var body: some View {
            HStack {
                Text(title)
                Spacer()
                Text("Page \(page) of \(of) • \(Date().formatted(date: .abbreviated, time: .omitted))")
            }.font(.system(size: 8)).foregroundStyle(.gray)
        }
    }

    private struct SummaryPage: View {
        let r: PeriodReport, title: String, filterLine: String, page: Int, of: Int

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 22, weight: .bold))
                    Text(r.range.label).font(.system(size: 13))
                    Text(filterLine).font(.system(size: 9)).foregroundStyle(.gray)
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow { kv("Income", money(r.income)); kv("Spending", money(r.spending)); kv("Net", money(r.net)) }
                    GridRow {
                        kv("Savings rate", r.savingsRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                        kv("Net worth change", r.netWorthChange.map(money) ?? "—")
                        kv("Fees and interest", money(r.feesTotal))
                    }
                    GridRow {
                        kv("Paid to subscriptions", money(r.subscriptionsPaid))
                        kv("Subscriptions, per year now", money(r.subscriptionsAnnual))
                        kv("Average spending a month", money(r.averageMonthlySpending))
                    }
                }
                HStack(alignment: .top, spacing: 18) {
                    table("By month", ["Month", "Income", "Spending", "Net"],
                          r.months.suffix(12).map { [$0.month.formatted(.dateTime.month(.abbreviated).year(.twoDigits)), money($0.income), money($0.spending), money($0.net)] })
                    table("Top categories", ["Category", "Spent", "%"],
                          r.byCategory.prefix(12).map { [$0.category, money($0.amount), r.spending > 0 ? String(format: "%.0f%%", $0.amount / r.spending * 100) : ""] })
                }
                HStack(alignment: .top, spacing: 18) {
                    table("Top merchants", ["Merchant", "Spent", "#"],
                          r.byMerchant.prefix(12).map { [$0.name, money($0.amount), String($0.count)] })
                    table("Fees and interest", ["Payee", "Date", "Amount"],
                          r.fees.prefix(12).map { [$0.name, $0.date.formatted(.dateTime.month(.abbreviated).day()), money(-$0.amount)] },
                          empty: "None in this period")
                }
                Spacer(minLength: 0)
                Footer(title: title, page: page, of: of)
            }
            .padding(36)
            .foregroundStyle(.black)
            .background(.white)
        }

        private func kv(_ k: String, _ v: String) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                Text(k).font(.system(size: 8)).foregroundStyle(.gray)
                Text(v).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
        }

        /// First column takes the spare room; the others are fixed-width numbers.
        @ViewBuilder private func cell(_ v: String, _ i: Int) -> some View {
            if i == 0 { Text(v).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
            else { Text(v).lineLimit(1).frame(width: 62, alignment: .trailing) }
        }

        private func table(_ heading: String, _ cols: [String], _ rows: [[String]], empty: String = "Nothing to show") -> some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(heading).font(.system(size: 11, weight: .bold))
                HStack {
                    ForEach(Array(cols.enumerated()), id: \.offset) { i, c in cell(c, i) }
                }.font(.system(size: 8, weight: .semibold)).foregroundStyle(.gray)
                if rows.isEmpty { Text(empty).font(.system(size: 9)).foregroundStyle(.gray) }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        ForEach(Array(row.enumerated()), id: \.offset) { i, v in cell(v, i) }
                    }.font(.system(size: 9)).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private struct TransactionsPage: View {
        let rows: [ReportRow], title: String, page: Int, of: Int
        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text("Transactions").font(.system(size: 13, weight: .bold)).padding(.bottom, 4)
                HStack(spacing: 8) {
                    Text("Date").frame(width: 62, alignment: .leading)
                    Text("Payee").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Category").frame(width: 100, alignment: .leading)
                    Text("Account").frame(width: 110, alignment: .leading)
                    Text("Amount").frame(width: 72, alignment: .trailing)
                }.font(.system(size: 8, weight: .semibold)).foregroundStyle(.gray)
                ForEach(rows) { t in
                    HStack(spacing: 8) {
                        Text(t.date.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits))).frame(width: 62, alignment: .leading)
                        Text(t.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(t.category).lineLimit(1).frame(width: 100, alignment: .leading)
                        Text(t.accountName).lineLimit(1).frame(width: 110, alignment: .leading)
                        Text(money(t.amount)).frame(width: 72, alignment: .trailing)
                    }
                    .font(.system(size: 9)).monospacedDigit()
                    .foregroundStyle(t.isTransfer ? .gray : .black)
                }
                Spacer(minLength: 0)
                Footer(title: title, page: page, of: of)
            }
            .padding(36)
            .foregroundStyle(.black)
            .background(.white)
        }
    }
}
