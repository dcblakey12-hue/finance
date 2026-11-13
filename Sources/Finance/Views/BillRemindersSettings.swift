import SwiftUI
import SwiftData
import UserNotifications

/// Bill reminder settings, shared by the Mac (Settings) and the iPhone (Scheduled ▸ bell).
/// Put it inside a Form.
struct BillRemindersSettings: View {
    @Query private var bills: [RecurringBill]
    @Query private var accounts: [Account]
    @AppStorage(ReminderSettings.Key.bills) private var billsOn = false
    @AppStorage(ReminderSettings.Key.daysBefore) private var daysBefore = 3
    @AppStorage(ReminderSettings.Key.hour) private var hour = 9
    @AppStorage(ReminderSettings.Key.transfers) private var includeTransfers = false
    @AppStorage(ReminderSettings.Key.paychecks) private var paychecksOn = false
    @AppStorage(ReminderSettings.Key.graceDays) private var graceDays = 2
    @State private var status: UNAuthorizationStatus = .notDetermined

    private var settings: ReminderSettings {
        var s = ReminderSettings()
        s.billsOn = billsOn; s.daysBefore = daysBefore; s.hour = hour
        s.includeTransfers = includeTransfers; s.paychecksOn = paychecksOn; s.graceDays = graceDays
        return s
    }

    var body: some View {
        let upcoming = BillReminderService.plan(BillReminderService.schedules(bills, accounts: accounts), settings: settings)
        let late = paychecksOn ? BillReminderService.latePaychecks(bills, settings: settings) : []

        Section {
            Toggle("Remind me before bills are due", isOn: $billsOn)
            if billsOn {
                Stepper(daysBefore == 0 ? "On the day it's due" : "\(daysBefore) day\(daysBefore == 1 ? "" : "s") before", value: $daysBefore, in: 0...14)
                Toggle("Include transfers to savings and investments", isOn: $includeTransfers)
            }
            Toggle("Tell me when a paycheck is late", isOn: $paychecksOn)
            if paychecksOn {
                Stepper("When \(graceDays) day\(graceDays == 1 ? "" : "s") late", value: $graceDays, in: 1...10)
            }
            if billsOn || paychecksOn {
                Picker("Time of day", selection: $hour) {
                    ForEach(6..<23, id: \.self) { h in
                        Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())?
                            .formatted(date: .omitted, time: .shortened) ?? "\(h):00").tag(h)
                    }
                }
            }
            if (billsOn || paychecksOn) && status == .denied {
                Label(Self.deniedHelp, systemImage: "bell.slash")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Bill reminders")
        } footer: {
            Text("Reminders are set up on this device only, from your scheduled transactions. Turn them on on just one device if you don't want them twice. A paycheck counts as arrived once it's entered or matched with a bank deposit.")
        }
        .task { status = await BillReminderScheduler.permission() }
        .onChange(of: billsOn) { _, on in if on { askPermission() } }
        .onChange(of: paychecksOn) { _, on in if on { askPermission() } }

        if billsOn || paychecksOn {
            Section("Coming reminders") {
                if !late.isEmpty {
                    ForEach(late) { item in
                        Label("\(item.bill.name) is \(item.daysLate()) days late (expected \(item.date.formatted(.dateTime.month(.abbreviated).day())))",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.callout)
                    }
                }
                if upcoming.isEmpty && late.isEmpty {
                    Text("Nothing in the next \(BillReminderService.horizonDays) days.").foregroundStyle(.secondary)
                }
                ForEach(upcoming.prefix(8)) { r in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: r.kind == .billDue ? "bell" : "banknote").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.title)
                            Text(r.body()).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(r.fireDate.formatted(.dateTime.month(.abbreviated).day().hour()))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if upcoming.count > 8 {
                    Text("and \(upcoming.count - 8) more").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    #if os(macOS)
    private static let deniedHelp = "Notifications are turned off for Finance. Turn them on in System Settings ▸ Notifications ▸ Finance."
    #else
    private static let deniedHelp = "Notifications are turned off for Finance. Turn them on in the Settings app ▸ Notifications ▸ Finance."
    #endif

    private func askPermission() {
        Task {
            _ = await BillReminderScheduler.requestPermission()
            status = await BillReminderScheduler.permission()
            await BillReminderScheduler.refresh(bills, accounts: accounts, settings: settings)
        }
    }
}

/// Keeps the system's reminders in step with your scheduled transactions and settings: when the app
/// opens or comes to the front, and whenever a schedule or a setting changes.
struct BillReminderWatcher: ViewModifier {
    @Query private var bills: [RecurringBill]
    @Query private var accounts: [Account]
    @AppStorage(ReminderSettings.Key.bills) private var billsOn = false
    @AppStorage(ReminderSettings.Key.daysBefore) private var daysBefore = 3
    @AppStorage(ReminderSettings.Key.hour) private var hour = 9
    @AppStorage(ReminderSettings.Key.transfers) private var includeTransfers = false
    @AppStorage(ReminderSettings.Key.paychecks) private var paychecksOn = false
    @AppStorage(ReminderSettings.Key.graceDays) private var graceDays = 2
    @Environment(\.scenePhase) private var scenePhase
    @State private var wakes = 0

    /// Changes whenever anything that affects the reminders changes.
    private var key: String {
        let b = bills.map { "\($0.id)\($0.name)\($0.amount)\($0.isActive)\($0.kindRaw)\($0.frequencyRaw)\($0.dueDay)\($0.secondDay)\($0.anchorDate?.timeIntervalSince1970 ?? 0)\($0.endDate?.timeIntervalSince1970 ?? 0)\($0.occurrenceLogRaw)" }
            .sorted().joined(separator: "|")
        let a = accounts.map { "\($0.accountId)\($0.typeRaw)" }.sorted().joined()
        return "\(b)#\(a)#\(billsOn)\(daysBefore)\(hour)\(includeTransfers)\(paychecksOn)\(graceDays)#\(wakes)"
    }

    func body(content: Content) -> some View {
        content
            .task(id: key) {
                var s = ReminderSettings()
                s.billsOn = billsOn; s.daysBefore = daysBefore; s.hour = hour
                s.includeTransfers = includeTransfers; s.paychecksOn = paychecksOn; s.graceDays = graceDays
                await BillReminderScheduler.refresh(bills, accounts: accounts, settings: s)
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { wakes += 1 } }
    }
}

extension View {
    /// Keep bill reminder notifications up to date (see `BillReminderWatcher`).
    func billReminders() -> some View { modifier(BillReminderWatcher()) }
}
