import XCTest
@testable import Finance

final class ReportTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private var today: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 11))! }
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }
    private func row(_ name: String, _ amount: Double, _ d: Date, _ category: String = "Groceries", account: String = "A") -> ReportRow {
        ReportRow(date: d, name: name, amount: amount, category: category, accountId: account, accountName: account)
    }

    func testRanges() {
        let q = ReportRange.containing(date(2026, 8, 15), kind: .quarter, calendar: cal)
        XCTAssertEqual(q.start, cal.date(from: DateComponents(year: 2026, month: 7, day: 1)))
        XCTAssertEqual(q.end, cal.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        XCTAssertEqual(q.label, "Q3 2026")
        XCTAssertEqual(q.shifted(-1, kind: .quarter, calendar: cal).label, "Q2 2026")
        let y = ReportRange.containing(date(2026, 3, 1), kind: .year, calendar: cal)
        XCTAssertEqual(y.shifted(1, kind: .year, calendar: cal).label, "2027")
        let c = ReportRange.custom(from: date(2026, 3, 10), through: date(2026, 3, 1), calendar: cal)
        XCTAssertTrue(c.contains(date(2026, 3, 10)))
        XCTAssertFalse(c.contains(date(2026, 3, 11)))
    }

    func testIncomeSpendingSavingsRateAndTransfersLeftOut() {
        let rows = [
            row("PAYROLL", 4000, date(2026, 1, 15), "Income"),
            row("FRESH MARKET #12", -300, date(2026, 1, 20)),
            row("FRESH MARKET #40", -200, date(2026, 2, 3)),
            row("CORNER BISTRO", -400, date(2026, 2, 9), "Dining"),
            row("Transfer to savings", -1000, date(2026, 2, 16), Categorizer.transfer),
            row("PAYROLL", 4000, date(2025, 12, 15), "Income"),   // outside the year
        ]
        let r = ReportService.report(rows: rows, range: .containing(date(2026, 6, 1), kind: .year, calendar: cal),
                                     today: today, calendar: cal)
        XCTAssertEqual(r.income, 4000)
        XCTAssertEqual(r.spending, 900)
        XCTAssertEqual(r.savingsRate!, 0.775, accuracy: 0.0001)
        XCTAssertEqual(r.byCategory.first?.category, "Groceries")
        XCTAssertEqual(r.byMerchant.first?.name, "Fresh Market", "store numbers are grouped together")
        XCTAssertEqual(r.byMerchant.first?.count, 2)
        XCTAssertEqual(r.months.count, 11, "January through November (not months after today)")
        XCTAssertEqual(r.biggestMonths(1).first?.month, cal.date(from: DateComponents(year: 2026, month: 2, day: 1)))
        XCTAssertEqual(r.rows.count, 5, "the transfer is still listed")
    }

    func testFiltersByAccountAndCategory() {
        let rows = [
            row("FRESH MARKET", -100, date(2026, 5, 1), account: "A"),
            row("FRESH MARKET", -50, date(2026, 5, 2), account: "B"),
            row("CORNER BISTRO", -20, date(2026, 5, 3), "Dining", account: "A"),
        ]
        let range = ReportRange.containing(date(2026, 5, 1), kind: .month, calendar: cal)
        let a = ReportService.report(rows: rows, range: range, filter: ReportFilter(accountIds: ["A"]), today: today, calendar: cal)
        XCTAssertEqual(a.spending, 120)
        let g = ReportService.report(rows: rows, range: range, filter: ReportFilter(categories: ["Groceries"]),
                                     netWorthToday: 1000, today: today, calendar: cal)
        XCTAssertEqual(g.spending, 150)
        XCTAssertNil(g.netWorthChange, "net worth means nothing for one category")
    }

    func testNetWorthChangeWorksBackFromToday() {
        let rows = [
            row("PAYROLL", 3000, date(2026, 3, 15), "Income"),
            row("RENT", -1000, date(2026, 3, 1), "Housing"),
            row("PAYROLL", 3000, date(2026, 4, 15), "Income"),   // after March
        ]
        let r = ReportService.report(rows: rows, range: .containing(date(2026, 3, 1), kind: .month, calendar: cal),
                                     netWorthToday: 10_000, today: today, calendar: cal)
        XCTAssertEqual(r.netWorthEnd, 7000)
        XCTAssertEqual(r.netWorthStart, 5000)
        XCTAssertEqual(r.netWorthChange, 2000)
    }

    func testFeesAndInterest() {
        XCTAssertTrue(ReportService.isFeeOrInterest(row("MONTHLY SERVICE FEE", -12, today, "Other")))
        XCTAssertTrue(ReportService.isFeeOrInterest(row("INTEREST CHARGE ON PURCHASES", -8.62, today, "Other")))
        XCTAssertTrue(ReportService.isFeeOrInterest(row("Anything", -5, today, "Bank Fees")))
        XCTAssertTrue(ReportService.isFeeOrInterest(row("FINANCE CHARGE", -3, today, "Other")))
        XCTAssertFalse(ReportService.isFeeOrInterest(row("BEAN THERE COFFEE", -5, today, "Dining")), "COFFEE isn't FEE")
        XCTAssertFalse(ReportService.isFeeOrInterest(row("INTEREST PAID", 4.10, today, "Income")), "interest earned isn't a cost")
    }

    func testSubscriptionsPaidInRange() {
        let charges = (1...6).map { row("STREAMFLIX", -15.49, date(2026, $0 + 4, 7), "Entertainment") }
        let subs = SubscriptionService.detect(charges.map {
            ChargeRow(id: $0.id, name: $0.name, amount: $0.amount, date: $0.date, category: $0.category, accountId: "A")
        }, today: today, calendar: cal)
        let r = ReportService.report(rows: charges, range: .containing(date(2026, 1, 1), kind: .year, calendar: cal),
                                     subscriptions: subs, today: today, calendar: cal)
        XCTAssertEqual(r.subscriptionsPaid, 15.49 * 6, accuracy: 0.001)
        XCTAssertEqual(r.subscriptionsAnnual, 15.49 * 12, accuracy: 0.001)
        XCTAssertEqual(r.subscriptionCount, 1)
    }

    func testCSVEscapesAndListsEverything() {
        let rows = [row("=HYPERLINK(\"x\")", -10, date(2026, 5, 1)), row("SMITH, JONES & CO", -5, date(2026, 5, 2))]
        let r = ReportService.report(rows: rows, range: .containing(date(2026, 5, 1), kind: .month, calendar: cal), today: today, calendar: cal)
        let csv = ReportService.csv(r)
        XCTAssertTrue(csv.contains("\"'=HYPERLINK(\"\"x\"\")\""), csv)
        XCTAssertTrue(csv.contains("\"SMITH, JONES & CO\""))
        XCTAssertTrue(csv.contains("Spending,15.00"))
        XCTAssertEqual(ReportService.escape("-12.50"), "-12.50", "numbers aren't touched")
    }

    func testDemoDataHasFeesInTheYearInReview() {
        let file = DemoData.make(today: today, calendar: cal)
        let rows = file.transactions.map {
            ReportRow(id: $0.id, date: $0.date, name: $0.name, amount: $0.amount, category: $0.category,
                      accountId: $0.accountId, accountName: $0.accountName, isLinkedTransfer: $0.transferPeerId != nil)
        }
        let r = ReportService.report(rows: rows, range: .containing(today, kind: .year, calendar: cal), today: today, calendar: cal)
        XCTAssertGreaterThanOrEqual(r.fees.count, 3)
        XCTAssertGreaterThan(r.income, r.spending, "the demo household saves money")
    }
}
