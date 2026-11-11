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
        XCTAssertEqual(s.lowDate, d(2026, 12, 1))

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

final class ScheduledTransferTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func d(_ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: day))! }
    private let cardPayment = ScheduleItem(name: "Visa payment", amount: 400, dueDay: 10, category: "Transfer",
                                           isTransfer: true, fromAccountId: "chk", toAccountId: "visa", detail: "Checking → Visa")

    func testTransferOutOfTrackedAccountReducesBalance() {
        XCTAssertEqual(CashCalendar.balanceEffect(of: cardPayment, cashAccountIds: ["chk", "sav"]), -400)
    }
    func testTransferBetweenTrackedAccountsIsNeutral() {
        XCTAssertEqual(CashCalendar.balanceEffect(of: cardPayment, cashAccountIds: ["chk", "visa"]), 0)
    }
    func testTransferIntoTrackedAccountAddsBalance() {
        let sweep = ScheduleItem(name: "Sweep", amount: 100, dueDay: 1, category: "Transfer",
                                 isTransfer: true, fromAccountId: "other", toAccountId: "chk")
        XCTAssertEqual(CashCalendar.balanceEffect(of: sweep, cashAccountIds: ["chk"]), 100)
    }

    func testCalendarShowsTransferButItIsNotIncomeOrSpending() {
        let days = CashCalendar.grid(month: d(11, 1), schedules: [cardPayment], balanceToday: 1000, today: d(11, 7),
                                     cashAccountIds: ["chk"], calendar: cal)
        let day = days.first { $0.date == d(11, 10) }!
        XCTAssertEqual(day.events.count, 1)
        XCTAssertEqual(day.events[0].gross, 400)
        XCTAssertEqual(day.closing, 600)
        let s = CashCalendar.summary(of: days, today: d(11, 7), calendar: cal)
        XCTAssertEqual(s.income, 0); XCTAssertEqual(s.expenses, 0)
        XCTAssertEqual(s.closing, 600)
    }

    func testBudgetIgnoresTransfers() {
        XCTAssertTrue(BudgetSync.scheduledExpenses([cardPayment]).isEmpty)
        XCTAssertEqual(BudgetSync.scheduledIncome([cardPayment]), 0)
    }

    func testDraftFromLinkedTransferPrefillsAccounts() {
        let draft = ScheduleService.draft(fromName: "VISA PAYMENT", amount: -400, date: d(11, 10), category: "Transfer",
                                          transferFrom: "chk", transferTo: "visa", calendar: cal)
        XCTAssertTrue(draft.isTransfer)
        XCTAssertEqual(draft.fromAccountId, "chk"); XCTAssertEqual(draft.toAccountId, "visa")
        XCTAssertEqual(draft.amount, 400); XCTAssertEqual(draft.category, "Transfer"); XCTAssertEqual(draft.dueDay, 10)
    }

    func testForecastIgnoresTransferSchedules() {
        let bill = RecurringBill(name: "Visa payment", amount: 400, dueDay: 10, category: "Transfer")
        bill.kindRaw = "transfer"; bill.fromAccountId = "chk"; bill.toAccountId = "visa"
        XCTAssertTrue(bill.isTransfer); XCTAssertFalse(bill.isExpense); XCTAssertFalse(bill.isIncome)
        XCTAssertEqual(bill.item(accountNames: ["chk": "Checking", "visa": "Visa"]).detail, "Checking → Visa")
        let months = CashFlowForecastService.forecast(bills: [bill], envelopes: [], transactions: [],
            options: ForecastOptions(months: 2, includeEnvelopes: false, fallbackAverageVariable: false,
                                     inferIncomeFromHistory: false, startingBalance: 1000))
        XCTAssertEqual(months.last?.closingBalance, 1000)
    }
}

@MainActor
final class DedupeServiceTests: XCTestCase {
    private var context: ModelContext!
    override func setUp() async throws {
        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                             OFXProfile.self, CategoryRule.self, CustomCategory.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = ModelContext(container)
    }
    private func count<T: PersistentModel>(_ t: T.Type) -> Int { (try? context.fetch(FetchDescriptor<T>()).count) ?? -1 }

    func testMergesDuplicatesAndKeepsTransferLinks() {
        func tx(_ fit: String, _ acct: String, _ amount: Double) -> TransactionRecord {
            let t = TransactionRecord(fitid: fit, accountId: acct, accountName: acct, date: Date(), name: "x", amount: amount, type: .debit)
            context.insert(t); return t
        }
        let a1 = tx("F1", "chk", -50), a2 = tx("F1", "chk", -50)      // same import on two devices
        let peer = tx("F2", "visa", 50)
        a2.transferPeerId = peer.id; peer.transferPeerId = a2.id        // link was made against the duplicate
        context.insert(Account(name: "Checking", type: .checking, accountId: "chk", bankName: "B"))
        context.insert(Account(name: "Checking", type: .checking, accountId: "chk", bankName: "B"))
        context.insert(CategoryRule(merchantKey: "shell", category: "Auto"))
        context.insert(CategoryRule(merchantKey: "shell", category: "Auto"))
        context.insert(CustomCategory(name: "Pets")); context.insert(CustomCategory(name: "Pets"))
        context.insert(Envelope(category: "Food", year: 2026, month: 11, allocated: 300))
        context.insert(Envelope(category: "Food", year: 2026, month: 11, allocated: 500))

        XCTAssertEqual(DedupeService.run(in: context), 5)
        XCTAssertEqual(count(TransactionRecord.self), 2)
        XCTAssertEqual(count(Account.self), 1); XCTAssertEqual(count(CategoryRule.self), 1)
        XCTAssertEqual(count(CustomCategory.self), 1)
        XCTAssertEqual(try! context.fetch(FetchDescriptor<Envelope>()).first?.allocated, 500)

        let kept = try! context.fetch(FetchDescriptor<TransactionRecord>()).first { $0.fitid == "F1" }!
        let peerNow = try! context.fetch(FetchDescriptor<TransactionRecord>()).first { $0.fitid == "F2" }!
        XCTAssertEqual(kept.transferPeerId, peerNow.id)
        XCTAssertEqual(peerNow.transferPeerId, kept.id)
        _ = a1
        XCTAssertEqual(DedupeService.run(in: context), 0)              // idempotent
    }
}

