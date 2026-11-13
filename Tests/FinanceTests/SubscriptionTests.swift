import XCTest
import SwiftData
@testable import Finance

@MainActor
final class SubscriptionTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private var today: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 11))! }
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }
    private func charge(_ name: String, _ amount: Double, _ d: Date, category: String = "Entertainment") -> ChargeRow {
        ChargeRow(name: name, amount: amount, date: d, category: category, accountName: "Visa")
    }

    func testFindsMonthlyChargeWithTotalsAndNextDate() {
        let rows = (5...10).map { charge("STREAMFLIX \($0)/07", -15.49, date(2026, $0, 7)) }
        let found = SubscriptionService.detect(rows, today: today, calendar: cal)
        XCTAssertEqual(found.count, 1)
        let s = found[0]
        XCTAssertEqual(s.name, "Streamflix")
        XCTAssertEqual(s.cadence, .monthly)
        XCTAssertEqual(s.chargeCount, 6)
        XCTAssertTrue(s.isFixedAmount)
        XCTAssertEqual(cal.dateComponents([.month, .day], from: s.nextExpected), DateComponents(month: 11, day: 7))
        XCTAssertFalse(s.mayHaveStopped)
        XCTAssertEqual(s.annualCost, 15.49 * 12, accuracy: 0.001)
        XCTAssertEqual(SubscriptionService.totals(found).monthly, 15.49, accuracy: 0.001)
    }

    func testPriceRiseStaysOneSubscription() {
        let rows = (5...10).map { charge("TUNEBOX MUSIC", $0 >= 9 ? -11.99 : -10.99, date(2026, $0, 14)) }
        let found = SubscriptionService.detect(rows, today: today, calendar: cal)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].amount, 11.99)
        XCTAssertFalse(found[0].isFixedAmount)
    }

    func testWeeklyAndYearly() {
        var rows: [ChargeRow] = (0..<10).map { charge("MORNING LEDGER DIGITAL", -3.99, cal.date(byAdding: .day, value: -7 * $0, to: today)!) }
        rows += [charge("CLOUDNEST STORAGE ANNUAL", -99.99, date(2024, 12, 1)), charge("CLOUDNEST STORAGE ANNUAL", -99.99, date(2025, 12, 1))]
        let found = SubscriptionService.detect(rows, today: today, calendar: cal)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: found.map { ($0.merchantKey, $0.cadence) }),
                       ["MORNING LEDGER": .weekly, "CLOUDNEST STORAGE": .yearly])
        let weekly = found.first { $0.cadence == .weekly }!
        XCTAssertEqual(weekly.monthlyCost, 3.99 * 52 / 12, accuracy: 0.001)
    }

    func testIgnoresIrregularShoppingIncomeAndTransfers() {
        var rows: [ChargeRow] = []
        // Groceries at the same store, similar amounts, but no regular gap.
        for (i, d) in [1, 3, 9, 10, 18, 26, 27, 40, 44, 59].enumerated() {
            rows.append(charge("FRESH BASKET MARKET #112", -60 - Double(i), cal.date(byAdding: .day, value: -d, to: today)!, category: "Groceries"))
        }
        for m in 5...10 {
            rows.append(charge("ACME PAYROLL", 2400, date(2026, m, 1), category: "Income"))
            rows.append(charge("CEDAR RIDGE HOME LOANS PMT", -1845, date(2026, m, 1), category: "Housing"))
            var t = charge("TRANSFER TO SAVINGS", -500, date(2026, m, 16), category: "Other"); t.isTransfer = true
            rows.append(t)
        }
        XCTAssertEqual(SubscriptionService.detect(rows, today: today, calendar: cal), [])
    }

    func testTwoMonthlyChargesAreNotEnough() {
        let rows = [charge("NEWAPP", -4.99, date(2026, 9, 3)), charge("NEWAPP", -4.99, date(2026, 10, 3))]
        XCTAssertTrue(SubscriptionService.detect(rows, today: today, calendar: cal).isEmpty)
    }

    func testSameMerchantDifferentPlansAreSeparate() {
        var rows = (5...10).map { charge("APPLE.COM/BILL", -2.99, date(2026, $0, 2)) }
        rows += (5...10).map { charge("APPLE.COM/BILL", -10.99, date(2026, $0, 20)) }
        let found = SubscriptionService.detect(rows, today: today, calendar: cal)
        XCTAssertEqual(found.map(\.amount).sorted(), [2.99, 10.99])
    }

    func testSameServiceOnTwoCardsIsTwoSubscriptionsGroupedByAccount() {
        var rows: [ChargeRow] = (5...10).map {
            ChargeRow(name: "STREAMFLIX", amount: -15.49, date: date(2026, $0, 7), category: "Entertainment", accountId: "VISA", accountName: "Visa")
        }
        rows += (5...10).map {
            ChargeRow(name: "STREAMFLIX", amount: -15.49, date: date(2026, $0, 9), category: "Entertainment", accountId: "MC", accountName: "Mastercard")
        }
        rows += (5...10).map {
            ChargeRow(name: "SKYLINE FIBER", amount: -69.99, date: date(2026, $0, 22), category: "Utilities", accountId: "CHK", accountName: "Checking")
        }
        let found = SubscriptionService.detect(rows, today: today, calendar: cal)
        XCTAssertEqual(found.filter { $0.merchantKey == "STREAMFLIX" }.map(\.accountId).sorted(), ["MC", "VISA"])
        let groups = SubscriptionService.byAccount(found)
        XCTAssertEqual(groups.map(\.accountName), ["Checking", "Mastercard", "Visa"])
        XCTAssertEqual(groups[0].totals.monthly, 69.99, accuracy: 0.001)
    }

    func testStoppedChargeIsFlaggedAndLeftOutOfTotals() {
        let rows = (5...8).map { charge("FITTRACK PREMIUM", -7.99, date(2026, $0, 4)) }
        let found = SubscriptionService.detect(rows, today: today, calendar: cal)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].mayHaveStopped)
        XCTAssertEqual(SubscriptionService.totals(found).monthly, 0)

        // Long gone: not shown at all.
        let old = (1...4).map { charge("OLDSERVICE", -5, date(2025, $0, 4)) }
        XCTAssertTrue(SubscriptionService.detect(old, today: today, calendar: cal).isEmpty)
    }

    func testDecisionsPersistAndSurviveAPriceRise() throws {
        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                             OFXProfile.self, CategoryRule.self, CustomCategory.self, SubscriptionMark.self, DismissedAlert.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let rows = (5...10).map { charge("STREAMFLIX", -15.49, date(2026, $0, 7)) }
        let s = SubscriptionService.detect(rows, today: today, calendar: cal)[0]

        SubscriptionService.set(.dismissed, for: s, in: context)
        var marks = try context.fetch(FetchDescriptor<SubscriptionMark>())
        XCTAssertEqual(SubscriptionService.detect(rows, marks: marks, today: today, calendar: cal)[0].status, .dismissed)
        XCTAssertEqual(SubscriptionService.totals(SubscriptionService.detect(rows, marks: marks, today: today, calendar: cal)).monthly, 0)

        // Changing your mind replaces the old choice rather than adding another.
        SubscriptionService.set(.confirmed, for: s, in: context)
        marks = try context.fetch(FetchDescriptor<SubscriptionMark>())
        XCTAssertEqual(marks.count, 1)

        // A small price rise keeps the choice.
        let raised = rows + [charge("STREAMFLIX", -16.99, date(2026, 11, 7))]
        XCTAssertEqual(SubscriptionService.detect(raised, marks: marks, today: today, calendar: cal)[0].status, .confirmed)

        // Choices go into backups and come back.
        let file = BackupService.snapshot(in: context)
        XCTAssertEqual(file.subscriptionMarks?.first?.statusRaw, "confirmed")
        BackupService.restore(file, in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SubscriptionMark>()).first?.status, .confirmed)

        SubscriptionService.set(.unreviewed, for: s, in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SubscriptionMark>()), 0)
    }

    func testOldBackupsWithoutDecisionsStillLoad() throws {
        let json = #"{"format":1,"createdAt":"2026-01-01T00:00:00Z","accounts":[],"transactions":[],"envelopes":[],"schedules":[],"profiles":[],"rules":[],"categories":[]}"#
        XCTAssertNil(try BackupService.decode(Data(json.utf8)).subscriptionMarks)
    }

    func testDemoHasSubscriptionsToShow() {
        let file = DemoData.make(today: today, calendar: cal)
        let rows = file.transactions.map {
            ChargeRow(id: $0.id, name: $0.name, amount: $0.amount, date: $0.date, category: $0.category,
                      accountId: $0.accountId, accountName: $0.accountName, isTransfer: $0.transferPeerId != nil)
        }
        let found = SubscriptionService.detect(rows, today: today, calendar: cal)
        let byKey = Dictionary(found.map { ($0.merchantKey, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byKey["STREAMFLIX"]?.cadence, .monthly)
        XCTAssertEqual(byKey["TUNEBOX MUSIC"]?.amount, 11.99)
        XCTAssertEqual(byKey["MORNING LEDGER"]?.cadence, .weekly)
        XCTAssertEqual(byKey["CLOUDNEST STORAGE"]?.cadence, .yearly)
        XCTAssertEqual(byKey["FITTRACK PREMIUM"]?.mayHaveStopped, true)
        XCTAssertNil(byKey["CEDAR RIDGE"], "the mortgage isn't a subscription")
        XCTAssertNil(byKey["FRESH BASKET"], "groceries aren't a subscription")
    }
}
