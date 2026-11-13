import Foundation
import SwiftData
import UserNotifications

// MARK: - Dismissed alerts (synced)

/// An alert you've looked at and dismissed. Synced, so dismissing on the Mac clears it on the iPhone.
@Model
final class DismissedAlert {
    var key: String = ""
    var dismissedAt: Date = Date()
    init(key: String, dismissedAt: Date = Date()) { self.key = key; self.dismissedAt = dismissedAt }
}

// MARK: - Settings

/// Which spending alerts you want. Kept on this device (demo mode has its own set).
struct AlertSettings: Equatable {
    enum Key {
        static let unusual = "alerts.unusual"
        static let duplicates = "alerts.duplicates"
        static let budget = "alerts.budget"
        static let largeAmount = "alerts.largeAmount"
        static let notify = "alerts.notify"
    }
    /// A charge much bigger than usual at that merchant.
    var unusualOn = true
    /// The same charge twice in a few days.
    var duplicatesOn = true
    /// A budget category over (or nearly at) its envelope this month.
    var budgetOn = true
    /// Any one-off charge at least this big (0 = off).
    var largeAmount: Double = 500
    /// Send a notification when a new alert turns up.
    var notify = false

    init() {}
    init(defaults d: UserDefaults) {
        unusualOn = d.object(forKey: Key.unusual) as? Bool ?? true
        duplicatesOn = d.object(forKey: Key.duplicates) as? Bool ?? true
        budgetOn = d.object(forKey: Key.budget) as? Bool ?? true
        largeAmount = d.object(forKey: Key.largeAmount) as? Double ?? 500
        notify = d.bool(forKey: Key.notify)
    }
    static var store: UserDefaults { DemoMode.isOn ? DemoMode.defaults : .standard }
}

// MARK: - Alerts

struct SpendingAlert: Identifiable, Equatable {
    enum Kind: String { case duplicate, unusual, large, overBudget, nearBudget }
    let kind: Kind
    /// Stable identity, used to remember that you dismissed it.
    let key: String
    let title: String
    let detail: String
    /// When it happened (the charge's date, or today for budgets).
    let date: Date
    let amount: Double
    let category: String
    /// The charges it's about (empty for budgets).
    let transactionIds: [UUID]
    var id: String { key }

    var symbol: String {
        switch self.kind {
        case .duplicate: return "doc.on.doc"
        case .unusual: return "arrow.up.right.circle"
        case .large: return "exclamationmark.circle"
        case .overBudget: return "chart.pie.fill"
        case .nearBudget: return "chart.pie"
        }
    }
}

enum SpendingAlertService {
    /// Charges from this many days back are checked.
    static let lookbackDays = 30
    /// Duplicates: same amount at the same merchant on the same account within this many days.
    static let duplicateWindowDays = 3
    /// Smaller duplicates are ignored (two coffees on the same day are normal).
    static let duplicateMinimum = 10.0
    /// Categories that aren't spending.
    static let ignoredCategories: Set<String> = [Categorizer.transfer, "Income"]