@MainActor
final class ManualTransactionTests: XCTestCase {
    private var context: ModelContext!
    override func setUp() async throws {
        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                             OFXProfile.self, CategoryRule.self, CustomCategory.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = ModelContext(container)
    }

    func testAddMovesBalanceAndDeleteUndoesIt() {
        let acct = Account(name: "Checking", type: .checking, accountId: "chk", bankName: "B", balance: 100)
        context.insert(acct)
        let tx = ManualTransactionService.add(to: acct, date: Date(), name: "Coffee", amount: -4.5, category: "Dining", in: context)
        XCTAssertEqual(acct.balance, 95.5)
        XCTAssertTrue(ManualTransactionService.isManual(tx))
        XCTAssertEqual(tx.category, "Dining")
        XCTAssertTrue(ManualTransactionService.delete(tx, from: [acct], in: context))
        XCTAssertEqual(acct.balance, 100)
        XCTAssertEqual(try! context.fetch(FetchDescriptor<TransactionRecord>()).count, 0)
    }

    func testImportReplacesMatchingManualEntryKeepingCategory() {
        let acct = Account(name: "Checking", type: .checking, accountId: "chk", bankName: "B", balance: 100)
        context.insert(acct)
        let manual = ManualTransactionService.add(to: acct, date: Date(), name: "Lunch", amount: -12, category: "Dining", in: context)
        let other = ManualTransactionService.add(to: acct, date: Date(), name: "Gas", amount: -40, category: "Transport", in: context)
        let parsed = ParsedOFXFile(bankId: "B", accountId: "chk", accountName: "Checking", balance: 48,
            transactions: [OFXTransaction(fitid: "BANK1", accountId: "chk", date: Date(), name: "SQ *CAFE 123", amount: -12, type: .debit, memo: "")])
        let r = TransactionImportService().importParsed(parsed, into: context)
        XCTAssertEqual(r.inserted, 1)
        let all = try! context.fetch(FetchDescriptor<TransactionRecord>())
        XCTAssertEqual(all.count, 2)                                    // lunch replaced, gas kept
        XCTAssertFalse(all.contains { $0.id == manual.id })
        XCTAssertTrue(all.contains { $0.id == other.id })
        XCTAssertEqual(all.first { $0.fitid == "BANK1" }?.category, "Dining")
        XCTAssertEqual(acct.balance, 8)                                 // statement's 48, less the gas the bank hasn't reported yet
    }

    func testBankBalanceKeepsUnreportedManualEntriesWithoutDoubleCounting() {
        let acct = Account(name: "Checking", type: .checking, accountId: "chk", bankName: "B", balance: 1000)
        context.insert(acct)
        ManualTransactionService.add(to: acct, date: Date(), name: "Rent", amount: -600, in: context)
        XCTAssertEqual(acct.balance, 400)
        // Bank sync before the bank has the $600: its balance is still 1000.
        let before = ParsedOFXFile(bankId: "B", accountId: "chk", accountName: "Checking", balance: 1000, transactions: [])
        _ = TransactionImportService().importParsed(before, into: context)
        XCTAssertEqual(acct.balance, 400)
        // Bank posts it: its balance drops to 400 and the hand-entered one is replaced, not added again.
        let after = ParsedOFXFile(bankId: "B", accountId: "chk", accountName: "Checking", balance: 400,
            transactions: [OFXTransaction(fitid: "R1", accountId: "chk", date: Date(), name: "RENT", amount: -600, type: .debit, memo: "")])
        _ = TransactionImportService().importParsed(after, into: context)
        XCTAssertEqual(acct.balance, 400)
        XCTAssertTrue(ManualTransactionService.unreported(in: "chk", from: try! context.fetch(FetchDescriptor<TransactionRecord>())).isEmpty)
    }

    func testMatchWindowAndAmount() {
        let acct = Account(name: "C", type: .checking, accountId: "c", bankName: "B")
        context.insert(acct)
        let m = ManualTransactionService.add(to: acct, date: Date(), name: "x", amount: -10, in: context)
        let farOff = Calendar.current.date(byAdding: .day, value: 9, to: Date())!
        XCTAssertFalse(ManualTransactionService.matches(m, amount: -10, date: farOff))
        XCTAssertFalse(ManualTransactionService.matches(m, amount: -11, date: Date()))
        XCTAssertTrue(ManualTransactionService.matches(m, amount: -10, date: Date()))
    }
}

