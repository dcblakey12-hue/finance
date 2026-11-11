import XCTest
import SwiftData
@testable import Finance

@MainActor
final class DemoDataTests: XCTestCase {
    private let cal = Calendar.current
    private var today: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 11))! }

    /// The demo must never be pointed at the iCloud container that holds real data.
    func testDemoRefusesTheRealICloudContainer() {
        XCTAssertEqual(DemoMode.safeCloudID(demo: "iCloud.com.blakey.finance.demo", real: "iCloud.com.blakey.finance"),
                       "iCloud.com.blakey.finance.demo")
        XCTAssertNil(DemoMode.safeCloudID(demo: "iCloud.com.blakey.finance", real: "iCloud.com.blakey.finance"))
        XCTAssertNil(DemoMode.safeCloudID(demo: "iCloud.com.Blakey.Finance", real: "iCloud.com.blakey.finance"))
        XCTAssertNil(DemoMode.safeCloudID(demo: "", real: "iCloud.com.blakey.finance"))
    }

    /// The demo's file is its own, never SwiftData's default store where real data lives.
    func testDemoUsesItsOwnFile() {
        XCTAssertEqual(DemoMode.storeURL.lastPathComponent, "Demo.store")
        XCTAssertEqual(DemoMode.storeURL.deletingLastPathComponent().lastPathComponent, "Finance Demo")
        XCTAssertNotEqual(DemoMode.storeURL, URL.applicationSupportDirectory.appending(path: "default.store"))
    }

    func testDemoHasEveryKindOfAccountAndMonthsOfHistory() {
        let file = DemoData.make(today: today, calendar: cal)
        XCTAssertEqual(Set(file.accounts.map(\.typeRaw)), Set(AccountType.allCases.map(\.rawValue)))
        XCTAssertGreaterThan(file.transactions.count, 300)
        let oldest = file.transactions.map(\.date).min()!
        XCTAssertLessThanOrEqual(oldest, cal.date(byAdding: .month, value: -5, to: today)!)
        XCTAssertTrue(file.transactions.allSatisfy { $0.date <= cal.date(byAdding: .day, value: 1, to: today)! })
        XCTAssertEqual(Set(file.transactions.map(\.fitid)).count, file.transactions.count, "fitids are unique")
        XCTAssertFalse(file.envelopes.isEmpty)
        XCTAssertFalse(file.schedules.isEmpty)
        XCTAssertTrue(file.profiles.isEmpty, "no bank login profiles in the demo")
    }

    func testBalancesLookLikeARealHousehold() {
        let file = DemoData.make(today: today, calendar: cal)
        func balance(_ id: String) -> Double { file.accounts.first { $0.accountId == id }!.balance }
        XCTAssertGreaterThan(balance(DemoData.checking.id), 1000)
        XCTAssertLessThan(balance(DemoData.visa.id), 0)
        XCTAssertGreaterThan(balance(DemoData.visa.id), -3000)
        XCTAssertLessThan(balance(DemoData.mortgage.id), -200_000)
        XCTAssertGreaterThan(file.accounts.reduce(0) { $0 + $1.balance }, 0, "positive net worth")

        // Checking never dips below zero on any day of the history.
        var running = DemoData.checking.opening
        for t in file.transactions.filter({ $0.accountId == DemoData.checking.id }).sorted(by: { $0.date < $1.date }) {
            running += t.amount
            XCTAssertGreaterThan(running, 0, "checking went negative on \(t.date)")
        }
    }

    func testTransfersArePairedBothWays() {
        let file = DemoData.make(today: today, calendar: cal)
        let byId = Dictionary(uniqueKeysWithValues: file.transactions.map { ($0.id, $0) })
        for t in file.transactions {
            guard let peer = t.transferPeerId else { continue }
            XCTAssertEqual(byId[peer]?.transferPeerId, t.id)
            XCTAssertEqual(byId[peer]?.amount, -t.amount)
        }
    }

    func testRestoresIntoAStoreWithOneOverduePayment() throws {
        let schema = Schema([Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
                             OFXProfile.self, CategoryRule.self, CustomCategory.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let file = DemoData.make(today: today, calendar: cal)
        BackupService.restore(file, in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Account>()), file.accounts.count)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TransactionRecord>()), file.transactions.count)
        let bills = try context.fetch(FetchDescriptor<RecurringBill>())
        let overdue = ScheduleService.overdue(bills, today: today, calendar: cal)
        XCTAssertEqual(overdue.map(\.bill.name), ["Peak Fitness"])
    }

    /// Writes the demo as a backup file when FINANCE_DEMO_EXPORT names a path
    /// (e.g. `FINANCE_DEMO_EXPORT=~/Desktop/Finance\ Demo.json swift test --filter DemoDataTests`).
    func testExportDemoFileWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["FINANCE_DEMO_EXPORT"], !path.isEmpty else { return }
        let data = try BackupService.encode(DemoData.make())
        try data.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }
}
