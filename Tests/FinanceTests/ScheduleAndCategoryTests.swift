import XCTest
import SwiftData
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

    func testAllCategoriesSortsAndDeduplicates() {
        let all = BudgetService.allCategories(stored: ["Travel", "groceries", "Pets", "Groceries", "  "])
        XCTAssertEqual(all, ["groceries", "Pets", "Travel"])
    }

    func testValidatedNewCategory() {
        let existing = BudgetService.allCategories(stored: ["Travel"])
        XCTAssertEqual(BudgetService.validatedNewCategory("  Pets ", existing: existing), "Pets")
        XCTAssertNil(BudgetService.validatedNewCategory("travel", existing: existing))
        XCTAssertNil(BudgetService.validatedNewCategory("Income", existing: existing))
        XCTAssertNil(BudgetService.validatedNewCategory("   ", existing: existing))
    }

    func testValidatedRename() {
        let existing = ["Dining", "Groceries", "Travel"]
        XCTAssertEqual(BudgetService.validatedRename(" Restaurants ", from: "Dining", existing: existing), "Restaurants")
        XCTAssertEqual(BudgetService.validatedRename("TRAVEL", from: "Travel", existing: existing), "TRAVEL") // capitalization only
        XCTAssertNil(BudgetService.validatedRename("Dining", from: "Dining", existing: existing))          // unchanged
        XCTAssertNil(BudgetService.validatedRename("groceries", from: "Dining", existing: existing))       // taken
        XCTAssertNil(BudgetService.validatedRename("Income", from: "Dining", existing: existing))          // reserved
        XCTAssertNil(BudgetService.validatedRename("  ", from: "Dining", existing: existing))
    }

    func testBuiltInKeywordIgnoredWhenCategoryRemoved() {
        let allowedWithoutDining: Set<String> = ["groceries", "transport", "income"]
        XCTAssertNil(Categorizer.category(forName: "STARBUCKS #12", rules: [:], allowed: allowedWithoutDining))
        XCTAssertEqual(Categorizer.category(forName: "KROGER 551", rules: [:], allowed: allowedWithoutDining), "Groceries")
        // A learned rule still wins even if not in the built-in list.
        XCTAssertEqual(Categorizer.category(forName: "STARBUCKS #12", rules: ["STARBUCKS": "Coffee"], allowed: allowedWithoutDining), "Coffee")
    }
}

@MainActor
final class CategoryServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                             OFXProfile.self, CategoryRule.self, CustomCategory.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = ModelContext(container)
    }

    private func tx(_ name: String, _ category: String) -> TransactionRecord {
        let t = TransactionRecord(fitid: UUID().uuidString, accountId: "a", accountName: "A", date: Date(),
                                  name: name, amount: -10, type: .debit, category: category)
        context.insert(t); return t
    }

    func testRenameUpdatesEverythingThatUsesTheCategory() throws {
        let cat = CustomCategory(name: "Dinning"); context.insert(cat)
        let t = tx("Cafe", "Dinning")
        let other = tx("Rent", "Housing")
        let bill = RecurringBill(name: "Meal plan", amount: 50, dueDay: 5, category: "Dinning"); context.insert(bill)
        let env = Envelope(category: "Dinning", year: 2026, month: 11, allocated: 200); context.insert(env)
        let rule = CategoryRule(merchantKey: "CAFE", category: "Dinning"); context.insert(rule)

        CategoryService.rename(cat, to: "Dining", in: context)

        XCTAssertEqual(cat.name, "Dining")
        XCTAssertEqual(t.category, "Dining")
        XCTAssertEqual(bill.category, "Dining")
        XCTAssertEqual(env.category, "Dining")
        XCTAssertEqual(rule.category, "Dining")
        XCTAssertEqual(other.category, "Housing")
    }

    func testDeleteMovesTransactionsAndMergesEnvelopes() throws {
        let travel = CustomCategory(name: "Travel"); context.insert(travel)
        context.insert(CustomCategory(name: "Other"))
        let t = tx("Hotel", "Travel")
        let bill = RecurringBill(name: "Flight fund", amount: 100, dueDay: 1, category: "Travel"); context.insert(bill)
        let travelNov = Envelope(category: "Travel", year: 2026, month: 11, allocated: 300); context.insert(travelNov)
        let travelDec = Envelope(category: "Travel", year: 2026, month: 12, allocated: 100); context.insert(travelDec)
        let otherNov = Envelope(category: "Other", year: 2026, month: 11, allocated: 50); context.insert(otherNov)
        let rule = CategoryRule(merchantKey: "HOTEL", category: "Travel"); context.insert(rule)

        CategoryService.delete(travel, moveTo: "Other", in: context)

        XCTAssertEqual(t.category, "Other")
        XCTAssertEqual(bill.category, "Other")
        XCTAssertEqual(rule.category, "Other")
        XCTAssertEqual(otherNov.allocated, 350, accuracy: 0.001)   // merged into same month
        XCTAssertEqual(travelDec.category, "Other")                // no Other envelope in Dec: moved
        let names = try context.fetch(FetchDescriptor<CustomCategory>()).map(\.name)
        XCTAssertEqual(names, ["Other"])
    }

    func testDeleteToUncategorizedDropsEnvelopesAndRules() throws {
        let travel = CustomCategory(name: "Travel"); context.insert(travel)
        let t = tx("Hotel", "Travel")
        context.insert(Envelope(category: "Travel", year: 2026, month: 11, allocated: 300))
        context.insert(CategoryRule(merchantKey: "HOTEL", category: "Travel"))

        CategoryService.delete(travel, moveTo: nil, in: context)

        XCTAssertEqual(t.category, Categorizer.uncategorized)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Envelope>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CategoryRule>()).isEmpty)
    }

    func testSeedingRunsOnceAndAddsDefaults() throws {
        let suite = UserDefaults(suiteName: "finance.tests.\(UUID().uuidString)")!
        context.insert(CustomCategory(name: "dining")) // user already has one, different case
        CategoryService.seedIfNeeded(in: context, defaults: suite)
        let first = try context.fetch(FetchDescriptor<CustomCategory>())
        XCTAssertEqual(first.count, BudgetService.defaultCategories.count) // no duplicate Dining

        // Deleting one and re-running must not bring it back.
        context.delete(first.first { $0.name == "Debt" }!)
        try context.save()
        CategoryService.seedIfNeeded(in: context, defaults: suite)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CustomCategory>()).count, BudgetService.defaultCategories.count - 1)
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