@MainActor
final class ScheduleOrderingTests: XCTestCase {
    func testNextDueFirstThenRollOverThenPaused() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 12))!
        func bill(_ name: String, _ day: Int, active: Bool = true) -> RecurringBill {
            RecurringBill(name: name, amount: 10, dueDay: day, category: "Other", isActive: active)
        }
        let ordered = ScheduleService.orderedByNextDue(
            [bill("Rent", 1), bill("Phone", 20), bill("Gym", 12), bill("Old", 5, active: false), bill("Water", 15)],
            from: today, calendar: cal)
        // Today (12) first, then 15, 20, then Rent (1st, rolls to Dec 1), then paused.
        XCTAssertEqual(ordered.map(\.name), ["Gym", "Water", "Phone", "Rent", "Old"])
    }
}

final class ScheduleRuleTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func d(_ m: Int, _ day: Int, _ y: Int = 2026) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day))! }

    func testMonthlyAndTwiceMonthly() {
        let monthly = ScheduleRule(frequency: .monthly, dueDay: 31)           // clamps to 28
        XCTAssertTrue(monthly.occurs(on: d(2, 28), calendar: cal)); XCTAssertFalse(monthly.occurs(on: d(1, 31), calendar: cal))
        let twice = ScheduleRule(frequency: .semimonthly, dueDay: 1, secondDay: 15)
        XCTAssertEqual(twice.dates(from: d(11, 1), to: d(11, 30), calendar: cal), [d(11, 1), d(11, 15)])
        XCTAssertEqual(twice.summary(calendar: cal), "1st & 15th of the month")
    }

    func testWeeklyFromAnchor() {
        let friday = d(11, 6)                                                  // Nov 6 2026 is a Friday
        let weekly = ScheduleRule(frequency: .weekly, anchor: friday)
        XCTAssertEqual(weekly.dates(from: d(11, 1), to: d(11, 30), calendar: cal), [d(11, 6), d(11, 13), d(11, 20), d(11, 27)])
        XCTAssertTrue(weekly.occurs(on: d(10, 30), calendar: cal))             // before the anchor too
        XCTAssertEqual(weekly.summary(calendar: cal), "Every Friday")
        XCTAssertEqual(weekly.nextDate(from: d(11, 7), calendar: cal), d(11, 13))
    }

    func testBiweeklyAlternates() {
        let r = ScheduleRule(frequency: .biweekly, anchor: d(11, 6))
        XCTAssertEqual(r.dates(from: d(11, 1), to: d(12, 31), calendar: cal),
                       [d(11, 6), d(11, 20), d(12, 4), d(12, 18)])
        XCTAssertEqual(r.dates(from: d(10, 1), to: d(10, 31), calendar: cal), [d(10, 9), d(10, 23)])
        XCTAssertEqual(r.summary(calendar: cal), "Every other Friday")
    }

    func testMonthlyFactorsAndBudget() {
        XCTAssertEqual(ScheduleRule(frequency: .semimonthly).monthlyFactor, 2)
        XCTAssertEqual(ScheduleRule(frequency: .weekly).monthlyFactor, 52.0 / 12.0, accuracy: 0.0001)
        let weeklyGroceries = ScheduleItem(name: "Groceries", amount: -120, dueDay: 1, category: "Groceries",
                                           frequency: .weekly, anchor: d(11, 6))
        let semiPay = ScheduleItem(name: "Pay", amount: 1500, dueDay: 1, category: "Income", frequency: .semimonthly)
        XCTAssertEqual(BudgetSync.scheduledExpenses([weeklyGroceries])["Groceries"]!, 120 * 52.0 / 12.0, accuracy: 0.01)
        XCTAssertEqual(BudgetSync.scheduledIncome([semiPay]), 3000)
    }

    func testCalendarShowsWeeklyItems() {
        let weekly = ScheduleItem(name: "Pay", amount: 500, dueDay: 1, category: "Income", frequency: .weekly, anchor: d(11, 6))
        let days = CashCalendar.grid(month: d(11, 1), schedules: [weekly], balanceToday: 0, today: d(11, 1), calendar: cal)
        XCTAssertEqual(days.filter { $0.inMonth && !$0.events.isEmpty }.map { cal.component(.day, from: $0.date) }, [6, 13, 20, 27])
        XCTAssertEqual(days.last { $0.inMonth }?.closing, 2000)
    }

    func testForecastCountsEveryPaydayInTheMonth() {
        // Local calendar, like the forecast itself.
        let local = Calendar.current
        let nov1 = local.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let anchor = local.date(from: DateComponents(year: 2026, month: 11, day: 6))!
        let months = CashFlowForecastService.forecastPlain(
            bills: [(name: "Pay", amount: 100, dueDay: 1, category: "Income", isIncome: true)],
            envelopes: [], transactions: [],
            options: ForecastOptions(months: 1, includeEnvelopes: false, fallbackAverageVariable: false,
                                     inferIncomeFromHistory: false, startingBalance: 0, from: nov1),
            rules: [ScheduleRule(frequency: .weekly, anchor: anchor)])
        XCTAssertEqual(months.first?.scheduledIncome, 400)
        XCTAssertEqual(months.first?.events.count, 4)
    }
}

