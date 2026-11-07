import XCTest
@testable import Finance

final class ScheduleAndCategoryTests: XCTestCase {
    private let cal = Calendar.current
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d))! }

    func testDraftFromExpenseTransaction() {
        let d = ScheduleService.draft(fromName: "NETFLIX INC 866-579-7172", amount: -15.49, date: date(2026, 10, 12), category: "Entertainment")
        XCTAssertFalse(d.isIncome)
        XCTAssertEqual(d.amount, 15.49, accuracy: 0.001)
        XCTAssertEqual(d.dueDay, 12)
        XCTAssertEqual(d.category, "Entertainment")
        XCTAssertEqual(d.name, "Netflix Inc")
    }

    func testDraftFromIncomeClampsDayAndUsesIncomeCategory() {
        let d = ScheduleService.draft(fromName: "ACME PAYROLL", amount: 2500, date: date(2026, 10, 31), category: "Uncategorized")
        XCTAssertTrue(d.isIncome)
        XCTAssertEqual(d.dueDay, 28)
        XCTAssertEqual(d.category, "Income")
    }

    func testDraftUncategorizedExpenseFallsBackToOther() {
        let d = ScheduleService.draft(fromName: "Joe's Gym", amount: -40, date: date(2026, 10, 3), category: "Uncategorized")
        XCTAssertEqual(d.category, "Other")
    }

    func testNextDueDate() {
        XCTAssertEqual(ScheduleService.nextDueDate(dueDay: 15, from: date(2026, 11, 7)), date(2026, 11, 15))
        XCTAssertEqual(ScheduleService.nextDueDate(dueDay: 7, from: date(2026, 11, 7)), date(2026, 11, 7))
        XCTAssertEqual(ScheduleService.nextDueDate(dueDay: 1, from: date(2026, 12, 20)), date(2027, 1, 1))
    }

    func testAllCategoriesMergesCustomWithoutDuplicates() {
        let all = BudgetService.allCategories(custom: ["Travel", "groceries", "Pets", "  "])
        XCTAssertEqual(Array(all.prefix(BudgetService.defaultCategories.count)), BudgetService.defaultCategories)
        XCTAssertEqual(Array(all.suffix(2)), ["Pets", "Travel"])
        XCTAssertFalse(all.contains("groceries"))
    }

    func testValidatedNewCategory() {
        let existing = BudgetService.allCategories(custom: ["Travel"])
        XCTAssertEqual(BudgetService.validatedNewCategory("  Pets ", existing: existing), "Pets")
        XCTAssertNil(BudgetService.validatedNewCategory("travel", existing: existing))
        XCTAssertNil(BudgetService.validatedNewCategory("Income", existing: existing))
        XCTAssertNil(BudgetService.validatedNewCategory("   ", existing: existing))
    }
}

final class RunningBalanceTests: XCTestCase {
    func testBalancesWalkBackFromEndingBalance() {
        let a = UUID(), b = UUID(), c = UUID()
        // Newest first: +100 paycheck, -30 groceries, -20 coffee. Ends at 500.
        let r = RunningBalance.compute(newestFirst: [(a, 100), (b, -30), (c, -20)], endingBalance: 500)
        XCTAssertEqual(r[a]!, 500, accuracy: 0.001)
        XCTAssertEqual(r[b]!, 400, accuracy: 0.001)   // before the paycheck
        XCTAssertEqual(r[c]!, 430, accuracy: 0.001)   // before groceries
    }

    func testEmptyList() {
        XCTAssertTrue(RunningBalance.compute(newestFirst: [], endingBalance: 10).isEmpty)
    }
}
