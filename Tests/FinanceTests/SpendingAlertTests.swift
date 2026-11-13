import XCTest
import SwiftData
@testable import Finance

final class SpendingAlertTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }
    private var today: Date { date(2026, 11, 12) }
    private func row(_ name: String, _ amount: Double, _ d: Date, category: String = "Dining", account: String = "visa") -> ChargeRow {
        ChargeRow(name: name, amount: amount, date: d, category: category, accountId: account, accountName: account)
    }
    private func detect(_ rows: [ChargeRow], budgets: [(category: String, allocated: Double)] = [], settings: AlertSettings = AlertSettings(),
                        dismissed: Set<String> = []) -> [SpendingAlert] {
        SpendingAlertService.detect(rows, budgets: budgets, settings: settings, dismissed: dismissed, today: today, calendar: cal)
    }

    func testDoubleChargeSameAccountSameAmountWithinDays() {
        let rows = [row("CORNER BISTRO", -46.80, date(2026, 11, 9)), row("CORNER BISTRO", -46.80, date(2026, 11, 10)),
                    row("CORNER BISTRO", -46.80, date(2026, 11, 1), account: "mc"),        // other card: fine
                    row("BEAN THERE COFFEE", -4.50, date(2026, 11, 9)), row("BEAN THERE COFFEE", -4.50, date(2026, 11, 9))]   // too small to matter
        let found = detect(rows)
        XCTAssertEqual(found.map(\.kind), [.duplicate])
        XCTAssertEqual(found.first?.transactionIds.count, 2)
    }

    func testMuchBiggerThanUsualAtAMerchant() {
        var rows = (1...6).map { row("QUICKFUEL #2231", -Double(40 + $0), date(2026, 9, $0 * 4), category: "Transport") }
        rows.append(row("QUICKFUEL #2231", -142.60, date(2026, 11, 7), category: "Transport"))
        rows.append(row("QUICKFUEL #2231", -52, date(2026, 11, 8), category: "Transport"))   // normal
        let found = detect(rows)
        XCTAssertEqual(found.map(\.kind), [.unusual])
        XCTAssertEqual(found.first?.amount, 142.60)
    }

    func testLargeOneOffButNotRegularBigBills() {
        var rows = [row("NORTHGATE APPLIANCES", -689, date(2026, 11, 6), category: "Shopping")]
        rows += (8...11).map { row("LITTLE SPROUTS DAYCARE", -1240, date(2026, $0, 3), category: "Childcare", account: "chk") }
        rows.append(row("CEDAR RIDGE HOME LOANS PMT", -1845, date(2026, 11, 1), category: "Housing", account: "chk"))
        rows.append(row("TRANSFER TO SAVINGS", -5000, date(2026, 11, 2), category: Categorizer.transfer, account: "chk"))
        let found = detect(rows)
        // The mortgage payment has no history in this test, so it counts as a one-off too.
        XCTAssertEqual(Set(found.filter { $0.kind == .large }.map(\.amount)), [689, 1845])
        var off = AlertSettings(); off.largeAmount = 0
        XCTAssertTrue(detect(rows, settings: off).isEmpty)
    }

    func testBudgetOverAndNearlyAt() {
        let rows = [row("CORNER BISTRO", -300, date(2026, 11, 5)), row("FRESH BASKET", -270, date(2026, 11, 6), category: "Groceries"),
                    row("FRESH BASKET", -900, date(2026, 10, 6), category: "Groceries")]   // last month doesn't count
        let found = detect(rows, budgets: [("Dining", 250), ("Groceries", 290), ("Travel", 200)])
        XCTAssertEqual(Set(found.map(\.key)), ["over|Dining|2026-11", "near|Groceries|2026-11"])
        XCTAssertEqual(found.first { $0.kind == .overBudget }?.amount, 50)
    }

    func testDismissedAlertsStayHidden() {
        let rows = [row("CORNER BISTRO", -46.80, date(2026, 11, 9)), row("CORNER BISTRO", -46.80, date(2026, 11, 9))]
        let key = detect(rows)[0].key
        XCTAssertTrue(detect(rows, dismissed: [key]).isEmpty)
    }

    @MainActor
    func testDemoHasOneOfEachChargeAlert() throws {
        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self, OFXProfile.self,
                             CategoryRule.self, CustomCategory.self, SubscriptionMark.self, DismissedAlert.self])
        let context = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12))!
        BackupService.restore(DemoData.make(today: now), in: context)
        let alerts = SpendingAlertService.current(transactions: try context.fetch(FetchDescriptor<TransactionRecord>()),
                                                  accounts: try context.fetch(FetchDescriptor<Account>()),
                                                  envelopes: try context.fetch(FetchDescriptor<Envelope>()),
                                                  dismissed: [], settings: AlertSettings(), today: now)
        for a in alerts { print("ALERT", a.kind, a.title, a.detail) }
        XCTAssertTrue(alerts.contains { $0.kind == .duplicate && $0.title.contains("Corner Bistro") })
        XCTAssertTrue(alerts.contains { $0.kind == .unusual && $0.title.contains("Quickfuel") })
        XCTAssertTrue(alerts.contains { $0.kind == .large && $0.title.contains("Northgate") })
        XCTAssertLessThanOrEqual(alerts.count, 8, "the demo shouldn't drown in alerts")

        // Dismissing one hides it.
        SpendingAlertService.dismiss([alerts[0]], in: context)
        let after = SpendingAlertService.current(transactions: try context.fetch(FetchDescriptor<TransactionRecord>()),
                                                 accounts: try context.fetch(FetchDescriptor<Account>()),
                                                 envelopes: try context.fetch(FetchDescriptor<Envelope>()),
                                                 dismissed: try context.fetch(FetchDescriptor<DismissedAlert>()), settings: AlertSettings(), today: now)
        XCTAssertEqual(after.count, alerts.count - 1)
    }
}