@MainActor
final class SchedulePersistenceTests: XCTestCase {
    func testSaveStoresFrequencyAndNextDateUsesIt() throws {
        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                             OFXProfile.self, CategoryRule.self, CustomCategory.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let anchor = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        var draft = ScheduleDraft(name: "Paycheck", amount: 1000, dueDay: 1, category: "Income", isIncome: true)
        draft.frequency = .biweekly; draft.startDate = anchor
        ScheduleService.save(draft, existing: nil, in: context)
        let bill = try XCTUnwrap(try context.fetch(FetchDescriptor<RecurringBill>()).first)
        XCTAssertEqual(bill.frequencyRaw, "biweekly")
        XCTAssertEqual(bill.rule.frequency, .biweekly)
        let next = try XCTUnwrap(bill.rule.nextDate(from: Date()))
        XCTAssertEqual(Calendar.current.dateComponents([.day], from: anchor, to: next).day! % 14, 0)
        XCTAssertEqual(bill.monthlySize, 1000 * 26.0 / 12.0, accuracy: 0.01)
    }
}

@MainActor
final class ScheduleEntryTests: XCTestCase {
    private var context: ModelContext!
    override func setUp() async throws {
        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                             OFXProfile.self, CategoryRule.self, CustomCategory.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = ModelContext(container)
    }
    private func all<T: PersistentModel>(_ t: T.Type) -> [T] { (try? context.fetch(FetchDescriptor<T>())) ?? [] }

    func testOccurrenceLogRoundTripAndExcludedDates() {
        let cal = Calendar.current
        let d = cal.date(from: DateComponents(year: 2026, month: 11, day: 15))!
        let bill = RecurringBill(name: "Rent", amount: 1200, dueDay: 15, category: "Housing")
        bill.record(.skipped, on: d, now: d)
        XCTAssertEqual(bill.occurrenceLogRaw, "2026-11-15|s")
        XCTAssertEqual(bill.occurrenceLog["2026-11-15"], .skipped)
        XCTAssertFalse(bill.rule.occurs(on: d))                                   // skipped day no longer projected
        XCTAssertEqual(bill.rule.nextDate(from: d), cal.date(from: DateComponents(year: 2026, month: 12, day: 15)))
    }

    func testEnterPostsEditedTransactionAndMovesToNextPayment() throws {
        let acct = Account(name: "Checking", type: .checking, accountId: "chk", bankName: "B", balance: 2000)
        context.insert(acct)
        let bill = RecurringBill(name: "Electric", amount: 100, dueDay: 15, category: "Utilities")
        context.insert(bill)
        let due = try XCTUnwrap(bill.rule.nextDate(from: Date()))
        let paidOn = Calendar.current.date(byAdding: .day, value: 2, to: due)!
        XCTAssertTrue(ScheduleService.enter(bill, occurrence: due, postedOn: paidOn, amount: 117.25, account: acct, in: context))
        let tx = try XCTUnwrap(all(TransactionRecord.self).first)
        XCTAssertEqual(tx.amount, -117.25); XCTAssertEqual(tx.category, "Utilities"); XCTAssertEqual(tx.date, paidOn)
        XCTAssertEqual(acct.balance, 2000 - 117.25, accuracy: 0.001)
        XCTAssertEqual(bill.accountId, "chk"); XCTAssertEqual(bill.lastPaid, paidOn)
        let next = try XCTUnwrap(bill.rule.nextDate(from: Date()))
        XCTAssertGreaterThan(next, due)                                           // that occurrence is done
    }

    func testSkipCreatesNoTransaction() throws {
        let bill = RecurringBill(name: "Gym", amount: 40, dueDay: 3, category: "Health")
        context.insert(bill)
        let due = try XCTUnwrap(bill.rule.nextDate(from: Date()))
        ScheduleService.skip(bill, occurrence: due, in: context)
        XCTAssertTrue(all(TransactionRecord.self).isEmpty)
        XCTAssertNotEqual(bill.rule.nextDate(from: Date()), due)
    }

    func testEnteringIncomeAndTransfer() throws {
        let chk = Account(name: "Checking", type: .checking, accountId: "chk", bankName: "B", balance: 1000)
        let visa = Account(name: "Visa", type: .creditCard, accountId: "visa", bankName: "B", balance: -400)
        context.insert(chk); context.insert(visa)
        let pay = RecurringBill(name: "Paycheck", amount: 1500, dueDay: 1, category: "Income", isIncome: true)
        let payment = RecurringBill(name: "Visa payment", amount: 400, dueDay: 10, category: "Transfer")
        payment.kindRaw = "transfer"
        context.insert(pay); context.insert(payment)

        XCTAssertTrue(ScheduleService.enter(pay, occurrence: try XCTUnwrap(pay.rule.nextDate(from: Date())),
                                            postedOn: Date(), amount: 1500, account: chk, in: context))
        XCTAssertEqual(chk.balance, 2500)

        XCTAssertFalse(ScheduleService.enter(payment, occurrence: Date(), postedOn: Date(), amount: 400,
                                             account: nil, from: chk, to: chk, in: context))   // same account refused
        XCTAssertTrue(ScheduleService.enter(payment, occurrence: try XCTUnwrap(payment.rule.nextDate(from: Date())),
                                            postedOn: Date(), amount: 400, account: nil, from: chk, to: visa, in: context))
        XCTAssertEqual(chk.balance, 2100); XCTAssertEqual(visa.balance, 0)
        let txs = all(TransactionRecord.self).filter { $0.name == "Visa payment" }
        XCTAssertEqual(txs.count, 2)
        XCTAssertEqual(txs[0].transferPeerId, txs[1].id); XCTAssertEqual(txs[1].transferPeerId, txs[0].id)
        XCTAssertTrue(txs.allSatisfy { $0.category == "Transfer" })
    }

