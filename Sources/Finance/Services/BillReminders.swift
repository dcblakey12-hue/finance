import Foundation
import SwiftData
import UserNotifications

// MARK: - Settings

/// Your bill reminder choices. Kept in this device's settings (not synced), so you can have them on
/// the iPhone and off on the Mac, or the other way round. Demo mode has its own set.
struct ReminderSettings: Equatable {
    enum Key {
        static let bills = "reminders.bills"
        static let daysBefore = "reminders.daysBefore"
        static let hour = "reminders.hour"
        static let transfers = "reminders.savingsTransfers"
        static let paychecks = "reminders.paychecks"
        static let graceDays = "reminders.graceDays"
    }

    /// Remind before bills are due.
    var billsOn = false
    /// How many days before the due date (0 = on the day).
    var daysBefore = 3
    /// Hour of the day the reminder arrives (24-hour clock).
    var hour = 9
    /// Also remind about moving money between your own accounts (savings, investing). Card and loan
    /// payments are bills and always included.
    var includeTransfers = false
    /// Tell me when an expected paycheck hasn't arrived.
    var paychecksOn = false
    /// How many days late a paycheck has to be before you're told.
    var graceDays = 2

    var anyOn: Bool { billsOn || paychecksOn }

    /// The settings this copy of the app uses (demo mode has its own).
    static var store: UserDefaults { DemoMode.isOn ? DemoMode.defaults : .standard }

    init() {}
    init(defaults d: UserDefaults) {
        billsOn = d.bool(forKey: Key.bills)
        daysBefore = d.object(forKey: Key.daysBefore) as? Int ?? 3
        hour = d.object(forKey: Key.hour) as? Int ?? 9
        includeTransfers = d.bool(forKey: Key.transfers)
        paychecksOn = d.bool(forKey: Key.paychecks)
        graceDays = d.object(forKey: Key.graceDays) as? Int ?? 2
    }
}

// MARK: - What to remind about

struct BillReminder: Identifiable, Equatable {
    enum Kind: String { case billDue, paycheckLate }
    let kind: Kind
    let billId: UUID
    let name: String
    /// Positive size of the payment.
    let amount: Double
    /// The day it's due (bill) or was expected (paycheck).
    let dueDate: Date
    /// When the notification goes off.
    let fireDate: Date
    var id: String { "\(kind.rawValue).\(billId.uuidString).\(Int(dueDate.timeIntervalSince1970))" }

    var title: String {
        switch kind {
        case .billDue: return "\(name) is due"
        case .paycheckLate: return "\(name) hasn't arrived"
        }
    }

    func body(calendar: Calendar = .current) -> String {
        let money = currency.string(from: NSNumber(value: amount)) ?? ""
        let day = dueDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        switch kind {
        case .billDue:
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: fireDate), to: calendar.startOfDay(for: dueDate)).day ?? 0
            let when = days == 0 ? "today" : (days == 1 ? "tomorrow" : "in \(days) days")
            return "\(money) is due \(when) (\(day))."
        case .paycheckLate:
            return "\(money) was expected \(day). Check with your employer or bank if it doesn't show up soon."
        }
    }
}

/// A scheduled payment as plain values, so the planner can be tested without SwiftData.
struct ReminderSchedule {
    let id: UUID
    let name: String
    let amount: Double
    let isIncome: Bool
    /// A transfer that isn't paying off a card or loan (e.g. moving money to savings).
    let isTransfer: Bool
    let rule: ScheduleRule
    /// Payments before this day are never "late" (when the schedule started being tracked).
    let trackedSince: Date?
}

enum BillReminderService {
    /// How far ahead reminders are set up (the app tops them up each time it opens).
    static let horizonDays = 35
    /// iOS keeps at most 64 pending notifications per app.
    static let maxPending = 60

