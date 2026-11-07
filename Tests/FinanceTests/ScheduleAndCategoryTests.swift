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

final class TransferTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func d(_ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: day))! }
    private func c(_ acct: String, _ amount: Double, _ date: Date) -> TransferDetector.Candidate {
        .init(id: UUID(), accountId: acct, amount: amount, date: date)
    }

    func testCardPaymentPairsWithCheckingDebit() {
        let out = c("checking", -500, d(11, 3)), inn = c("card", 500, d(11, 5))
        let other = c("checking", -500, d(11, 20))
        let pairs = TransferDetector.pairs([out, inn, other], calendar: cal)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.0, out.id)
        XCTAssertEqual(pairs.first?.1, inn.id)
    }

    func testNoPairWithinSameAccountTooFarApartOrDifferentAmount() {
        XCTAssertTrue(TransferDetector.pairs([c("a", -50, d(11, 3)), c("a", 50, d(11, 3))], calendar: cal).isEmpty)
        XCTAssertTrue(TransferDetector.pairs([c("a", -50, d(11, 3)), c("b", 50, d(11, 10))], calendar: cal).isEmpty)
        XCTAssertTrue(TransferDetector.pairs([c("a", -50, d(11, 3)), c("b", 51, d(11, 3))], calendar: cal).isEmpty)
    }

    func testDefaultWindowIsFiveDays() {
        XCTAssertEqual(TransferDetector.pairs([c("a", -75, d(11, 3)), c("b", 75, d(11, 8))], calendar: cal).count, 1)
        XCTAssertTrue(TransferDetector.pairs([c("a", -75, d(11, 3)), c("b", 75, d(11, 9))], calendar: cal).isEmpty)
    }

    func testEachTransactionUsedOnceClosestDateWins() {
        let out = c("a", -100, d(11, 5))
        let near = c("b", 100, d(11, 5)), far = c("b", 100, d(11, 7))
        let pairs = TransferDetector.pairs([out, far, near], calendar: cal)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.1, near.id)
    }

    func testTransfersAreExcludedFromReports() {
        let now = d(11, 7)
        let rows: [SpendingReport.Row] = [
            ("Transfer", -500, d(11, 3)), ("Transfer", 500, d(11, 3)),
            ("Dining", -20, d(11, 4)), ("Income", 1000, d(11, 1)),
        ]
        let t = SpendingReport.totals(rows, period: .thisMonth, now: now, calendar: cal)
        XCTAssertEqual(t.expenses, 20, accuracy: 0.001)
        XCTAssertEqual(t.income, 1000, accuracy: 0.001)
        XCTAssertEqual(SpendingReport.byCategory(rows, period: .thisMonth, now: now, calendar: cal).map(\.category), ["Dining"])
    }

    func testTransferKeywordsAndReservedName() {
        XCTAssertEqual(Categorizer.category(forName: "PAYMENT THANK YOU", rules: [:]), "Transfer")
        XCTAssertEqual(Categorizer.category(forName: "ONLINE TRANSFER TO SAV 1234", rules: [:]), "Transfer")
        XCTAssertNil(BudgetService.validatedNewCategory("transfer", existing: []))
    }
}

@MainActor
final class BudgetIncomeTests: XCTestCase {
    private func tx(_ account: String, _ amount: Double, _ category: String = "Uncategorized") -> TransactionRecord {
        TransactionRecord(fitid: UUID().uuidString, accountId: account, accountName: account, date: Date(),
                          name: "x", amount: amount, type: amount < 0 ? .debit : .credit, category: category)
    }

    func testIncomeCountsOnlyCheckingDepositsButSpendingCountsEverything() {
        let cal = Calendar.current
        let now = Date()
        let (y, m) = (cal.component(.year, from: now), cal.component(.month, from: now))
        let txs = [tx("checking", 3000), tx("card", 40), tx("savings", 5), tx("card", -60), tx("checking", -100),
                   tx("checking", 500, "Transfer"), tx("card", -500, "Transfer")]

        let all = BudgetService.summary(year: y, month: m, transactions: txs)
        XCTAssertEqual(all.income, 3045, accuracy: 0.001)

        let checkingOnly = BudgetService.summary(year: y, month: m, transactions: txs, incomeAccountIds: ["checking"])
        XCTAssertEqual(checkingOnly.income, 3000, accuracy: 0.001)
        XCTAssertEqual(checkingOnly.expenses, 160, accuracy: 0.001)   // card + checking spending, transfers excluded
    }
}

