import Foundation
import SwiftData
#if os(macOS)
import AppKit
#endif

// MARK: - Demo mode

/// Demo mode shows a made-up household so the app can be shown to people without your data.
///
/// Your real data is never opened for writing in demo mode. The demo has its own data file
/// ("Finance Demo/Demo.store") and, when Info.plist's `FinanceDemoCloudContainer` names one, its own
/// iCloud container. That container is separate from the one that holds your real data, so the
/// Mac and the iPhone can share the demo (changes on one show on the other) without either app
/// writing a single made-up record next to your own. Leaving demo mode just switches back to your
/// real file; nothing is copied, merged or deleted there.
///
/// On the Mac the demo runs as its own copy of the app (launched with `-FinanceDemo`); your settings
/// are swapped for a throwaway set, Plaid bank connections are hidden and never synced, and Apple
/// Calendar is left alone. On the iPhone a switch saved on the phone picks which data file to show.
enum DemoMode {
    #if os(macOS)
    static let argument = "-FinanceDemo"
    static let isOn: Bool = ProcessInfo.processInfo.arguments.contains(argument)
        || ProcessInfo.processInfo.environment["FINANCE_DEMO"] == "1"
    #else
    /// The phone's demo switch (in the standard settings, never the demo's throwaway ones).
    static let flagKey = "demoMode"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: flagKey) }
    #endif

    private static let suiteName = "com.blakey.Finance.demo-settings"
    /// Settings used while showing the demo, in place of your own.
    static var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }
    /// Start each demo with default settings.
    static func resetSettings() { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

    /// The iCloud container for demo data only, or nil to keep the demo on this device.
    /// It is refused if it is missing or is the same as the container that holds your real data.
    static var cloudID: String? {
        func info(_ key: String) -> String {
            ((Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "").trimmingCharacters(in: .whitespaces)
        }
        return safeCloudID(demo: info("FinanceDemoCloudContainer"), real: info("FinanceCloudContainer"))
    }
    static func safeCloudID(demo: String, real: String) -> String? {
        guard !demo.isEmpty, demo.caseInsensitiveCompare(real) != .orderedSame else { return nil }
        return demo
    }
    /// True when the demo is shared between your Mac and iPhone through iCloud.
    static var isShared: Bool { cloudID != nil }

    /// The demo's own data file, apart from your real one.
    static var storeURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Finance Demo", directoryHint: .isDirectory)
            .appending(path: "Demo.store")
    }

    /// The demo's container: its own file, and its own iCloud container or none.
    /// `cloudKitDatabase` is always spelled out: `.automatic` would pick the first container in the
    /// entitlements, which is the one with your real data.
    static func makeContainer(schema: Schema) throws -> ModelContainer {
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let config = ModelConfiguration("FinanceDemo", schema: schema, url: storeURL,
                                        cloudKitDatabase: cloudID.map { .private($0) } ?? .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @MainActor private static var prepared = false

    /// Put the made-up household in the demo file.
    ///
    /// The Mac starts every demo with a fresh copy (dated around today) and shares it with the phone.
    /// The phone only fills the demo itself when it isn't shared; when it is, it waits for the Mac's copy,
    /// so the two never add the household twice.
    @MainActor
    static func prepare(in context: ModelContext) {
        guard isOn else { return }
        #if os(macOS)
        guard !prepared else { return }   // once per demo launch, not each time a window opens
        prepared = true
        BackupService.restore(DemoData.make(), in: context)
        #else
        guard !isShared, ((try? context.fetchCount(FetchDescriptor<Account>())) ?? 0) == 0 else { return }
        BackupService.restore(DemoData.make(), in: context)
        #endif
    }

    #if os(macOS)
    /// Ask, then reopen the app in (or out of) demo mode.
    @MainActor
    static func confirmAndSwitch() {
        let alert = NSAlert()
        if isOn {
            alert.messageText = "Leave the demo?"
            alert.informativeText = "Finance will reopen with your own data. Nothing from the demo is added to it."
                + (isShared ? " If your iPhone is showing the demo, tap Leave on its orange Demo bar to go back there too." : "")
            alert.addButton(withTitle: "Leave Demo")
        } else {
            alert.messageText = "Show demo data?"
            alert.informativeText = "Finance will reopen with a made-up household (accounts, transactions, budget and bills) that you can show to people. Your own data is not changed, and nothing from the demo goes to your banks or your calendar."
                + (isShared
                   ? " The demo has its own iCloud space, apart from your real data. To show it on your iPhone too, open Finance there and choose ••• ▸ Show Demo Data on the Overview tab."
                   : " The demo stays on this Mac.")
                + " Choose File ▸ Leave Demo Mode to come back."
            alert.addButton(withTitle: "Show Demo")
        }
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        relaunch(demo: !isOn)
    }

    @MainActor
    private static func relaunch(demo: Bool) {
        let args = demo ? [argument] : []
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = args
            config.createsNewApplicationInstance = true
            config.environment = ["FINANCE_DEMO": demo ? "1" : "0"]
            NSWorkspace.shared.openApplication(at: bundle, configuration: config) { _, error in
                guard error == nil else { return }
                Task { @MainActor in NSApp.terminate(nil) }
            }
        } else if let exe = Bundle.main.executableURL {
            // `swift run` build: no .app bundle, so start the executable directly.
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["FINANCE_DEMO"] = demo ? "1" : "0"
            p.environment = env
            if (try? p.run()) != nil { NSApp.terminate(nil) }
        }
    }
    #endif
}

// MARK: - Demo data

/// A made-up household: every name, bank, number and amount here is fictional.
/// Dates are built relative to `today`, so the demo always looks current.
enum DemoData {
    struct Acct {
        let id: String, name: String, type: AccountType, bank: String, opening: Double
    }

    static let checking = Acct(id: "DEMO-CHK-4821", name: "Everyday Checking", type: .checking, bank: "Harborview Bank", opening: 5200)
    static let savings  = Acct(id: "DEMO-SAV-7730", name: "High-Yield Savings", type: .savings, bank: "Summit Credit Union", opening: 14200)
    static let vacation = Acct(id: "DEMO-SAV-7731", name: "Vacation Fund", type: .savings, bank: "Summit Credit Union", opening: 900)
    static let visa     = Acct(id: "DEMO-CC-1188", name: "Rewards Visa", type: .creditCard, bank: "Northwind Card Services", opening: -1120)
    static let travelMC = Acct(id: "DEMO-CC-5024", name: "Travel Mastercard", type: .creditCard, bank: "Lakeside Bank", opening: -210)
    static let mortgage = Acct(id: "DEMO-MTG-3390", name: "Home Mortgage", type: .mortgage, bank: "Cedar Ridge Home Loans", opening: -252400)
    static let k401     = Acct(id: "DEMO-INV-6012", name: "Retirement 401(k)", type: .investment, bank: "Evergreen Investments", opening: 58300)
    static let brokerage = Acct(id: "DEMO-INV-6013", name: "Brokerage", type: .investment, bank: "Evergreen Investments", opening: 11800)
    static let cash     = Acct(id: "DEMO-CASH-0001", name: "Wallet Cash", type: .cash, bank: "Manual", opening: 60)
    static let home     = Acct(id: "property-demo-home", name: "Home", type: .property, bank: "42 Maple Lane (example)", opening: 412000)

    static let all = [checking, savings, vacation, visa, travelMC, mortgage, k401, brokerage, cash, home]

    /// The app's standard categories plus a few of the household's own.
    static let categories = ["Housing", "Groceries", "Dining", "Transport", "Utilities", "Entertainment", "Health",
                             "Savings", "Debt", "Other", "Childcare", "Shopping", "Travel", "Fees"]

    /// Monthly budget envelopes.
    static let budget: [(String, Double)] = [
        ("Housing", 1900), ("Groceries", 820), ("Dining", 420), ("Transport", 820), ("Utilities", 340),
        ("Entertainment", 90), ("Health", 130), ("Shopping", 220), ("Childcare", 1240), ("Travel", 200),
        ("Debt", 412), ("Other", 100),
    ]

    /// Months of history before the current month.
    static let monthsBack = 6

    static func make(today now: Date = Date(), calendar cal: Calendar = .current) -> BackupFile {
        let b = Builder(cal: cal, today: cal.startOfDay(for: now))
        b.run()
        return b.file(createdAt: now)
    }

    /// Small deterministic random generator (SplitMix64), so the demo looks the same every time.
    struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A class, so drawing random amounts while adding records never overlaps two accesses to the builder.
    final class Builder {
        let cal: Calendar
        let today: Date
        var rng = SeededRNG(state: 0x00F1_AA0C_E2026)
        var txs: [BackupFile.TransactionRow] = []
        var balances: [String: Double] = [:]
        var lastPaid: [String: Date] = [:]
        var serial = 0

        init(cal: Calendar, today: Date) {
            self.cal = cal; self.today = today
            for a in DemoData.all { balances[a.id] = a.opening }
        }

        // Dates
        var start: Date {
            let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: today))!
            return cal.date(byAdding: .month, value: -DemoData.monthsBack, to: thisMonth)!
        }
        func days(_ n: Int, from d: Date) -> Date { cal.date(byAdding: .day, value: n, to: d)! }
        /// Most recent Friday on or before today: the first earner's payday.
        var payAnchor: Date {
            var d = today
            while cal.component(.weekday, from: d) != 6 { d = days(-1, from: d) }
            return d
        }
        /// The gym bill falls due 4 days ago and hasn't been paid, so the app shows one overdue item.
        var gymDue: Date { days(-4, from: today) }
        var gymTrackedSince: Date { days(-10, from: today) }

        // Amounts
        func amt(_ lo: Double, _ hi: Double) -> Double { ((Double.random(in: lo...hi, using: &rng)) * 100).rounded() / 100 }
        func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
        func pick(_ xs: [String]) -> String { xs[Int.random(in: 0..<xs.count, using: &rng)] }

        // Records
        @discardableResult
        func add(_ a: Acct, _ date: Date, _ name: String, _ amount: Double, _ category: String,
                          id: UUID = UUID(), peer: UUID? = nil, schedule: String? = nil) -> UUID {
            serial += 1
            let value = (amount * 100).rounded() / 100
            txs.append(.init(id: id, fitid: "DEMO-\(String(format: "%05d", serial))", accountId: a.id, accountName: a.name,
                             date: cal.date(byAdding: .hour, value: 12, to: date)!, name: name, amount: value,
                             typeRaw: value < 0 ? "debit" : "credit", category: category, memo: "", transferPeerId: peer))
            balances[a.id, default: 0] += value
            if let schedule { lastPaid[schedule] = date }
            return id
        }

        func transfer(_ amount: Double, from: Acct, to: Acct, on date: Date, out outName: String, in inName: String,
                               schedule: String? = nil) {
            let a = UUID(), b = UUID()
            add(from, date, outName, -amount, Categorizer.transfer, id: a, peer: b, schedule: schedule)
            add(to, date, inName, amount, Categorizer.transfer, id: b, peer: a)
        }

        func run() {
            var visaStatement = 0.0, mcStatement = 0.0
            var day = start
            var monthIndex = 0
            let anchor = payAnchor
            // A yearly subscription, charged twice before the history above starts (so it can be spotted).
            for monthsBack in [23, 11] {
                if let d = cal.date(byAdding: .month, value: -monthsBack, to: today) {
                    add(DemoData.travelMC, days(19, from: d), "CLOUDNEST STORAGE ANNUAL", -99.99, "Other")
                }
            }
            while day <= today {
                let d = cal.component(.day, from: day)
                let weekday = cal.component(.weekday, from: day)   // 1 = Sunday
                let lastDay = cal.range(of: .day, in: .month, for: day)?.count ?? 30
                func on(_ n: Int) -> Bool { d == min(n, lastDay) }
                let monthsAgo = DemoData.monthsBack - monthIndex

                // Income
                let sinceAnchor = cal.dateComponents([.day], from: anchor, to: day).day ?? 1
                if ((sinceAnchor % 14) + 14) % 14 == 0 {
                    add(DemoData.checking, day, "BRIGHTLINE DESIGN CO PAYROLL", 2486.20, "Income", schedule: "Brightline Design paycheck")
                    add(DemoData.k401, day, "Payroll contribution", 310, Categorizer.transfer)
                }
                if on(15) || on(31) { add(DemoData.checking, day, "RIVERSIDE CLINIC DIRECT DEP", 1612.30, "Income", schedule: "Riverside Clinic paycheck") }
                if monthsAgo == 3 && on(19) { add(DemoData.checking, day, "STATE TAX REFUND", 612.00, "Income") }
                if on(28) { add(DemoData.brokerage, day, "Dividend reinvested", amt(18, 36), "Income") }

                // Checking bills and transfers
                if on(1) {
                    add(DemoData.checking, day, "CEDAR RIDGE HOME LOANS PMT", 1845.00 * -1, "Housing", schedule: "Mortgage")
                    add(DemoData.mortgage, day, "Principal payment", 548 + Double(monthIndex) * 2.35, Categorizer.transfer)
                }
                // Escrow paid straight out of the mortgage account. The mortgage is left out of spending and
                // cash flow by default, so these show in net worth but not in the Overview's spending.
                if monthsAgo % 6 == 0 && on(5) { add(DemoData.mortgage, day, "COUNTY PROPERTY TAX (ESCROW)", -2140, "Housing") }
                if monthsAgo % 12 == 4 && on(12) { add(DemoData.mortgage, day, "HOMEOWNERS INSURANCE (ESCROW)", -1380, "Housing") }
                // Savings and investing go out the day after the mid-month paycheck.
                if on(16) {
                    transfer(1000, from: DemoData.checking, to: DemoData.savings, on: day, out: "Transfer to High-Yield Savings", in: "Transfer from Everyday Checking", schedule: "Save to High-Yield Savings")
                    transfer(150, from: DemoData.checking, to: DemoData.vacation, on: day, out: "Transfer to Vacation Fund", in: "Transfer from Everyday Checking", schedule: "Vacation Fund")
                }
                if on(3) { add(DemoData.checking, day, "LITTLE SPROUTS DAYCARE", -1240, "Childcare", schedule: "Little Sprouts Daycare") }
                if on(16) { transfer(600, from: DemoData.checking, to: DemoData.brokerage, on: day, out: "Transfer to Evergreen Brokerage", in: "Deposit from Harborview", schedule: "Invest in Brokerage") }
                if on(9) { add(DemoData.checking, day, "SHIELD AUTO INSURANCE", -138.40, "Transport", schedule: "Car insurance") }
                if on(15) { add(DemoData.checking, day, "NORTHSHORE AUTO FINANCE", -412.00, "Debt", schedule: "Car loan") }
                if on(18) { add(DemoData.checking, day, "BRIGHTWATER ELECTRIC", -amt(92, 168), "Utilities", schedule: "Electric") }
                if on(22) { add(DemoData.checking, day, "SKYLINE FIBER INTERNET", -69.99, "Utilities", schedule: "Internet") }
                if on(26) { add(DemoData.checking, day, "CLEARWATER UTILITIES WATER", -amt(41, 58), "Utilities", schedule: "Water") }
                if on(cal.component(.day, from: gymDue)) && day < gymTrackedSince {
                    add(DemoData.checking, day, "PEAK FITNESS MEMBERSHIP", -49, "Health", schedule: "Peak Fitness")
                }
                if on(8) || on(23) { transfer(100, from: DemoData.checking, to: DemoData.cash, on: day, out: "ATM WITHDRAWAL", in: "Cash from ATM") }

                // Card statements close on the 20th and are paid in full from checking a few days later.
                if on(20) { visaStatement = max(0, -(balances[DemoData.visa.id] ?? 0)); mcStatement = max(0, -(balances[DemoData.travelMC.id] ?? 0)) }
                if on(25) && visaStatement > 0 {
                    transfer(visaStatement, from: DemoData.checking, to: DemoData.visa, on: day, out: "NORTHWIND CARD PAYMENT", in: "PAYMENT THANK YOU", schedule: "Pay Rewards Visa")
                    visaStatement = 0
                }
                if on(27) && mcStatement > 0 {
                    transfer(mcStatement, from: DemoData.checking, to: DemoData.travelMC, on: day, out: "LAKESIDE MASTERCARD PAYMENT", in: "PAYMENT RECEIVED - THANK YOU", schedule: "Pay Travel Mastercard")
                    mcStatement = 0
                }

                // Everyday spending on the Visa
                if chance(0.27) { add(DemoData.visa, day, pick(["FRESH BASKET MARKET #112", "GREENLEAF GROCERY", "FRESH BASKET MARKET #204"]), -amt(45, 165), "Groceries") }
                if chance(0.22) { add(DemoData.visa, day, "BEAN THERE COFFEE", -amt(4.5, 7.8), "Dining") }
                if chance(0.16) { add(DemoData.visa, day, pick(["CORNER BISTRO", "NOODLE HOUSE", "SLICE PIZZA CO", "TACO VERDE"]), -amt(18, 64), "Dining") }
                if weekday == 7 && chance(0.85) { add(DemoData.visa, day, "QUICKFUEL #2231", -amt(34, 58), "Transport") }
                if chance(0.06) { add(DemoData.visa, day, "ONLINE MARKETPLACE", -amt(18, 140), "Shopping") }
                if chance(0.03) { add(DemoData.visa, day, "HOME & HEARTH HARDWARE", -amt(25, 90), "Housing") }
                if chance(0.04) { add(DemoData.visa, day, "WELLNESS PHARMACY", -amt(9, 38), "Health") }
                if chance(0.05) { add(DemoData.visa, day, "CINEPLEX 8", -amt(24, 38), "Entertainment") }
                if on(7) { add(DemoData.visa, day, "STREAMFLIX", -15.49, "Entertainment", schedule: "StreamFlix") }
                if on(12) { add(DemoData.visa, day, "ORBIT WIRELESS", -84.12, "Utilities", schedule: "Phone") }
                // Subscriptions that aren't scheduled, for the Subscriptions screen to find:
                // a price rise, a weekly one, and one that stopped a few months ago.
                if on(14) { add(DemoData.visa, day, "TUNEBOX MUSIC", monthsAgo <= 1 ? -11.99 : -10.99, "Entertainment") }
                if weekday == 2 { add(DemoData.visa, day, "MORNING LEDGER DIGITAL", -3.99, "Entertainment") }
                if monthsAgo >= 3 && on(4) { add(DemoData.visa, day, "FITTRACK PREMIUM", -7.99, "Health") }
                if monthsAgo == 2 && on(11) { add(DemoData.visa, day, "RIVERSIDE DENTAL", -145.00, "Health") }

                // Cash and the travel card
                if chance(0.12) && (balances[DemoData.cash.id] ?? 0) > 40 { add(DemoData.cash, day, pick(["FARMERS MARKET", "BAKERY ON 5TH", "FOOD TRUCK"]), -amt(6, 34), pick(["Groceries", "Dining"])) }
                if chance(0.05) { add(DemoData.travelMC, day, "PARKSIDE PARKING", -amt(8, 22), "Transport") }
                if monthsAgo == 4 && on(6) { add(DemoData.travelMC, day, "BLUEJAY AIRWAYS", -486.40, "Travel") }
                if monthsAgo == 4 && on(21) { add(DemoData.travelMC, day, "SEASIDE INN", -642.18, "Travel") }
                if monthsAgo == 1 && on(10) { add(DemoData.travelMC, day, "MOUNTAIN VIEW LODGE", -389.75, "Travel") }
                // A few fees and some interest, for the Year in Review to find
                if monthsAgo == 4 && on(22) { add(DemoData.travelMC, day, "FOREIGN TRANSACTION FEE", -19.27, "Fees") }
                if monthsAgo == 3 && on(20) { add(DemoData.travelMC, day, "INTEREST CHARGE ON PURCHASES", -8.62, "Fees") }
                if monthsAgo == 2 && on(5) { add(DemoData.checking, day, "OUT OF NETWORK ATM FEE", -3.50, "Fees") }

                // A few recent purchases left uncategorized, to show categorizing
                if cal.isDate(day, inSameDayAs: days(-2, from: today)) { add(DemoData.visa, day, "SQ *LUNCHBOX TRUCK", -14.25, "Uncategorized") }
                if cal.isDate(day, inSameDayAs: days(-1, from: today)) { add(DemoData.visa, day, "POS 4471 ODDS AND ENDS", -27.60, "Uncategorized") }

                let next = days(1, from: day)
                if cal.component(.month, from: next) != cal.component(.month, from: day) { monthIndex += 1 }
                day = next
            }
        }

        func schedules() -> [BackupFile.ScheduleRow] {
            func row(_ name: String, _ amount: Double, day: Int, _ category: String, kind: String = "debit",
                     from: String? = nil, to: String? = nil, account: String? = nil, frequency: String = "monthly",
                     secondDay: Int = 15, anchor: Date? = nil, tracked: Date? = nil, end: Date? = nil) -> BackupFile.ScheduleRow {
                .init(id: UUID(), name: name, amount: amount, dueDay: day, category: category, isActive: true,
                      lastPaid: lastPaid[name], kindRaw: kind, fromAccountId: from, toAccountId: to,
                      frequencyRaw: frequency, secondDay: secondDay, anchorDate: anchor, occurrenceLogRaw: "",
                      accountId: account ?? from, trackedSince: tracked ?? today, endDate: end)
            }
            let chk = DemoData.checking.id
            let loanEnd = cal.date(byAdding: .month, value: 14, to: today).flatMap {
                cal.date(bySetting: .day, value: 15, of: $0)
            }
            return [
                row("Brightline Design paycheck", 2486.20, day: cal.component(.day, from: payAnchor), "Income", kind: "credit",
                    account: chk, frequency: "biweekly", anchor: payAnchor),
                row("Riverside Clinic paycheck", 1612.30, day: 15, "Income", kind: "credit", account: chk,
                    frequency: "semimonthly", secondDay: 31),
                row("Mortgage", 1845, day: 1, "Housing", account: chk),
                row("Save to High-Yield Savings", 1000, day: 16, Categorizer.transfer, kind: "transfer", from: chk, to: DemoData.savings.id),
                row("Vacation Fund", 150, day: 16, Categorizer.transfer, kind: "transfer", from: chk, to: DemoData.vacation.id),
                row("Little Sprouts Daycare", 1240, day: 3, "Childcare", account: chk),
                row("Invest in Brokerage", 600, day: 16, Categorizer.transfer, kind: "transfer", from: chk, to: DemoData.brokerage.id),
                row("StreamFlix", 15.49, day: 7, "Entertainment", account: DemoData.visa.id),
                row("Car insurance", 138.40, day: 9, "Transport", account: chk),
                row("Phone", 84.12, day: 12, "Utilities", account: DemoData.visa.id),
                row("Car loan", 412, day: 15, "Debt", account: chk, end: loanEnd),
                row("Electric", 125, day: 18, "Utilities", account: chk),
                row("Internet", 69.99, day: 22, "Utilities", account: chk),
                row("Pay Rewards Visa", 1700, day: 25, Categorizer.transfer, kind: "transfer", from: chk, to: DemoData.visa.id),
                row("Water", 50, day: 26, "Utilities", account: chk),
                row("Pay Travel Mastercard", 150, day: 27, Categorizer.transfer, kind: "transfer", from: chk, to: DemoData.travelMC.id),
                row("Peak Fitness", 49, day: cal.component(.day, from: gymDue), "Health", account: chk, tracked: gymTrackedSince),
            ]
        }

        func envelopes() -> [BackupFile.EnvelopeRow] {
            var out: [BackupFile.EnvelopeRow] = []
            for offset in -DemoData.monthsBack...2 {
                guard let m = cal.date(byAdding: .month, value: offset, to: today) else { continue }
                let c = cal.dateComponents([.year, .month], from: m)
                for (category, amount) in DemoData.budget {
                    out.append(.init(id: UUID(), category: category, year: c.year ?? 0, month: c.month ?? 0, allocated: amount))
                }
            }
            return out
        }

        func file(createdAt: Date) -> BackupFile {
            let accounts = DemoData.all.map { a in
                BackupFile.AccountRow(id: UUID(), name: a.name, typeRaw: a.type.rawValue, accountId: a.id, bankName: a.bank,
                                      balance: ((balances[a.id] ?? a.opening) * 100).rounded() / 100)
            }
            let ruleMerchants: [(String, String)] = [
                ("FRESH BASKET MARKET #112", "Groceries"), ("GREENLEAF GROCERY", "Groceries"), ("BEAN THERE COFFEE", "Dining"),
                ("QUICKFUEL #2231", "Transport"), ("STREAMFLIX", "Entertainment"), ("LITTLE SPROUTS DAYCARE", "Childcare"),
            ]
            let rules = ruleMerchants.map {
                BackupFile.RuleRow(merchantKey: MerchantNormalizer.key(for: $0.0), category: $0.1, createdAt: start, updatedAt: start)
            }
            let categories = DemoData.categories.map {
                BackupFile.CategoryRow(name: $0, createdAt: start)
            }
            return BackupFile(createdAt: createdAt, accounts: accounts, transactions: txs, envelopes: envelopes(),
                              schedules: schedules(), profiles: [], rules: rules, categories: categories)
        }
    }
}