    func testCalendarAndItemsHonorEnteredDays() throws {
        let bill = RecurringBill(name: "Rent", amount: 1000, dueDay: 15, category: "Housing")
        let cal = Calendar.current
        let day = cal.date(from: DateComponents(year: 2026, month: 11, day: 15))!
        bill.record(.entered, on: day, now: day)
        let events = CashCalendar.events(on: day, schedules: [bill.item])
        XCTAssertTrue(events.isEmpty)
    }
}

@MainActor
final class OverdueTests: XCTestCase {
    private var context: ModelContext!
    private var cal: Calendar { Calendar.current }
    override func setUp() async throws {
        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                             OFXProfile.self, CategoryRule.self, CustomCategory.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = ModelContext(container)
    }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d))! }

    func testOverdueListsMissedPaymentsSinceTracking() {
        let today = day(2026, 11, 20)
        let weekly = RecurringBill(name: "Groceries", amount: 100, dueDay: 1, category: "Groceries")
        weekly.frequencyRaw = "weekly"; weekly.anchorDate = day(2026, 11, 6)       // Fridays: 6, 13, 20
        weekly.trackedSince = day(2026, 11, 1)
        let rent = RecurringBill(name: "Rent", amount: 1200, dueDay: 1, category: "Housing")
        rent.trackedSince = day(2026, 11, 10)                                        // Nov 1 is before tracking
        let untracked = RecurringBill(name: "New", amount: 5, dueDay: 2, category: "Other")
        let paused = RecurringBill(name: "Old", amount: 5, dueDay: 2, category: "Other", isActive: false)
        paused.trackedSince = day(2026, 11, 1)

        let items = ScheduleService.overdue([weekly, rent, untracked, paused], today: today, calendar: cal)
        XCTAssertEqual(items.map { "\($0.bill.name) \(cal.component(.day, from: $0.date))" }, ["Groceries 6", "Groceries 13"])  // 20 is today, not overdue
        XCTAssertEqual(items[0].daysLate(today: today, calendar: cal), 14)

        weekly.record(.skipped, on: day(2026, 11, 6))
        XCTAssertEqual(ScheduleService.overdue([weekly], today: today, calendar: cal).count, 1)
    }

    func testEnsureTrackingOnlySetsMissingStart() {
        let a = RecurringBill(name: "A", amount: 1, dueDay: 1, category: "x")
        let b = RecurringBill(name: "B", amount: 1, dueDay: 1, category: "x")
        let earlier = day(2026, 1, 1)
        b.trackedSince = earlier
        context.insert(a); context.insert(b)
        ScheduleService.ensureTracking(in: context, now: day(2026, 11, 7), calendar: cal)
        XCTAssertEqual(a.trackedSince, day(2026, 11, 7)); XCTAssertEqual(b.trackedSince, earlier)
    }

    func testImportMarksMatchingOverduePaymentEntered() {
        let today = Date()
        var due = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: today))!
        while cal.component(.day, from: due) > 28 { due = cal.date(byAdding: .day, value: -1, to: due)! }   // schedules cap at the 28th
        let bill = RecurringBill(name: "Electric", amount: 100, dueDay: cal.component(.day, from: due), category: "Utilities")
        bill.trackedSince = cal.date(byAdding: .day, value: -10, to: due)!
        context.insert(bill)
        let bank = TransactionRecord(fitid: "F1", accountId: "chk", accountName: "C", date: due, name: "POWER CO", amount: -108, type: .debit)
        let unrelated = TransactionRecord(fitid: "F2", accountId: "chk", accountName: "C", date: due, name: "COFFEE", amount: -4, type: .debit)
        let farAway = TransactionRecord(fitid: "F3", accountId: "chk", accountName: "C",
                                        date: cal.date(byAdding: .day, value: -30, to: due)!, name: "POWER CO", amount: -100, type: .debit)
        XCTAssertEqual(ScheduleService.autoResolve(with: [unrelated, farAway], in: context, today: today, calendar: cal), 0)
        XCTAssertEqual(ScheduleService.overdue([bill], today: today, calendar: cal).count, 1)
        XCTAssertEqual(ScheduleService.autoResolve(with: [bank, unrelated], in: context, today: today, calendar: cal), 1)
        XCTAssertTrue(ScheduleService.overdue([bill], today: today, calendar: cal).isEmpty)
    }

    func testNewSchedulesStartTrackingToday() throws {
        var draft = ScheduleDraft(name: "Gym", amount: 40, dueDay: 3, category: "Health", isIncome: false)
        draft.frequency = .monthly
        ScheduleService.save(draft, existing: nil, in: context)
        let bill = try XCTUnwrap(try context.fetch(FetchDescriptor<RecurringBill>()).first)
        XCTAssertEqual(bill.trackedSince, cal.startOfDay(for: Date()))
        XCTAssertTrue(ScheduleService.overdue([bill]).isEmpty)
    }
}