@MainActor
final class MonthOptionsTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func d(_ y: Int, _ m: Int, _ day: Int = 1) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day))! }

    func testDefaultRangeIsElevenMonthsBackToThreeAhead() {
        let o = BudgetService.monthOptions(earliest: nil, now: d(2026, 11, 7), selected: d(2026, 11), calendar: cal)
        XCTAssertEqual(o.count, 15)
        XCTAssertEqual(o.first, d(2027, 2))
        XCTAssertEqual(o.last, d(2025, 12))
    }

    func testReachesBackToFirstTransactionAndIncludesSelection() {
        let o = BudgetService.monthOptions(earliest: d(2025, 3, 14), now: d(2026, 11, 7), selected: d(2027, 8), calendar: cal)
        XCTAssertEqual(o.last, d(2025, 3))
        XCTAssertEqual(o.first, d(2027, 8))
        XCTAssertTrue(o.contains(d(2026, 11)))
    }
}

final class TransactionFiltersTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func d(_ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: day))! }

    func testBudgetSpentDrillDownMatchesTheCardTotals() {
        let f = TransactionFilters(month: d(11, 1), flow: .spending)
        func m(_ acct: String, _ cat: String, _ date: Date, _ amt: Double) -> Bool {
            f.matches(accountId: acct, category: cat, date: date, amount: amt, calendar: cal)
        }
        XCTAssertTrue(m("card", "Dining", d(11, 30), -20))
        XCTAssertFalse(m("card", "Dining", d(10, 31), -20))        // other month
        XCTAssertFalse(m("checking", "Income", d(11, 2), 100))      // money in
        XCTAssertFalse(m("checking", "Transfer", d(11, 2), -500))   // transfer
    }

    func testBudgetIncomeDrillDownLimitsToCheckingAccounts() {
        let f = TransactionFilters(accountIds: ["checking"], month: d(11, 1), flow: .income)
        func m(_ acct: String, _ cat: String, _ amt: Double) -> Bool {
            f.matches(accountId: acct, category: cat, date: d(11, 5), amount: amt, calendar: cal)
        }
        XCTAssertTrue(m("checking", "Uncategorized", 3000))
        XCTAssertFalse(m("card", "Uncategorized", 40))              // refund on the card
        XCTAssertFalse(m("checking", "Transfer", 500))
        XCTAssertFalse(m("checking", "Dining", -10))
    }

    func testMonthTakesPriorityOverPeriodAndDefaultsMatchEverything() {
        let f = TransactionFilters(period: .thisYear, month: d(3, 1))
        XCTAssertTrue(f.matches(accountId: "a", category: "x", date: d(3, 9), amount: -1, now: d(11, 7), calendar: cal))
        XCTAssertFalse(f.matches(accountId: "a", category: "x", date: d(4, 9), amount: -1, now: d(11, 7), calendar: cal))
        XCTAssertTrue(TransactionFilters().matches(accountId: "a", category: "x", date: d(1, 1), amount: 5, calendar: cal))
    }
}

final class AccountGroupingTests: XCTestCase {
    func testGroupsFollowDisplayOrderAndSkipEmptyTypes() {
        let items: [(name: String, type: AccountType)] = [
            ("Brokerage", .investment), ("Visa", .creditCard), ("Everyday", .checking),
            ("Home loan", .mortgage), ("Rainy day", .savings), ("Bills", .checking),
        ]
        let groups = AccountType.grouped(items, by: { $0.type })
        XCTAssertEqual(groups.map(\.type), [.checking, .savings, .creditCard, .mortgage, .investment])
        XCTAssertEqual(groups.first?.items.map(\.name), ["Everyday", "Bills"])   // incoming order kept
        XCTAssertTrue(AccountType.grouped([(String, AccountType)](), by: { $0.1 }).isEmpty)
    }
}

final class TransferCandidatesTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func d(_ day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day))! }
    private func c(_ acct: String, _ amt: Double, _ day: Int) -> TransferDetector.Candidate {
        .init(id: UUID(), accountId: acct, amount: amt, date: d(day))
    }

    func testRanksByAmountThenDateAndFiltersOthers() {
        let src = c("checking", -500, 10)
        let exact = c("card", 500, 14), withFee = c("card", 495, 11), sameSign = c("card", -500, 10)
        let sameAccount = c("checking", 500, 10), tooFar = c("card", 500, 25)
        let r = TransferDetector.candidates(for: src, among: [withFee, exact, sameSign, sameAccount, tooFar], calendar: cal)
        XCTAssertEqual(r, [exact.id, withFee.id])
    }
}