final class DashboardReportTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day))! }
    private var now: Date { d(2026, 11, 7) }

    func testPeriodRanges() {
        func inP(_ p: DashboardPeriod, _ date: Date) -> Bool { p.contains(date, now: now, calendar: cal) }
        XCTAssertTrue(inP(.thisMonth, d(2026, 11, 1)));  XCTAssertFalse(inP(.thisMonth, d(2026, 10, 31)))
        XCTAssertFalse(inP(.thisMonth, d(2026, 12, 1)))
        XCTAssertTrue(inP(.lastMonth, d(2026, 10, 31))); XCTAssertFalse(inP(.lastMonth, d(2026, 11, 1)))
        XCTAssertTrue(inP(.last30Days, d(2026, 10, 9))); XCTAssertFalse(inP(.last30Days, d(2026, 10, 8)))
        XCTAssertTrue(inP(.last30Days, d(2026, 11, 7))); XCTAssertFalse(inP(.last30Days, d(2026, 11, 8)))
        XCTAssertTrue(inP(.thisYear, d(2026, 1, 1)));    XCTAssertFalse(inP(.thisYear, d(2025, 12, 31)))
        XCTAssertTrue(inP(.lastYear, d(2025, 12, 31)));  XCTAssertFalse(inP(.lastYear, d(2026, 1, 1)))
        XCTAssertTrue(inP(.allTime, d(1999, 1, 1)))
    }

    func testSpendingByCategoryTotalsAndSorts() {
        let rows: [SpendingReport.Row] = [
            ("Dining", -20, d(2026, 11, 2)), ("Dining", -30, d(2026, 11, 5)),
            ("Groceries", -80, d(2026, 11, 3)),
            ("Income", 1000, d(2026, 11, 1)),              // not spending
            ("Dining", -999, d(2026, 10, 15)),             // outside this month
        ]
        let r = SpendingReport.byCategory(rows, period: .thisMonth, now: now, calendar: cal)
        XCTAssertEqual(r, [CategorySpend(category: "Groceries", amount: 80, count: 1),
                           CategorySpend(category: "Dining", amount: 50, count: 2)])
        let t = SpendingReport.totals(rows, period: .thisMonth, now: now, calendar: cal)
        XCTAssertEqual(t.income, 1000, accuracy: 0.001)
        XCTAssertEqual(t.expenses, 130, accuracy: 0.001)
        XCTAssertEqual(SpendingReport.byCategory(rows, period: .allTime, now: now, calendar: cal).first?.category, "Dining")
    }
}