@MainActor
final class ScheduleAccountTests: XCTestCase {
    func testBillOnUntrackedAccountDoesNotMoveCashBalance() {
        let onCard = ScheduleItem(name: "Netflix", amount: -15, dueDay: 5, category: "Entertainment", accountId: "visa")
        let onChecking = ScheduleItem(name: "Rent", amount: -1000, dueDay: 5, category: "Housing", accountId: "chk")
        let unassigned = ScheduleItem(name: "Misc", amount: -20, dueDay: 5, category: "Other")
        let cash: Set<String> = ["chk", "sav"]
        XCTAssertEqual(CashCalendar.balanceEffect(of: onCard, cashAccountIds: cash), 0)
        XCTAssertEqual(CashCalendar.balanceEffect(of: onChecking, cashAccountIds: cash), -1000)
        XCTAssertEqual(CashCalendar.balanceEffect(of: unassigned, cashAccountIds: cash), -20)       // no account: counts, as before
        XCTAssertEqual(CashCalendar.balanceEffect(of: onCard, cashAccountIds: cash.union(["visa"])), -15)
        XCTAssertEqual(CashCalendar.balanceEffect(of: onCard, cashAccountIds: nil), -15)
    }

    func testSaveStoresAccountAndTransactionDraftCarriesIt() throws {
        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                             OFXProfile.self, CategoryRule.self, CustomCategory.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let draft = ScheduleService.draft(fromName: "NETFLIX.COM", amount: -15.49, date: Date(), category: "Entertainment", accountId: "visa")
        XCTAssertEqual(draft.accountId, "visa")
        ScheduleService.save(draft, existing: nil, in: context)
        let bill = try XCTUnwrap(try context.fetch(FetchDescriptor<RecurringBill>()).first)
        XCTAssertEqual(bill.accountId, "visa")
        XCTAssertEqual(bill.item().accountId, "visa")
    }
}

final class FutureLedgerTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func d(_ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: day))! }

    func testFutureLedgerTransactionLandsOnItsDayAndBalanceIsNotDoubleCounted() {
        // Balance as of Nov 7 is $1000; a -$200 entry is booked for Nov 20.
        let entry = LedgerEntry(date: d(11, 20), name: "Dentist", amount: -200, accountId: "chk")
        let days = CashCalendar.grid(month: d(11, 1), schedules: [], balanceToday: 1000, today: d(11, 7),
                                     cashAccountIds: ["chk"], ledger: [entry], calendar: cal)
        func day(_ n: Int) -> CalendarDay { days.first { $0.date == d(11, n) }! }
        XCTAssertEqual(day(20).events.map(\.name), ["Dentist"])
        XCTAssertEqual(day(19).closing, 1000)     // balance before the entry
        XCTAssertEqual(day(20).closing, 800)
    }

    func testLedgerEntryOnUntrackedAccountIsIgnored() {
        let entry = LedgerEntry(date: d(11, 20), name: "Card buy", amount: -50, accountId: "visa")
        let days = CashCalendar.grid(month: d(11, 1), schedules: [], balanceToday: 800, today: d(11, 7),
                                     cashAccountIds: ["chk"], ledger: [entry], calendar: cal)
        XCTAssertTrue(days.allSatisfy { $0.events.isEmpty })
        XCTAssertEqual(days.first { $0.date == d(11, 25) }?.closing, 800)
    }

    func testBalanceBookLeavesOutFutureBookings() {
        let acct = Account(name: "Checking", type: .checking, accountId: "chk", bankName: "B", balance: 800)   // includes -200 booked ahead
        let today = d(11, 7)
        let txs = [TransactionRecord(fitid: "a", accountId: "chk", accountName: "Checking", date: d(11, 20), name: "Dentist", amount: -200, type: .debit),
                   TransactionRecord(fitid: "b", accountId: "chk", accountName: "Checking", date: d(11, 7), name: "Today", amount: -10, type: .debit)]
        let book = BalanceBook(transactions: txs, today: today, calendar: cal)
        XCTAssertEqual(book.today(acct), 1000)       // today's own transaction stays in
    }
}

final class BackupServiceTests: XCTestCase {
    @MainActor
    func testBackupRoundTripAndStartNew() throws {
        let container = try ModelContainer(for: Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                                           OFXProfile.self, CategoryRule.self, CustomCategory.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = container.mainContext
        ctx.insert(Account(name: "Checking", type: .checking, accountId: "chk", bankName: "Bank", balance: 100))
        let bill = RecurringBill(name: "Rent", amount: 1200, dueDay: 1, category: "Housing")
        bill.frequencyRaw = "weekly"; bill.accountId = "chk"; bill.occurrenceLogRaw = "2026-11-01|e"
        ctx.insert(bill)
        ctx.insert(TransactionRecord(fitid: "f1", accountId: "chk", accountName: "Checking", date: Date(), name: "Cafe", amount: -4, type: .debit))
        try ctx.save()

        let snap = BackupService.snapshot(in: ctx)
        let data = try BackupService.encode(snap)
        let back = try BackupService.decode(data)
        XCTAssertEqual(back.accounts, snap.accounts)
        XCTAssertEqual(back.schedules.first?.frequencyRaw, "weekly")

        BackupService.wipe(in: ctx)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<TransactionRecord>()).count, 0)
        BackupService.restore(back, in: ctx)
        let restored = try ctx.fetch(FetchDescriptor<RecurringBill>())
        XCTAssertEqual(restored.first?.occurrenceLogRaw, "2026-11-01|e")
        XCTAssertEqual(restored.first?.accountId, "chk")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<TransactionRecord>()).count, 1)

        BackupService.startNew(in: ctx)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).count, 0)
        XCTAssertFalse(try ctx.fetch(FetchDescriptor<CustomCategory>()).isEmpty)   // standard categories re-seeded
    }
}