@MainActor
final class TransferLinkTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                             OFXProfile.self, CategoryRule.self, CustomCategory.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = ModelContext(container)
    }

    private func tx(_ acct: String, _ amount: Double, _ category: String = "Uncategorized", daysAgo: Int = 1) -> TransactionRecord {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let t = TransactionRecord(fitid: UUID().uuidString, accountId: acct, accountName: acct.capitalized, date: date,
                                  name: "x", amount: amount, type: amount < 0 ? .debit : .credit, category: category)
        context.insert(t); return t
    }

    func testFindTransfersLinksBothSides() {
        let out = tx("checking", -500), inn = tx("card", 500, daysAgo: 0), lunch = tx("checking", -12)
        let scan = CategorizationService.markTransfers(in: context)
        XCTAssertEqual(scan.linked, 1)
        XCTAssertEqual(out.transferPeerId, inn.id)
        XCTAssertEqual(inn.transferPeerId, out.id)
        XCTAssertEqual(out.category, "Transfer"); XCTAssertEqual(inn.category, "Transfer")
        XCTAssertNil(lunch.transferPeerId)
        // Running it again finds nothing new.
        XCTAssertEqual(CategorizationService.markTransfers(in: context).linked, 0)
    }

    func testManualLinkReplacesOldLinkAndUnlinkResetsBoth() {
        let out = tx("checking", -500), card = tx("card", 495), other = tx("savings", 500)
        TransferLinkService.link(out, card, in: context)
        XCTAssertEqual(card.transferPeerId, out.id)

        TransferLinkService.link(out, other, in: context)          // relink out -> savings
        XCTAssertEqual(out.transferPeerId, other.id)
        XCTAssertEqual(other.transferPeerId, out.id)
        XCTAssertNil(card.transferPeerId)                          // old partner released

        TransferLinkService.unlink(out, in: context)
        XCTAssertNil(out.transferPeerId); XCTAssertNil(other.transferPeerId)
        XCTAssertEqual(out.category, "Uncategorized"); XCTAssertEqual(other.category, "Uncategorized")
    }

    func testLinkRefusesSameAccount() {
        let a = tx("checking", -50), b = tx("checking", 50)
        TransferLinkService.link(a, b, in: context)
        XCTAssertNil(a.transferPeerId)
    }
}

final class CashCalendarTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; c.firstWeekday = 1; return c
    }()
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day))! }

    private let rent = ScheduleItem(name: "Rent", amount: -1200, dueDay: 1, category: "Housing")
    private let pay = ScheduleItem(name: "Paycheck", amount: 2000, dueDay: 15, category: "Income")

    func testGridCoversWholeWeeksAndPlacesEvents() {
        // Nov 2026 starts on a Sunday and has 30 days -> 5 rows.
        let days = CashCalendar.grid(month: d(2026, 11, 10), schedules: [rent, pay], balanceToday: 1000,
                                     today: d(2026, 11, 7), calendar: cal)
        XCTAssertEqual(days.count, 35)
        XCTAssertEqual(days.first?.date, d(2026, 11, 1))
        XCTAssertEqual(days.filter(\.inMonth).count, 30)
        XCTAssertEqual(days.first { cal.component(.day, from: $0.date) == 15 && $0.inMonth }?.events.map(\.name), ["Paycheck"])
    }

    func testRunningBalanceStartsToday() {
        let days = CashCalendar.grid(month: d(2026, 11, 10), schedules: [rent, pay], balanceToday: 1000,
                                     today: d(2026, 11, 7), calendar: cal)
        func closing(_ day: Int) -> Double? { days.first { $0.date == d(2026, 11, day) }?.closing }
        XCTAssertNil(closing(1))                 // past: no projection
        XCTAssertEqual(closing(7), 1000)         // nothing due today
        XCTAssertEqual(closing(15), 3000)        // payday
        XCTAssertEqual(closing(30), 3000)
    }

    func testBalanceCarriesAcrossMonths() {
        let days = CashCalendar.grid(month: d(2026, 12, 1), schedules: [rent, pay], balanceToday: 1000,
                                     today: d(2026, 11, 7), calendar: cal)
        func closing(_ day: Int) -> Double? { days.first { $0.date == d(2026, 12, day) }?.closing }
        // Nov 15 +2000 = 3000; Dec 1 -1200 = 1800; Dec 15 +2000 = 3800
        XCTAssertEqual(closing(1), 1800)
        XCTAssertEqual(closing(15), 3800)
    }

    func testSummaryAndPastMonth() {
        let days = CashCalendar.grid(month: d(2026, 12, 1), schedules: [rent, pay], balanceToday: 1000,
                                     today: d(2026, 11, 7), calendar: cal)
        let s = CashCalendar.summary(of: days, today: d(2026, 11, 7), calendar: cal)
        XCTAssertEqual(s.income, 2000); XCTAssertEqual(s.expenses, 1200)
        XCTAssertEqual(s.low, 1800); XCTAssertEqual(s.closing, 3800)

        let past = CashCalendar.grid(month: d(2026, 9, 1), schedules: [rent], balanceToday: 1000,
                                     today: d(2026, 11, 7), calendar: cal)
        XCTAssertNil(CashCalendar.summary(of: past, today: d(2026, 11, 7), calendar: cal).low)
    }

    func testDaysAreClampedTo28() {
        let late = ScheduleItem(name: "Late", amount: -10, dueDay: 31, category: "Other")
        XCTAssertEqual(CashCalendar.events(on: d(2026, 2, 28), schedules: [late], calendar: cal).count, 1)
        XCTAssertEqual(CashCalendar.events(on: d(2026, 1, 31), schedules: [late], calendar: cal).count, 0)
    }
}

