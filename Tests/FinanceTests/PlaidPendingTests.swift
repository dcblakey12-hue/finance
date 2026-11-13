import XCTest
import SwiftData
@testable import Finance

@MainActor
final class PlaidPendingTests: XCTestCase {
    private var context: ModelContext!
    private let acct = "plaid-chk"
    private var cal: Calendar { Calendar.current }
    private func date(_ s: String) -> Date { PlaidMapping.date(s)! }

    override func setUp() async throws {
        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                             OFXProfile.self, CategoryRule.self, CustomCategory.self, SubscriptionMark.self])
        context = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
        context.insert(Account(name: "TD Bank", type: .checking, accountId: acct, bankName: "TD", balance: 1000))
        try context.save()
    }

    private func dto(_ id: String, _ amountOut: Double, _ day: String, _ name: String, pending: Bool = false, replaces: String? = nil) -> PlaidTransactionDTO {
        PlaidTransactionDTO(transaction_id: id, account_id: "chk", amount: amountOut, date: day, name: name, merchant_name: nil,
                            pending: pending, pending_transaction_id: replaces)
    }
    private func sync(added: [PlaidTransactionDTO] = [], modified: [PlaidTransactionDTO] = [], removed: [String] = []) -> PlaidSyncReport {
        var r = PlaidSyncReport(institution: "TD", date: Date())
        PlaidSync.apply(added: added, modified: modified, removed: removed, map: ["chk": acct], accountNames: [acct: "TD Bank"],
                        institution: "TD", report: &r, in: context)
        try? context.save()
        return r
    }
    private func records() -> [TransactionRecord] { (try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? [] }
    private func typeIn(_ name: String, _ amount: Double, _ day: String) -> TransactionRecord {
        let a = try! context.fetch(FetchDescriptor<Account>()).first!
        return ManualTransactionService.add(to: a, date: date(day), name: name, amount: amount, in: context)
    }

    func testPendingIsKeptOutOfTheBalanceAndBecomesThePostedOne() {
        let r1 = sync(added: [dto("p1", 42.10, "2026-11-12", "CORNER CAFE", pending: true)])
        XCTAssertEqual(r1.pending.count, 1)
        let pending = records().first!
        XCTAssertTrue(pending.isPending)
        XCTAssertFalse(pending.isOutstanding, "pending isn't counted as an outstanding entry")
        XCTAssertFalse(pending.isReconciled)
        pending.category = "Dining"   // you categorise it while it's pending

        let r2 = sync(added: [dto("x1", 45.60, "2026-11-13", "CORNER CAFE", replaces: "p1")], removed: ["p1"])
        XCTAssertEqual(r2.pendingPosted.count, 1)
        XCTAssertTrue(r2.added.isEmpty)
        let all = records()
        XCTAssertEqual(all.count, 1, "the pending one turned into the posted one, not a second row")
        XCTAssertEqual(all[0].fitid, "plaid-x1")
        XCTAssertFalse(all[0].isPending)
        XCTAssertEqual(all[0].amount, -45.60, "final amount with the tip")
        XCTAssertEqual(all[0].category, "Dining", "your category is kept")
    }

    func testPendingMatchesYourEntryThenThePostedOneReconcilesIt() {
        let mine = typeIn("Affirm", -223.91, "2026-11-11")
        let r1 = sync(added: [dto("p2", 223.91, "2026-11-12", "AFFIRM INC", pending: true)])
        XCTAssertEqual(r1.pendingMatchedToYours.count, 1)
        XCTAssertEqual(records().count, 1, "no second row for the pending one")
        XCTAssertEqual(mine.bankPendingId, "p2")
        XCTAssertTrue(mine.isOutstanding, "still outstanding until the bank posts it")

        let r2 = sync(added: [dto("x2", 223.91, "2026-11-14", "AFFIRM INC", replaces: "p2")], removed: ["p2"])
        XCTAssertEqual(r2.matchedToYours.count, 1)
        let all = records()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].fitid, "plaid-x2")
        XCTAssertTrue(all[0].isReconciled)
    }

    func testPostedAmountDifferentFromYourEntryStillReplacesItViaThePendingLink() {
        _ = typeIn("Dinner", -60, "2026-11-11")
        _ = sync(added: [dto("p3", 60, "2026-11-11", "BISTRO", pending: true)])
        let r = sync(added: [dto("x3", 72, "2026-11-13", "BISTRO", replaces: "p3")], removed: ["p3"])
        XCTAssertEqual(r.matchedToYours.count, 1)
        XCTAssertTrue(r.matchedToYours[0].note?.contains("Dinner") == true)
        XCTAssertEqual(records().map(\.amount), [-72])
    }

    func testPendingThatDropsOffFreesYourEntry() {
        let mine = typeIn("Hold", -50, "2026-11-11")
        _ = sync(added: [dto("p4", 50, "2026-11-11", "HOTEL HOLD", pending: true)])
        let r = sync(removed: ["p4"])
        XCTAssertNil(mine.bankPendingId)
        XCTAssertTrue(r.removed.isEmpty, "nothing of yours was removed")
        XCTAssertEqual(records().count, 1)
    }

    func testPostedMatchesYourEntryWithoutAPendingStep() {
        _ = typeIn("Plumber", -600, "2026-11-12")
        let r = sync(added: [dto("x5", 600, "2026-11-13", "JOE PLUMBING")])
        XCTAssertEqual(r.matchedToYours.count, 1)
        XCTAssertTrue(r.added.isEmpty)
        XCTAssertTrue(records().allSatisfy(\.isReconciled))
        XCTAssertTrue(r.summary.contains("1 matched to entries you typed in"))
    }

    func testReportsAreKeptPerBank() {
        let d = UserDefaults(suiteName: "plaid-report-\(UUID().uuidString)")!
        PlaidSyncReport.save(PlaidSyncReport(institution: "TD", date: Date(timeIntervalSince1970: 1)), d)
        PlaidSyncReport.save(PlaidSyncReport(institution: "Chase", date: Date(timeIntervalSince1970: 2)), d)
        PlaidSyncReport.save(PlaidSyncReport(institution: "TD", date: Date(timeIntervalSince1970: 3)), d)
        XCTAssertEqual(PlaidSyncReport.all(d).map(\.institution), ["TD", "Chase"])
    }
}
