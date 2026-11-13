import XCTest
import SwiftData
@testable import Finance

final class SavingsGoalTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d))! }
    private var today: Date { date(2026, 11, 12) }

    func testLinkedAccountPaceAndProjectedDate() {
        // $150 a month into the account for the last three months.
        let changes = [(date(2026, 8, 16), 150.0), (date(2026, 9, 16), 150.0), (date(2026, 10, 16), 150.0)]
        let p = SavingsGoalService.progress(target: 3000, targetDate: date(2027, 6, 15), createdAt: date(2026, 1, 1), balance: 1800,
                                            savedByHand: 0, contributions: [], accountChanges: changes, today: today, calendar: cal)
        XCTAssertEqual(p.fraction, 0.6, accuracy: 0.0001)
        XCTAssertEqual(p.monthlyPace!, 150, accuracy: 3)
        // $1,200 to go at ~$150 a month: about eight months, so July 2027.
        XCTAssertEqual(cal.component(.month, from: p.projectedDate!), 7)
        XCTAssertEqual(p.onTrack, false)
        XCTAssertEqual(p.neededPerMonth!, 1200 / 7.1, accuracy: 6)
        XCTAssertTrue(SavingsGoalService.summary(p).contains("a month to make June 2027"))
    }

    func testByHandGoalNeedsAMonthBeforeAPace() {
        let p = SavingsGoalService.progress(target: 1000, targetDate: nil, createdAt: date(2026, 11, 1), balance: nil, savedByHand: 300,
                                            contributions: [(date(2026, 11, 1), 300)], accountChanges: [], today: today, calendar: cal)
        XCTAssertEqual(p.saved, 300)
        XCTAssertNil(p.monthlyPace)
        XCTAssertNil(p.projectedDate)
        XCTAssertTrue(SavingsGoalService.summary(p).hasPrefix("Add to it for a month"))
    }

    func testReachedAndNotGrowing() {
        let reached = SavingsGoalService.progress(target: 500, targetDate: nil, createdAt: date(2026, 1, 1), balance: 620, savedByHand: 0,
                                                  contributions: [], accountChanges: [], today: today, calendar: cal)
        XCTAssertTrue(reached.isReached)
        XCTAssertEqual(reached.fraction, 1)
        let flat = SavingsGoalService.progress(target: 5000, targetDate: nil, createdAt: date(2026, 1, 1), balance: 1000, savedByHand: 0,
                                               contributions: [], accountChanges: [(date(2026, 10, 1), -50)], today: today, calendar: cal)
        XCTAssertNil(flat.projectedDate)
        XCTAssertEqual(SavingsGoalService.summary(flat), "Nothing added lately.")
    }

    func testContributionLogRoundTrips() {
        let list = [(date: date(2026, 9, 1), amount: 200.0), (date: date(2026, 10, 1), amount: -25.5)]
        let back = SavingsGoalService.parse(SavingsGoalService.serialize(list))
        XCTAssertEqual(back.map(\.amount), [200, -25.5])
        XCTAssertEqual(back.count, 2)
    }

    @MainActor
    func testDemoGoalsAndBackup() throws {
        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self, OFXProfile.self,
                             CategoryRule.self, CustomCategory.self, SubscriptionMark.self, SavingsGoal.self])
        let context = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
        BackupService.restore(DemoData.make(), in: context)
        let goals = try context.fetch(FetchDescriptor<SavingsGoal>(sortBy: [SortDescriptor(\.name)]))
        XCTAssertEqual(goals.map(\.name), ["Emergency fund", "New laptop", "Summer trip"])
        let accounts = try context.fetch(FetchDescriptor<Account>()), txs = try context.fetch(FetchDescriptor<TransactionRecord>())
        for g in goals {
            let p = SavingsGoalService.progress(g, accounts: accounts, transactions: txs)
            print("GOAL", g.name, p.saved, p.monthlyPace ?? -1, p.projectedDate as Any, SavingsGoalService.summary(p))
            XCTAssertGreaterThan(p.saved, 0)
            XCTAssertNotNil(p.projectedDate, "\(g.name) should have a projected date")
        }
        // Add money by hand and survive a backup.
        let laptop = goals[1]
        SavingsGoalService.add(100, to: laptop, in: context)
        XCTAssertEqual(laptop.savedByHand, 750)
        let file = BackupService.snapshot(in: context)
        BackupService.restore(file, in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SavingsGoal>()).first { $0.name == "New laptop" }?.savedByHand, 750)
    }
}