@MainActor
final class BudgetSyncTests: XCTestCase {
    private var context: ModelContext!
    override func setUp() async throws {
        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                             OFXProfile.self, CategoryRule.self, CustomCategory.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = ModelContext(container)
    }

    func testTotalsPerCategory() {
        let items = [ScheduleItem(name: "A", amount: -100, dueDay: 1, category: "Housing"),
                     ScheduleItem(name: "B", amount: -50, dueDay: 2, category: "Housing"),
                     ScheduleItem(name: "Pay", amount: 900, dueDay: 3, category: "Income")]
        XCTAssertEqual(BudgetSync.scheduledExpenses(items), ["Housing": 150])
        XCTAssertEqual(BudgetSync.scheduledIncome(items), 900)
    }

    func testApplyCreatesRaisesAndNeverLowers() {
        let now = Date(); let cal = Calendar.current
        let y = cal.component(.year, from: now), m = cal.component(.month, from: now)
        context.insert(RecurringBill(name: "Rent", amount: 1200, dueDay: 1, category: "Housing"))
        context.insert(RecurringBill(name: "Water", amount: 80, dueDay: 5, category: "Utilities"))
        context.insert(RecurringBill(name: "Old", amount: 500, dueDay: 5, category: "Fun", isActive: false))
        context.insert(Envelope(category: "Utilities", year: y, month: m, allocated: 200))   // already bigger
        context.insert(Envelope(category: "Housing", year: y, month: m, allocated: 1000))    // too small
        XCTAssertEqual(BudgetSync.apply(in: context, now: now, calendar: cal), 1)
        let all = try! context.fetch(FetchDescriptor<Envelope>())
        func alloc(_ c: String) -> Double? { all.first { $0.category == c }?.allocated }
        XCTAssertEqual(alloc("Housing"), 1200)
        XCTAssertEqual(alloc("Utilities"), 200)
        XCTAssertNil(alloc("Fun"))                                                            // inactive ignored
        // Idempotent.
        XCTAssertEqual(BudgetSync.apply(in: context, now: now, calendar: cal), 0)
    }

    func testApplyCreatesMissingEnvelope() {
        context.insert(RecurringBill(name: "Gym", amount: 40, dueDay: 3, category: "Health"))
        XCTAssertEqual(BudgetSync.apply(in: context), 1)
        XCTAssertEqual(try! context.fetch(FetchDescriptor<Envelope>()).first?.allocated, 40)
    }
}

final class CashCalendarPastBalanceTests: XCTestCase {
    func testPastDaysWorkBackwardFromToday() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func d(_ day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day))! }
        // Balance is 1000 today (Nov 7). Spent 100 on Nov 6 and earned 500 on Nov 3.
        let days = CashCalendar.grid(month: d(7), schedules: [], balanceToday: 1000, today: d(7),
                                     actualNetByDay: [d(6): -100, d(3): 500], calendar: cal)
        func closing(_ day: Int) -> Double? { days.first { $0.date == d(day) }?.closing }
        XCTAssertEqual(closing(7), 1000)
        XCTAssertEqual(closing(6), 1000)   // end of Nov 6 = today's balance (nothing posted today)
        XCTAssertEqual(closing(5), 1100)   // before the -100
        XCTAssertEqual(closing(3), 1100)
        XCTAssertEqual(closing(2), 600)    // before the +500
        XCTAssertEqual(closing(1), 600)
    }
}