final class PlaidMappingTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func dto(_ id: String, _ amt: Double, _ date: String, pending: Bool = false, merchant: String? = nil) -> PlaidTransactionDTO {
        PlaidTransactionDTO(transaction_id: id, account_id: "pa", amount: amt, date: date, name: "RAW NAME", merchant_name: merchant, pending: pending)
    }

    func testPlaidSpendingBecomesNegativeAndPendingIsSkipped() {
        let o = PlaidMapping.convert(dto("t1", 12.5, "2026-11-03", merchant: "Cafe"), accountId: "chk", calendar: cal)
        XCTAssertEqual(o?.amount, -12.5)
        XCTAssertEqual(o?.fitid, "plaid-t1")
        XCTAssertEqual(o?.name, "Cafe")
        XCTAssertEqual(o?.type, .debit)
        XCTAssertEqual(PlaidMapping.convert(dto("t2", -2000, "2026-11-04"), accountId: "chk", calendar: cal)?.amount, 2000)   // deposit
        XCTAssertNil(PlaidMapping.convert(dto("t3", 5, "2026-11-05", pending: true), accountId: "chk", calendar: cal))
    }

    @MainActor
    func testSplitKnownAdoptsExistingFileImports() {
        let d = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
        let have = TransactionRecord(fitid: "OFX123", accountId: "chk", accountName: "Checking", date: d, name: "Cafe", amount: -12.5, type: .debit)
        let incoming = [PlaidMapping.convert(dto("t1", 12.5, "2026-11-04"), accountId: "chk", calendar: cal)!,
                        PlaidMapping.convert(dto("t9", 40, "2026-11-04"), accountId: "chk", calendar: cal)!]
        let split = PlaidMapping.splitKnown(incoming, existing: [have], calendar: cal)
        XCTAssertEqual(split.new.map(\.fitid), ["plaid-t9"])
        XCTAssertEqual(split.adopt.map(\.fitid), ["plaid-t1"])
        XCTAssertTrue(split.adopt.first?.record === have)
    }

    func testCardBalanceIsStoredAsWhatYouOwe() {
        let card = PlaidAccountInfo(accountId: "c", name: "Visa", mask: "1234", type: "credit", subtype: "credit card", current: 250)
        XCTAssertEqual(card.appBalance, -250)
        XCTAssertEqual(card.appType, .creditCard)
        XCTAssertEqual(PlaidAccountInfo(accountId: "s", name: "Sv", mask: nil, type: "depository", subtype: "savings", current: 900).appType, .savings)
    }
}

final class BulkDeleteTests: XCTestCase {
    @MainActor
    func testDeletingClearsPeersAndUndoesManualBalance() throws {
        let container = try ModelContainer(for: Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                                           OFXProfile.self, CategoryRule.self, CustomCategory.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = container.mainContext
        let acct = Account(name: "Chk", type: .checking, accountId: "chk", bankName: "B", balance: 100)
        ctx.insert(acct)
        let manual = ManualTransactionService.add(to: acct, date: Date(), name: "Hand", amount: -30, in: ctx)   // balance 70
        let bank = TransactionRecord(fitid: "F1", accountId: "chk", accountName: "Chk", date: Date(), name: "Bank", amount: -5, type: .debit)
        let keeper = TransactionRecord(fitid: "F2", accountId: "chk", accountName: "Chk", date: Date(), name: "Keep", amount: 5, type: .credit)
        keeper.transferPeerId = bank.id; bank.transferPeerId = keeper.id
        ctx.insert(bank); ctx.insert(keeper); try ctx.save()
        let all = try ctx.fetch(FetchDescriptor<TransactionRecord>())
        let n = TransactionDeletionService.delete([manual, bank], accounts: [acct], all: all, in: ctx)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(acct.balance, 100)                    // the manual one's -30 is undone
        let left = try ctx.fetch(FetchDescriptor<TransactionRecord>())
        XCTAssertEqual(left.map(\.name), ["Keep"])
        XCTAssertNil(left.first?.transferPeerId)
    }
}

final class ForecastAccountsTests: XCTestCase {
    @MainActor
    func testForecastFollowsTheChosenAccounts() throws {
        let container = try ModelContainer(for: Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                                           OFXProfile.self, CategoryRule.self, CustomCategory.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = container.mainContext
        let cardBill = RecurringBill(name: "Netflix", amount: 20, dueDay: 28, category: "Fun")
        cardBill.accountId = "visa"
        let rent = RecurringBill(name: "Rent", amount: 1000, dueDay: 28, category: "Housing")
        rent.accountId = "chk"
        let payCard = RecurringBill(name: "Pay Visa", amount: 300, dueDay: 28, category: "Transfer")
        payCard.kindRaw = "transfer"; payCard.fromAccountId = "chk"; payCard.toAccountId = "visa"
        [cardBill, rent, payCard].forEach { ctx.insert($0) }
        let opts = ForecastOptions(months: 1, includeEnvelopes: false, fallbackAverageVariable: false,
                                   inferIncomeFromHistory: false, startingBalance: 5000,
                                   from: Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1))!)
        func names(_ ids: Set<String>?) -> [String] {
            CashFlowForecastService.forecast(bills: [cardBill, rent, payCard], envelopes: [], transactions: [], options: opts, accountIds: ids)
                .first?.events.map(\.name).sorted() ?? []
        }
        XCTAssertEqual(names(nil), ["Netflix", "Rent"])                 // everything: transfers cancel out
        XCTAssertEqual(names(["chk"]), ["Pay Visa", "Rent"])            // checking only: the card payment leaves
        XCTAssertEqual(names(["visa"]), ["Netflix", "Pay Visa"])        // card only: the payment arrives
    }
}