    /// Every reminder from now to `horizonDays` ahead, soonest first. Ones whose time has
    /// already passed are left out.
    static func plan(_ schedules: [ReminderSchedule], settings: ReminderSettings, now: Date = Date(),
                     calendar: Calendar = .current) -> [BillReminder] {
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: horizonDays, to: today) else { return [] }
        func at(_ day: Date, plus days: Int) -> Date? {
            guard let d = calendar.date(byAdding: .day, value: days, to: day) else { return nil }
            return calendar.date(bySettingHour: min(max(settings.hour, 0), 23), minute: 0, second: 0, of: d)
        }
        var out: [BillReminder] = []
        for s in schedules {
            if s.isIncome {
                guard settings.paychecksOn else { continue }
                // A paycheck still unpaid `graceDays` after its date. Include ones already due but not yet late.
                guard let from = calendar.date(byAdding: .day, value: -settings.graceDays, to: today) else { continue }
                let start = max(from, s.trackedSince.map { calendar.startOfDay(for: $0) } ?? from)
                for d in s.rule.dates(from: start, to: end, calendar: calendar) {
                    guard let fire = at(d, plus: settings.graceDays), fire > now else { continue }
                    out.append(BillReminder(kind: .paycheckLate, billId: s.id, name: s.name, amount: abs(s.amount), dueDate: d, fireDate: fire))
                }
            } else {
                guard settings.billsOn, settings.includeTransfers || !s.isTransfer else { continue }
                for d in s.rule.dates(from: today, to: end, calendar: calendar) {
                    guard let fire = at(d, plus: -settings.daysBefore), fire > now else { continue }
                    out.append(BillReminder(kind: .billDue, billId: s.id, name: s.name, amount: abs(s.amount), dueDate: d, fireDate: fire))
                }
            }
        }
        return out.sorted { ($0.fireDate, $0.name) < ($1.fireDate, $1.name) }
    }

    /// Paychecks already later than the grace period and still not in (shown in the app).
    @MainActor
    static func latePaychecks(_ bills: [RecurringBill], settings: ReminderSettings, today: Date = Date(),
                              calendar: Calendar = .current) -> [OverdueItem] {
        ScheduleService.overdue(bills, today: today, calendar: calendar)
            .filter { $0.bill.isIncome && $0.daysLate(today: today, calendar: calendar) >= settings.graceDays }
    }

    /// `accounts` tells card and loan payments (bills) apart from other transfers.
    static func schedules(_ bills: [RecurringBill], accounts: [Account] = []) -> [ReminderSchedule] {
        let debts = Set(accounts.filter { $0.type == .creditCard || $0.type == .mortgage }.map(\.accountId))
        return bills.filter(\.isActive).map {
            ReminderSchedule(id: $0.id, name: $0.name, amount: $0.amount, isIncome: $0.isIncome,
                             isTransfer: $0.isTransfer && !debts.contains($0.toAccountId ?? ""),
                             rule: $0.rule, trackedSince: $0.trackedSince)
        }
    }
}

// MARK: - Notifications

/// Puts the planned reminders into the system's notification queue. Each copy of the app (real or
/// demo) only touches its own reminders, told apart by their identifier prefix.
@MainActor
enum BillReminderScheduler {
    static var prefix: String { DemoMode.isOn ? "finance.demo.reminder." : "finance.reminder." }

    /// Ask for permission to show notifications. Returns true when allowed.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// "allowed", "denied" or "notAsked".
    static func permission() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Replace this copy's pending reminders with `reminders` (only when notifications are allowed).
    static func replace(with reminders: [BillReminder]) async {
        let center = UNUserNotificationCenter.current()
        let mine = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: mine)
        guard !reminders.isEmpty else { return }
        let status = await permission()
        guard status == .authorized || status == .provisional else { return }
        let cal = Calendar.current
        for r in reminders.prefix(BillReminderService.maxPending) {
            let content = UNMutableNotificationContent()
            content.title = (DemoMode.isOn ? "Demo: " : "") + r.title
            content.body = r.body(calendar: cal)
            content.sound = .default
            let when = cal.dateComponents([.year, .month, .day, .hour, .minute], from: r.fireDate)
            let request = UNNotificationRequest(identifier: prefix + r.id, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
            try? await center.add(request)
        }
    }

    /// Work out and set up reminders from the current schedules and settings.
    static func refresh(_ bills: [RecurringBill], accounts: [Account], settings: ReminderSettings = ReminderSettings(defaults: ReminderSettings.store)) async {
        let plan = settings.anyOn ? BillReminderService.plan(BillReminderService.schedules(bills, accounts: accounts), settings: settings) : []
        await replace(with: plan)
    }
}
