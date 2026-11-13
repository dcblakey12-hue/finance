import XCTest
import SwiftData
@testable import Finance

final class BillReminderTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }
    private var now: Date { date(2026, 11, 12, 8) }

    private func schedule(_ name: String, _ amount: Double, day: Int, income: Bool = false, transfer: Bool = false,
                          excluded: Set<Date> = [], tracked: Date? = nil) -> ReminderSchedule {
        ReminderSchedule(id: UUID(), name: name, amount: amount, isIncome: income, isTransfer: transfer,
                         rule: ScheduleRule(frequency: .monthly, dueDay: day, excluded: excluded), trackedSince: tracked)
    }

    func testBillReminderArrivesDaysBeforeAtTheChosenHour() {
        var s = ReminderSettings(); s.billsOn = true; s.daysBefore = 3; s.hour = 9
        let plan = BillReminderService.plan([schedule("Electric", 125, day: 18)], settings: s, now: now, calendar: cal)
        XCTAssertEqual(plan.first?.dueDate, date(2026, 11, 18))
        XCTAssertEqual(plan.first?.fireDate, date(2026, 11, 15, 9))
        XCTAssertEqual(plan.first?.body(calendar: cal).hasPrefix("$125.00 is due in 3 days"), true)
        XCTAssertEqual(plan.count, 1, "Dec 18 is past the 35 days the app looks ahead")
    }

    func testReminderWhoseTimeHasPassedIsSkipped() {
        var s = ReminderSettings(); s.billsOn = true; s.daysBefore = 3
        // Due the 13th: three days before was the 10th, already gone.
        let plan = BillReminderService.plan([schedule("Water", 50, day: 13)], settings: s, now: now, calendar: cal)
        XCTAssertEqual(plan.map(\.dueDate), [date(2026, 12, 13)])
    }

    func testEnteredOrSkippedPaymentsAndTransfersFollowSettings() {
        var s = ReminderSettings(); s.billsOn = true; s.daysBefore = 0
        let skipped = schedule("Gym", 49, day: 20, excluded: [date(2026, 11, 20)])
        let card = schedule("Move to savings", 900, day: 25, transfer: true)
        XCTAssertTrue(BillReminderService.plan([skipped], settings: s, now: now, calendar: cal).isEmpty)
        XCTAssertEqual(BillReminderService.plan([schedule("Gym", 49, day: 20)], settings: s, now: now, calendar: cal).count, 1)
        XCTAssertTrue(BillReminderService.plan([card], settings: s, now: now, calendar: cal).isEmpty, "savings moves are off by default")
        s.includeTransfers = true
        XCTAssertEqual(BillReminderService.plan([card], settings: s, now: now, calendar: cal).count, 1)
    }

    func testLatePaycheckReminderFiresAfterTheGraceDaysUnlessItArrived() {
        var s = ReminderSettings(); s.paychecksOn = true; s.graceDays = 2; s.hour = 9
        let pay = schedule("Paycheck", 2000, day: 11, income: true, tracked: date(2026, 1, 1))
        let plan = BillReminderService.plan([pay], settings: s, now: now, calendar: cal)
        // Nov 11's paycheck: told on the 13th at 9 unless it's entered before then.
        XCTAssertEqual(plan.first?.kind, .paycheckLate)
        XCTAssertEqual(plan.first?.fireDate, date(2026, 11, 13, 9))
        let arrived = schedule("Paycheck", 2000, day: 11, income: true, excluded: [date(2026, 11, 11)], tracked: date(2026, 1, 1))
        XCTAssertEqual(BillReminderService.plan([arrived], settings: s, now: now, calendar: cal).first?.dueDate, date(2026, 12, 11))
    }

    func testNothingWhenTurnedOff() {
        let plan = BillReminderService.plan([schedule("Electric", 125, day: 18), schedule("Pay", 1, day: 15, income: true)],
                                            settings: ReminderSettings(), now: now, calendar: cal)
        XCTAssertTrue(plan.isEmpty)
    }

    func testSettingsReadFromDefaults() {
        let d = UserDefaults(suiteName: "reminder-test-\(UUID().uuidString)")!
        XCTAssertEqual(ReminderSettings(defaults: d), ReminderSettings())
        d.set(true, forKey: ReminderSettings.Key.bills); d.set(5, forKey: ReminderSettings.Key.daysBefore)
        let s = ReminderSettings(defaults: d)
        XCTAssertTrue(s.billsOn); XCTAssertEqual(s.daysBefore, 5); XCTAssertEqual(s.graceDays, 2)
    }

    func testCardAndLoanPaymentsCountAsBillsOtherTransfersDont() {
        let visa = Account(name: "Visa", type: .creditCard, accountId: "visa", bankName: "")
        let save = Account(name: "Savings", type: .savings, accountId: "sav", bankName: "")
        func transfer(to: String) -> RecurringBill {
            let b = RecurringBill(name: "T", amount: 100, dueDay: 20, category: Categorizer.transfer)
            b.kindRaw = "transfer"; b.fromAccountId = "chk"; b.toAccountId = to
            return b
        }
        let mapped = BillReminderService.schedules([transfer(to: "visa"), transfer(to: "sav")], accounts: [visa, save])
        XCTAssertEqual(mapped.map(\.isTransfer), [false, true])
    }

    /// Another bill of a similar size paid a few days earlier mustn't count as next week's bill paid early
    /// (it hid the Electric reminder in the demo).
    @MainActor
    func testSimilarSizedOtherBillDoesNotMarkUpcomingBillPaid() throws {
        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                             OFXProfile.self, CategoryRule.self, CustomCategory.self, SubscriptionMark.self])
        let context = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
        let electric = RecurringBill(name: "Electric", amount: 125, dueDay: 18, category: "Utilities")
        electric.trackedSince = date(2026, 11, 12)
        context.insert(electric)
        let insurance = TransactionRecord(fitid: "1", accountId: "chk", accountName: "Checking", date: date(2026, 11, 9, 12),
                                          name: "SHIELD AUTO INSURANCE", amount: -138.40, type: .debit, category: "Transport")
        context.insert(insurance)
        XCTAssertEqual(ScheduleService.autoResolve(with: [insurance], in: context, today: now, calendar: cal), 0)
        XCTAssertEqual(electric.rule.nextDate(from: now, calendar: cal), date(2026, 11, 18))
    }
}