final class DashboardMathTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func d(_ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: day))! }

    func testNetWorthHistoryUndoesLaterTransactions() {
        // Today Nov 8: 1000 now. +500 on Nov 2, -200 on Oct 20.  End of Oct = 1000 - 500 = 500; end of Sep = 500 + 200 = 700.
        let tx: [(date: Date, amount: Double)] = [(d(11, 2), 500), (d(10, 20), -200), (d(11, 20), 999)]   // last one is future: ignored
        let pts = DashboardMath.netWorthHistory(currentTotal: 1000, transactions: tx, months: 2, today: d(11, 8), calendar: cal)
        XCTAssertEqual(pts.map(\.balance), [700, 500, 1000])
        XCTAssertEqual(pts.last?.date, d(11, 8))
    }

    func testProjectionStartsAtTodayAndHitsPayday() {
        let pay = ScheduleItem(name: "Pay", amount: 2000, dueDay: 15, category: "Income")
        let rent = ScheduleItem(name: "Rent", amount: -1200, dueDay: 12, category: "Housing")
        let r = DashboardMath.projection(days: 10, schedules: [pay, rent], balanceToday: 500, cashAccountIds: [], today: d(11, 8), calendar: cal)
        XCTAssertEqual(r.points.first?.date, d(11, 8))
        XCTAssertEqual(r.points.first?.balance, 500)
        XCTAssertEqual(r.points.last?.date, d(11, 18))
        XCTAssertEqual(r.points.first { $0.date == d(11, 12) }?.balance, -700)
        XCTAssertEqual(r.points.last?.balance, 1300)
        XCTAssertEqual(r.upcoming.map(\.name), ["Rent", "Pay"])
    }
}

final class MonthEndTests: XCTestCase {
    func testThirtyFirstLandsOnLastDayOfShortMonths() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func d(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day))! }
        let rule = ScheduleRule(frequency: .monthly, dueDay: 31)
        XCTAssertTrue(rule.occurs(on: d(2026, 1, 31), calendar: cal))
        XCTAssertTrue(rule.occurs(on: d(2026, 2, 28), calendar: cal))
        XCTAssertFalse(rule.occurs(on: d(2026, 2, 27), calendar: cal))
        XCTAssertTrue(rule.occurs(on: d(2026, 4, 30), calendar: cal))
        let twice = ScheduleRule(frequency: .semimonthly, dueDay: 15, secondDay: 31)
        XCTAssertEqual(twice.dates(from: d(2026, 2, 1), to: d(2026, 2, 28), calendar: cal), [d(2026, 2, 15), d(2026, 2, 28)])
    }
}

@MainActor
final class ReconciledTests: XCTestCase {
    func testBankRecordsAreReconciledAndHandEnteredOnesAreNot() {
        func tx(_ fitid: String) -> TransactionRecord {
            TransactionRecord(fitid: fitid, accountId: "a", accountName: "A", date: Date(), name: "x", amount: -5, type: .debit)
        }
        XCTAssertTrue(tx("20260101-123").isReconciled)                           // file import
        XCTAssertTrue(tx(PlaidMapping.prefix + "abc").isReconciled)              // bank sync
        XCTAssertFalse(tx(ManualTransactionService.prefix + "1").isReconciled)   // typed in by hand
    }
}

final class ScheduleEndTests: XCTestCase {
    func testEndDateStopsOccurrencesAndNthDateCounts() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func d(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day))! }
        var rule = ScheduleRule(frequency: .monthly, dueDay: 15)
        XCTAssertEqual(rule.nthDate(3, from: d(2026, 11, 8), calendar: cal), d(2027, 1, 15))   // Nov, Dec, Jan
        rule.end = d(2027, 1, 15)
        XCTAssertTrue(rule.occurs(on: d(2027, 1, 15), calendar: cal))
        XCTAssertFalse(rule.occurs(on: d(2027, 2, 15), calendar: cal))
        XCTAssertEqual(rule.dates(from: d(2026, 11, 1), to: d(2027, 6, 1), calendar: cal).count, 3)
        XCTAssertNil(rule.nextDate(from: d(2027, 1, 16), calendar: cal))
    }
}

final class PropertyAccountTests: XCTestCase {
    func testPropertyIsGroupedLastAndFlagged() {
        XCTAssertTrue(AccountType.property.isPropertyValue)
        XCTAssertFalse(AccountType.checking.isPropertyValue)
        XCTAssertEqual(AccountType.displayOrder.last, .property)
        let groups = AccountType.grouped([AccountType.property, .checking], by: { $0 })
        XCTAssertEqual(groups.map(\.type), [.checking, .property])
    }
}