    private static func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }

    /// Everything worth a look, newest first. `budgets` are this month's envelopes (category, allocated).
    static func detect(_ rows: [ChargeRow], budgets: [(category: String, allocated: Double)], settings: AlertSettings,
                       dismissed: Set<String> = [], today: Date = Date(), calendar: Calendar = .current) -> [SpendingAlert] {
        let todayStart = calendar.startOfDay(for: today)
        guard let since = calendar.date(byAdding: .day, value: -lookbackDays, to: todayStart),
              let yearAgo = calendar.date(byAdding: .month, value: -12, to: todayStart),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) else { return [] }
        let expenses = rows.filter { $0.amount < 0 && !$0.isTransfer && !ignoredCategories.contains($0.category) && $0.date < tomorrow }
        var byMerchant: [String: [ChargeRow]] = [:]
        for c in expenses where c.date >= yearAgo {
            let k = MerchantNormalizer.key(for: c.name)
            if !k.isEmpty { byMerchant[k, default: []].append(c) }
        }
        let recent = expenses.filter { $0.date >= since }
        var out: [SpendingAlert] = []
        var flagged = Set<UUID>()

        // Duplicates
        if settings.duplicatesOn {
            for (_, list) in byMerchant {
                let sorted = list.filter { $0.date >= since }.sorted { $0.date < $1.date }
                for (i, a) in sorted.enumerated() {
                    for b in sorted[(i + 1)...] {
                        let gap = calendar.dateComponents([.day], from: calendar.startOfDay(for: a.date), to: calendar.startOfDay(for: b.date)).day ?? 99
                        guard gap <= duplicateWindowDays else { break }
                        guard a.accountId == b.accountId, abs(a.amount - b.amount) < 0.005, abs(a.amount) >= duplicateMinimum,
                              !flagged.contains(b.id) else { continue }
                        flagged.insert(b.id)
                        let name = SubscriptionService.displayName(MerchantNormalizer.key(for: b.name))
                        let when = gap == 0 ? "on the same day" : "\(gap) day\(gap == 1 ? "" : "s") apart"
                        out.append(SpendingAlert(kind: .duplicate, key: "dup|\(b.id)",
                                                 title: "Possible double charge at \(name)",
                                                 detail: "\(money(abs(b.amount))) twice on \(b.accountName), \(when). Check it wasn't charged twice by mistake.",
                                                 date: b.date, amount: abs(b.amount), category: b.category, transactionIds: [a.id, b.id]))
                    }
                }
            }
        }

        // Bigger than usual, and large one-offs
        for c in recent where !flagged.contains(c.id) {
            let size = abs(c.amount)
            let key = MerchantNormalizer.key(for: c.name)
            let name = SubscriptionService.displayName(key.isEmpty ? c.name : key)
            let before = (byMerchant[key] ?? []).filter { $0.date < c.date && $0.id != c.id }.map { abs($0.amount) }.sorted()
            let usual = before.isEmpty ? nil : before[before.count / 2]
            if settings.unusualOn, before.count >= 3, let usual, size > max(usual * 2, usual + 25) {
                flagged.insert(c.id)
                out.append(SpendingAlert(kind: .unusual, key: "unusual|\(c.id)",
                                         title: "Bigger than usual at \(name)",
                                         detail: "\(money(size)) on \(c.date.formatted(.dateTime.month(.abbreviated).day())), about \(String(format: "%.1f", size / usual))× your usual \(money(usual)).",
                                         date: c.date, amount: size, category: c.category, transactionIds: [c.id]))
                continue
            }
            // A big charge you don't pay regularly (rent, daycare and the like are left alone).
            let regular = before.count >= 2 && usual.map { abs(size - $0) <= $0 * 0.2 } == true
            if settings.largeAmount > 0, size >= settings.largeAmount, !regular {
                flagged.insert(c.id)
                out.append(SpendingAlert(kind: .large, key: "large|\(c.id)",
                                         title: "Large charge at \(name)",
                                         detail: "\(money(size)) on \(c.accountName), \(c.date.formatted(.dateTime.month(.abbreviated).day())).",
                                         date: c.date, amount: size, category: c.category, transactionIds: [c.id]))
            }
        }

        // Budgets this month
        if settings.budgetOn {
            let y = calendar.component(.year, from: todayStart), m = calendar.component(.month, from: todayStart)
            let monthKey = String(format: "%04d-%02d", y, m)
            var spent: [String: Double] = [:]
            for c in expenses where calendar.component(.year, from: c.date) == y && calendar.component(.month, from: c.date) == m {
                spent[c.category, default: 0] += abs(c.amount)
            }
            let daysIn = Double(calendar.range(of: .day, in: .month, for: todayStart)?.count ?? 30)
            let dayNow = Double(calendar.component(.day, from: todayStart))
            for b in budgets where b.allocated > 0 {
                let s = spent[b.category] ?? 0
                if s > b.allocated {
                    out.append(SpendingAlert(kind: .overBudget, key: "over|\(b.category)|\(monthKey)",
                                             title: "\(b.category) is over budget",
                                             detail: "\(money(s)) spent of \(money(b.allocated)) this month, \(money(s - b.allocated)) over.",
                                             date: todayStart, amount: s - b.allocated, category: b.category, transactionIds: []))
                } else if s >= b.allocated * 0.9, dayNow / daysIn < 0.9 {
                    // Nearly used up with a good part of the month still to go.
                    out.append(SpendingAlert(kind: .nearBudget, key: "near|\(b.category)|\(monthKey)",
                                             title: "\(b.category) is nearly at its budget",
                                             detail: "\(money(s)) of \(money(b.allocated)) spent, with \(Int(daysIn - dayNow)) days left this month.",
                                             date: todayStart, amount: b.allocated - s, category: b.category, transactionIds: []))
                }
            }
        }

        return out.filter { !dismissed.contains($0.key) }.sorted { ($0.date, $0.key) > ($1.date, $1.key) }
    }

    /// Alerts from the store: spending accounts only, this month's envelopes, minus dismissed ones.
    @MainActor
    static func current(transactions: [TransactionRecord], accounts: [Account], envelopes: [Envelope],
                        dismissed: [DismissedAlert], settings: AlertSettings, today: Date = Date(),
                        calendar: Calendar = .current) -> [SpendingAlert] {
        let rows = CashFlowScope.transactions(transactions, accounts: accounts).map {
            ChargeRow(id: $0.id, name: $0.name, amount: $0.amount, date: $0.date, category: $0.category,
                      accountId: $0.accountId, accountName: $0.accountName, isTransfer: $0.transferPeerId != nil)
        }
        let y = calendar.component(.year, from: today), m = calendar.component(.month, from: today)
        let budgets = envelopes.filter { $0.year == y && $0.month == m }.map { (category: $0.category, allocated: $0.allocated) }
        return detect(rows, budgets: budgets, settings: settings, dismissed: Set(dismissed.map(\.key)), today: today, calendar: calendar)
    }

    @MainActor
    static func dismiss(_ alerts: [SpendingAlert], in context: ModelContext) {
        for a in alerts { context.insert(DismissedAlert(key: a.key)) }
        try? context.save()
    }

    /// Forget dismissals older than a few months (the alerts they hid are long gone).
    @MainActor
    static func pruneDismissed(in context: ModelContext, now: Date = Date()) {
        guard let cutoff = Calendar.current.date(byAdding: .month, value: -3, to: now) else { return }
        let old = (try? context.fetch(FetchDescriptor<DismissedAlert>(predicate: #Predicate { $0.dismissedAt < cutoff }))) ?? []
        guard !old.isEmpty else { return }
        for d in old { context.delete(d) }
        try? context.save()
    }
}

// MARK: - Notifications

/// Sends a notification the first time this device sees each new alert.
@MainActor
enum SpendingAlertNotifier {
    private static var seenKey: String { "alerts.notifiedKeys" }

    static func notifyNew(_ alerts: [SpendingAlert], settings: AlertSettings, defaults: UserDefaults = AlertSettings.store) async {
        let seen = Set(defaults.stringArray(forKey: seenKey) ?? [])
        let fresh = alerts.filter { !seen.contains($0.key) }
        // Remember everything current (and drop keys of alerts that have gone), so nothing is sent twice.
        defaults.set(alerts.map(\.key), forKey: seenKey)
        // The first time, just take note of what's already there rather than sending a pile of old news.
        let primedKey = "alerts.notifiedPrimed"
        guard defaults.bool(forKey: primedKey) else { defaults.set(true, forKey: primedKey); return }
        guard settings.notify, !fresh.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let prefix = DemoMode.isOn ? "Demo: " : ""
        if fresh.count > 3 {
            let content = UNMutableNotificationContent()
            content.title = prefix + "\(fresh.count) new spending alerts"
            content.body = fresh.prefix(3).map(\.title).joined(separator: " • ")
            try? await center.add(UNNotificationRequest(identifier: "finance.alert.batch.\(UUID().uuidString)", content: content, trigger: nil))
        } else {
            for a in fresh {
                let content = UNMutableNotificationContent()
                content.title = prefix + a.title
                content.body = a.detail
                content.sound = .default
                try? await center.add(UNNotificationRequest(identifier: "finance.alert.\(a.key)", content: content, trigger: nil))
            }
        }
    }
}
