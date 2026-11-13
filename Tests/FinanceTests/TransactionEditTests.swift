import XCTest
import SwiftData
@testable import Finance

@MainActor
final class TransactionEditTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private let cal = Calendar.current

    override func setUp() async throws {
        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                             OFXProfile.self, CategoryRule.self, CustomCategory.self, SubscriptionMark.self, SavingsGoal.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = ModelContext(container)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }
    private func account(_ id: String, balance: Double) -> Account {
        let a = Account(name: id.capitalized, type: .checking, accountId: id, bankName: "Bank", balance: balance)
        context.insert(a); return a
    }
    private func imported(_ fitid: String, in acct: String, _ name: String, _ amount: Double, on date: Date) -> TransactionRecord {
        let t = TransactionRecord(fitid: fitid, accountId: acct, accountName: acct.capitalized, date: date, name: name,
                                  amount: amount, type: amount < 0 ? .debit : .credit)
        context.insert(t); return t
    }
    private var accounts: [Account] { (try? context.fetch(FetchDescriptor<Account>())) ?? [] }
    private var allTx: [TransactionRecord] { (try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? [] }

    // MARK: Basic edits

    func testEditChangesEveryFieldAndKeepsTimeOfDay() {
        _ = account("chk", balance: 1000); _ = account("sav", balance: 50)
        let t = imported("F1", in: "chk", "COFFEE", -4, on: day(2026, 11, 3, hour: 9))
        var e = TransactionEdit(t)
        e.date = day(2026, 11, 1, hour: 18); e.name = "  Blue Bottle  "; e.amount = -5.5
        e.category = "Dining"; e.accountId = "sav"; e.memo = "with Sam"
        let r = TransactionEditService.apply(e, to: t, accounts: accounts, in: context)
        XCTAssertEqual(r.changed, [.date, .name, .amount, .account, .memo])
        XCTAssertTrue(r.categoryChanged)
        XCTAssertEqual(t.date, day(2026, 11, 1, hour: 9))
        XCTAssertEqual(t.name, "Blue Bottle"); XCTAssertEqual(t.amount, -5.5); XCTAssertEqual(t.type, .debit)
        XCTAssertEqual(t.category, "Dining"); XCTAssertEqual(t.memo, "with Sam")
        XCTAssertEqual(t.accountId, "sav"); XCTAssertEqual(t.accountName, "Sav")
        XCTAssertEqual(t.sourceAccountId, "chk")
        XCTAssertEqual(t.editedFields, [.date, .name, .amount, .account, .memo])
    }

    func testNoChangesIsANoOp() {
        _ = account("chk", balance: 1000)
        let t = imported("F1", in: "chk", "COFFEE", -4, on: day(2026, 11, 3))
        let r = TransactionEditService.apply(TransactionEdit(t), to: t, accounts: accounts, in: context)
        XCTAssertTrue(r.nothingChanged)
        XCTAssertFalse(t.wasEdited)
    }

    func testFlippingSignChangesType() {
        _ = account("chk", balance: 0)
        let t = imported("F1", in: "chk", "REFUND", -20, on: day(2026, 11, 3))
        var e = TransactionEdit(t); e.amount = 20
        TransactionEditService.apply(e, to: t, accounts: accounts, in: context)
        XCTAssertEqual(t.type, .credit); XCTAssertFalse(t.isExpense)
    }

    // MARK: Balances

    func testImportedEditsLeaveBankBalanceAlone() {
        let chk = account("chk", balance: 1000), sav = account("sav", balance: 50)
        let t = imported("F1", in: "chk", "COFFEE", -4, on: day(2026, 11, 3))
        var e = TransactionEdit(t); e.amount = -40; e.accountId = "sav"
        TransactionEditService.apply(e, to: t, accounts: accounts, in: context)
        XCTAssertEqual(chk.balance, 1000); XCTAssertEqual(sav.balance, 50)
    }

    func testManualEditsMoveTheBalance() {
        let chk = account("chk", balance: 1000), sav = account("sav", balance: 50)
        let t = ManualTransactionService.add(to: chk, date: day(2026, 11, 3), name: "Lunch", amount: -20, category: "Dining", in: context)
        XCTAssertEqual(chk.balance, 980)
        var e = TransactionEdit(t); e.amount = -25
        TransactionEditService.apply(e, to: t, accounts: accounts, in: context)
        XCTAssertEqual(chk.balance, 975)
        e = TransactionEdit(t); e.accountId = "sav"
        TransactionEditService.apply(e, to: t, accounts: accounts, in: context)
        XCTAssertEqual(chk.balance, 1000); XCTAssertEqual(sav.balance, 25)
        // Hand-entered ones aren't marked: the bank's own record replaces them.
        XCTAssertFalse(t.wasEdited); XCTAssertNil(t.sourceAccountId)
        // Net worth (sum of balances) is unchanged by moving it between accounts.
        XCTAssertEqual(chk.balance + sav.balance, 1025)
    }

    func testEditedManualEntryStillMatchesBankAndKeepsNotes() {
        let chk = account("chk", balance: 1000)
        let t = ManualTransactionService.add(to: chk, date: day(2026, 11, 1), name: "Lunch", amount: -20, category: "Dining", in: context)
        var e = TransactionEdit(t); e.date = day(2026, 11, 3); e.amount = -22; e.memo = "tip"
        TransactionEditService.apply(e, to: t, accounts: accounts, in: context)
        XCTAssertEqual(chk.balance, 978)
        // Bank reports it, with the corrected amount, and its balance already includes it.
        let parsed = ParsedOFXFile(bankId: "B", accountId: "chk", accountName: "Chk", balance: 978,
                                   transactions: [OFXTransaction(fitid: "BANK1", accountId: "chk", date: day(2026, 11, 4), name: "CAFE 123",
                                                                 amount: -22, type: .debit, memo: "")], isCreditCard: false)
        let r = TransactionImportService().importParsed(parsed, into: context)
        XCTAssertEqual(r.inserted, 1)
        XCTAssertEqual(allTx.count, 1)
        let bank = allTx[0]
        XCTAssertEqual(bank.fitid, "BANK1"); XCTAssertEqual(bank.category, "Dining"); XCTAssertEqual(bank.memo, "tip")
        XCTAssertEqual(chk.balance, 978)
    }

    // MARK: Surviving syncs

    func testPlaidUpdateKeepsYourEditsButTakesTheRest() {
        _ = account("chk", balance: 0)
        let t = imported("plaid-abc", in: "chk", "AMAZON", -30, on: day(2026, 11, 3))
        var e = TransactionEdit(t); e.date = day(2026, 11, 1); e.name = "Birthday gift"
        TransactionEditService.apply(e, to: t, accounts: accounts, in: context)
        // The bank later changes the date, name and amount.
        let o = OFXTransaction(fitid: "plaid-abc", accountId: "chk", date: day(2026, 11, 4), name: "AMAZON MKTPL", amount: -31, type: .debit, memo: "")
        PlaidMapping.applyModified(o, to: t)
        XCTAssertEqual(cal.startOfDay(for: t.date), day(2026, 11, 1, hour: 0))
        XCTAssertEqual(t.name, "Birthday gift")
        XCTAssertEqual(t.amount, -31)   // not edited, so the bank's correction comes through
    }

    func testPlaidUpdateWithoutEditsStillApplies() {
        let t = imported("plaid-abc", in: "chk", "AMAZON", -30, on: day(2026, 11, 3))
        let o = OFXTransaction(fitid: "plaid-abc", accountId: "chk", date: day(2026, 11, 4), name: "AMAZON MKTPL", amount: -31, type: .debit, memo: "")
        PlaidMapping.applyModified(o, to: t)
        XCTAssertEqual(t.date, day(2026, 11, 4)); XCTAssertEqual(t.name, "AMAZON MKTPL"); XCTAssertEqual(t.amount, -31)
    }

    func testReimportingAFileDoesNotDuplicateAnEditedOrMovedTransaction() {
        _ = account("chk", balance: 0); _ = account("sav", balance: 0)
        let t = imported("F1", in: "chk", "COFFEE", -4, on: day(2026, 11, 3))
        var e = TransactionEdit(t); e.accountId = "sav"; e.date = day(2026, 11, 10); e.amount = -5
        TransactionEditService.apply(e, to: t, accounts: accounts, in: context)
        let parsed = ParsedOFXFile(bankId: "B", accountId: "chk", accountName: "Chk", balance: nil,
                                   transactions: [OFXTransaction(fitid: "F1", accountId: "chk", date: day(2026, 11, 3), name: "COFFEE",
                                                                 amount: -4, type: .debit, memo: "")], isCreditCard: false)
        let r = TransactionImportService().importParsed(parsed, into: context)
        XCTAssertEqual(r.inserted, 0); XCTAssertEqual(r.skipped, 1)
        XCTAssertEqual(allTx.count, 1)
        XCTAssertEqual(t.amount, -5); XCTAssertEqual(t.accountId, "sav")
    }

    func testMovingBackHomeForgetsTheSource() {
        _ = account("chk", balance: 0); _ = account("sav", balance: 0)
        let t = imported("F1", in: "chk", "COFFEE", -4, on: day(2026, 11, 3))
        var e = TransactionEdit(t); e.accountId = "sav"
        TransactionEditService.apply(e, to: t, accounts: accounts, in: context)
        e = TransactionEdit(t); e.accountId = "chk"
        TransactionEditService.apply(e, to: t, accounts: accounts, in: context)
        XCTAssertNil(t.sourceAccountId); XCTAssertEqual(t.importKey, "chk|F1")
    }

    func testDedupeTreatsMovedCopyAsTheSameTransaction() {
        _ = account("chk", balance: 0); _ = account("sav", balance: 0)
        let t = imported("F1", in: "chk", "COFFEE", -4, on: day(2026, 11, 3))
        t.sourceAccountId = "chk"; t.accountId = "sav"
        _ = imported("F1", in: "chk", "COFFEE", -4, on: day(2026, 11, 3))   // the same one, synced from another device
        try? context.save()
        XCTAssertEqual(DedupeService.run(in: context), 1)
        XCTAssertEqual(allTx.count, 1)
    }

    // MARK: Categories, transfers, Coming Up

    func testCategoryEditIsLearned() {
        _ = account("chk", balance: 0)
        let t = imported("F1", in: "chk", "NETFLIX.COM", -15, on: day(2026, 11, 3))
        let other = imported("F2", in: "chk", "NETFLIX.COM", -15, on: day(2026, 10, 3))
        var e = TransactionEdit(t); e.category = "Entertainment"
        let r = TransactionEditService.apply(e, to: t, accounts: accounts, in: context)
        XCTAssertEqual(r.learned, 1)
        XCTAssertEqual(other.category, "Entertainment")
    }

    func testMovingOneSideOfATransferIntoThePeersAccountUnlinks() {
        _ = account("chk", balance: 0); _ = account("card", balance: 0)
        let out = imported("A", in: "chk", "PAYMENT", -100, on: day(2026, 11, 3))
        let inn = imported("B", in: "card", "PAYMENT", 100, on: day(2026, 11, 3))
        TransferLinkService.link(out, inn, in: context)
        var e = TransactionEdit(out); e.accountId = "card"
        TransactionEditService.apply(e, to: out, accounts: accounts, in: context)
        XCTAssertNil(out.transferPeerId); XCTAssertNil(inn.transferPeerId)
    }

    func testChangingTransferCategoryUnlinks() {
        _ = account("chk", balance: 0); _ = account("card", balance: 0)
        let out = imported("A", in: "chk", "PAYMENT", -100, on: day(2026, 11, 3))
        let inn = imported("B", in: "card", "PAYMENT", 100, on: day(2026, 11, 3))
        TransferLinkService.link(out, inn, in: context)
        var e = TransactionEdit(out); e.category = "Housing"
        TransactionEditService.apply(e, to: out, accounts: accounts, in: context)
        XCTAssertNil(out.transferPeerId); XCTAssertNil(inn.transferPeerId)
        XCTAssertEqual(inn.category, Categorizer.transfer)
    }

    func testRedatingAPaymentSettlesComingUp() {
        _ = account("chk", balance: 0)
        let today = day(2026, 11, 12)
        let rent = RecurringBill(name: "Rent", amount: 1500, dueDay: 3, category: "Housing")
        rent.trackedSince = day(2026, 10, 20)
        context.insert(rent)
        // Imported with a wrong date far from the due date, so it didn't count as paid.
        let paid = imported("F9", in: "chk", "LANDLORD", -1500, on: day(2026, 10, 1))
        XCTAssertEqual(ScheduleService.overdue([rent], today: today, calendar: cal).count, 1)
        var e = TransactionEdit(paid); e.date = day(2026, 11, 4)
        TransactionEditService.apply(e, to: paid, accounts: accounts, in: context, today: today, calendar: cal)
        XCTAssertTrue(ScheduleService.overdue([rent], today: today, calendar: cal).isEmpty)
    }

    func testEditedDateMovesReportAndBudgetMonth() {
        _ = account("chk", balance: 0)
        let t = imported("F1", in: "chk", "GROCER", -80, on: day(2026, 10, 31))
        t.category = "Groceries"
        var e = TransactionEdit(t); e.date = day(2026, 11, 1)
        TransactionEditService.apply(e, to: t, accounts: accounts, in: context)
        XCTAssertEqual(BudgetService.spent(for: "Groceries", year: 2026, month: 10, transactions: allTx), 0)
        XCTAssertEqual(BudgetService.spent(for: "Groceries", year: 2026, month: 11, transactions: allTx), 80)
    }

    // MARK: Backups (and so demo data)

    func testBackupKeepsEditMarks() throws {
        _ = account("chk", balance: 0); _ = account("sav", balance: 0)
        let t = imported("F1", in: "chk", "COFFEE", -4, on: day(2026, 11, 3))
        var e = TransactionEdit(t); e.accountId = "sav"; e.name = "Cafe"
        TransactionEditService.apply(e, to: t, accounts: accounts, in: context)
        let data = try BackupService.encode(BackupService.snapshot(in: context))
        BackupService.restore(try BackupService.decode(data), in: context)
        let back = try XCTUnwrap(allTx.first)
        XCTAssertEqual(back.editedFields, [.account, .name]); XCTAssertEqual(back.sourceAccountId, "chk")
    }

    func testOldBackupsWithoutEditFieldsStillLoad() throws {
        let json = #"{"id":"7C9A4C55-6B0B-4E1B-9A0B-3E0D3C3B2A10","fitid":"F1","accountId":"chk","accountName":"C","date":"2026-11-03T12:00:00Z","name":"X","amount":-4,"typeRaw":"debit","category":"Uncategorized","memo":""}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let row = try d.decode(BackupFile.TransactionRow.self, from: Data(json.utf8))
        XCTAssertNil(row.editedFieldsRaw); XCTAssertNil(row.sourceAccountId)
    }
}
