import XCTest
import SwiftData
@testable import Finance

@MainActor
final class ReconciliationTests: XCTestCase {
    private var context: ModelContext!
    private var acct: Account!

    override func setUp() async throws {
        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                             OFXProfile.self, CategoryRule.self, CustomCategory.self, SubscriptionMark.self, DismissedAlert.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        context = ModelContext(container)
        acct = Account(name: "Checking", type: .checking, accountId: "chk", bankName: "B", balance: 1000)
        context.insert(acct)
    }

    private var all: [TransactionRecord] { (try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? [] }
    private func bankTx(_ fitid: String, _ amount: Double, account: String = "chk") -> TransactionRecord {
        let t = TransactionRecord(fitid: fitid, accountId: account, accountName: "x", date: Date(), name: fitid,
                                  amount: amount, type: amount < 0 ? .debit : .credit)
        context.insert(t)
        return t
    }
    private func summary() -> ReconciliationSummary { ReconciliationService.summary(for: [acct], transactions: all) }

    func testBankTransactionsAreReconciledAndManualOnesOutstanding() {
        let bank = bankTx("BANK1", -20)
        let manual = ManualTransactionService.add(to: acct, date: Date(), name: "Coffee", amount: -5, in: context)
        XCTAssertTrue(bank.isReconciled)
        XCTAssertFalse(bank.isOutstanding)
        XCTAssertTrue(manual.isOutstanding)
        XCTAssertFalse(manual.isReconciled)
    }

    func testSummarySplitsBalanceIntoReconciledAndOutstanding() {
        ManualTransactionService.add(to: acct, date: Date(), name: "Check 1042", amount: -120, in: context)
        ManualTransactionService.add(to: acct, date: Date(), name: "Deposit", amount: 50, in: context)
        let s = summary()
        XCTAssertEqual(s.balance, 930)                 // 1000 - 120 + 50: what you'll have once they clear
        XCTAssertEqual(s.outstandingCount, 2)
        XCTAssertEqual(s.outstandingTotal, -70)
        XCTAssertEqual(s.reconciledBalance, 1000)      // what the bank should show
        XCTAssertTrue(s.hasOutstanding)
    }

    func testNoOutstandingMeansBothBalancesMatch() {
        _ = bankTx("BANK1", -20)
        let s = summary()
        XCTAssertEqual(s.outstandingCount, 0)
        XCTAssertEqual(s.reconciledBalance, s.balance)
        XCTAssertFalse(s.hasOutstanding)
    }

    func testMarkingByHandMovesEntryToReconciledWithoutChangingBalance() {
        let check = ManualTransactionService.add(to: acct, date: Date(), name: "Check 1042", amount: -120, in: context)
        XCTAssertTrue(ReconciliationService.setReconciled(check, true, in: context))
        XCTAssertTrue(check.isReconciled)
        XCTAssertEqual(acct.balance, 880)
        XCTAssertEqual(summary().reconciledBalance, 880)
        XCTAssertEqual(summary().outstandingCount, 0)
        // And back again.
        ReconciliationService.setReconciled(check, false, in: context)
        XCTAssertEqual(summary().reconciledBalance, 1000)
        XCTAssertEqual(summary().outstandingCount, 1)
    }

    func testBankTransactionsCannotBeToggled() {
        let bank = bankTx("plaid-abc", -20)
        XCTAssertFalse(ReconciliationService.canToggle(bank))
        XCTAssertFalse(ReconciliationService.setReconciled(bank, false, in: context))
        XCTAssertTrue(bank.isReconciled)
        XCTAssertFalse(bank.reconciledByHand)
    }

    func testImportMatchClearsOutstandingEntry() {
        ManualTransactionService.add(to: acct, date: Date(), name: "Rent", amount: -600, in: context)
        XCTAssertEqual(summary().outstandingCount, 1)
        XCTAssertEqual(summary().reconciledBalance, 1000)
        let posted = ParsedOFXFile(bankId: "B", accountId: "chk", accountName: "Checking", balance: 400,
            transactions: [OFXTransaction(fitid: "R1", accountId: "chk", date: Date(), name: "RENT", amount: -600, type: .debit, memo: "")])
        _ = TransactionImportService().importParsed(posted, into: context)
        let s = summary()
        XCTAssertEqual(s.outstandingCount, 0)
        XCTAssertEqual(s.reconciledBalance, 400)
        XCTAssertEqual(s.balance, 400)
    }

    func testBankBalanceDoesNotAddEntriesYouMarkedReconciled() {
        // You can see the check on your statement already, so the bank's figure includes it.
        let check = ManualTransactionService.add(to: acct, date: Date(), name: "Check 1042", amount: -120, in: context)
        let coffee = ManualTransactionService.add(to: acct, date: Date(), name: "Coffee", amount: -5, in: context)
        ReconciliationService.setReconciled(check, true, in: context)
        XCTAssertEqual(ManualTransactionService.unreported(in: "chk", from: all).map(\.id), [coffee.id])
        let statement = ParsedOFXFile(bankId: "B", accountId: "chk", accountName: "Checking", balance: 880, transactions: [])
        _ = TransactionImportService().importParsed(statement, into: context)
        XCTAssertEqual(acct.balance, 875)              // 880 from the bank, less the coffee it hasn't seen
        XCTAssertEqual(summary().reconciledBalance, 880)
        // When the bank's own record of the check arrives it still replaces the hand-entered one.
        let later = ParsedOFXFile(bankId: "B", accountId: "chk", accountName: "Checking", balance: 880,
            transactions: [OFXTransaction(fitid: "C1042", accountId: "chk", date: Date(), name: "CHECK 1042", amount: -120, type: .debit, memo: "")])
        _ = TransactionImportService().importParsed(later, into: context)
        XCTAssertFalse(all.contains { $0.id == check.id })
        XCTAssertEqual(acct.balance, 875)
    }

    func testSummaryCoversSeveralAccountsAndSkipsPropertyValues() {
        let card = Account(name: "Visa", type: .creditCard, accountId: "visa", bankName: "B", balance: -200)
        let home = Account(name: "Home", type: .property, accountId: "home", bankName: "B", balance: 400_000)
        [card, home].forEach { context.insert($0) }
        ManualTransactionService.add(to: acct, date: Date(), name: "Check", amount: -100, in: context)
        ManualTransactionService.add(to: card, date: Date(), name: "Coffee", amount: -5, in: context)
        let s = ReconciliationService.summary(for: [acct, card, home], transactions: all)
        XCTAssertEqual(s.balance, 900 + -205)
        XCTAssertEqual(s.outstandingCount, 2)
        XCTAssertEqual(s.reconciledBalance, 1000 + -200)
        // One account on its own only counts its own outstanding entries.
        XCTAssertEqual(ReconciliationService.summary(for: [card], transactions: all).outstandingCount, 1)
    }

    func testMarkSurvivesBackupAndRestore() throws {
        let check = ManualTransactionService.add(to: acct, date: Date(), name: "Check", amount: -100, in: context)
        ReconciliationService.setReconciled(check, true, in: context)
        ManualTransactionService.add(to: acct, date: Date(), name: "Coffee", amount: -5, in: context)
        let file = BackupService.snapshot(in: context)
        let decoded = try BackupService.decode(BackupService.encode(file))
        XCTAssertEqual(decoded.transactions.filter { $0.reconciledByHand == true }.count, 1)

        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                             OFXProfile.self, CategoryRule.self, CustomCategory.self, SubscriptionMark.self, DismissedAlert.self])
        let other = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
        BackupService.restore(decoded, in: other)
        let restored = try other.fetch(FetchDescriptor<TransactionRecord>())
        XCTAssertTrue(restored.first { $0.name == "Check" }!.isReconciled)
        XCTAssertTrue(restored.first { $0.name == "Coffee" }!.isOutstanding)
    }

    func testOldBackupsWithoutTheFieldStillLoad() throws {
        let json = """
        {"id":"\(UUID().uuidString)","fitid":"manual-1","accountId":"chk","accountName":"Checking","date":0,
         "name":"Coffee","amount":-5,"typeRaw":"debit","category":"Dining","memo":""}
        """
        let row = try JSONDecoder().decode(BackupFile.TransactionRow.self, from: Data(json.utf8))
        XCTAssertNil(row.reconciledByHand)
    }

    func testDemoHasOutstandingEntries() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 11))!
        let file = DemoData.make(today: today, calendar: cal)
        let manual = file.transactions.filter { $0.fitid.hasPrefix(ManualTransactionService.prefix) }
        XCTAssertEqual(manual.count, 4)
        XCTAssertEqual(manual.filter { $0.reconciledByHand == true }.count, 1)
        XCTAssertTrue(manual.contains { $0.accountId == DemoData.checking.id && $0.reconciledByHand == nil })
    }
}
