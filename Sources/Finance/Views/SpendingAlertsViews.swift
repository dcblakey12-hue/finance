import SwiftUI
import SwiftData
import UserNotifications

/// Reads the alert settings from this copy's settings (demo has its own).
private struct AlertSettingsReader: DynamicProperty {
    @AppStorage(AlertSettings.Key.unusual) var unusualOn = true
    @AppStorage(AlertSettings.Key.duplicates) var duplicatesOn = true
    @AppStorage(AlertSettings.Key.budget) var budgetOn = true
    @AppStorage(AlertSettings.Key.largeAmount) var largeAmount = 500.0
    @AppStorage(AlertSettings.Key.notify) var notify = false
    var value: AlertSettings {
        var s = AlertSettings()
        s.unusualOn = unusualOn; s.duplicatesOn = duplicatesOn; s.budgetOn = budgetOn
        s.largeAmount = largeAmount; s.notify = notify
        return s
    }
}

/// The current alerts, worked out from the store.
struct CurrentAlerts: DynamicProperty {
    @Query private var transactions: [TransactionRecord]
    @Query private var accounts: [Account]
    @Query private var envelopes: [Envelope]
    @Query private var dismissed: [DismissedAlert]
    private var settings = AlertSettingsReader()
    @MainActor var alerts: [SpendingAlert] {
        SpendingAlertService.current(transactions: transactions, accounts: accounts, envelopes: envelopes,
                                     dismissed: dismissed, settings: settings.value)
    }
    var settingsValue: AlertSettings { settings.value }
}

/// One alert, with a Dismiss button.
struct SpendingAlertRow: View {
    let alert: SpendingAlert
    let onDismiss: () -> Void

    private var tint: Color {
        switch alert.kind {
        case .duplicate, .overBudget: return .red
        case .unusual, .large, .nearBudget: return .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: alert.symbol).foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.body.weight(.medium))
                Text(alert.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Dismiss", action: onDismiss)
                #if os(macOS)
                .buttonStyle(.link)
                #else
                .buttonStyle(.borderless)
                #endif
                .font(.caption)
        }
        .padding(.vertical, 2)
    }
}

/// Settings for spending alerts. Put it inside a Form.
struct SpendingAlertSettings: View {
    @AppStorage(AlertSettings.Key.unusual) private var unusualOn = true
    @AppStorage(AlertSettings.Key.duplicates) private var duplicatesOn = true
    @AppStorage(AlertSettings.Key.budget) private var budgetOn = true
    @AppStorage(AlertSettings.Key.largeAmount) private var largeAmount = 500.0
    @AppStorage(AlertSettings.Key.notify) private var notify = false

    var body: some View {
        Section {
            Toggle("Charges much bigger than usual at a merchant", isOn: $unusualOn)
            Toggle("Possible double charges", isOn: $duplicatesOn)
            Toggle("Budget categories over or nearly at their limit", isOn: $budgetOn)
            Picker("One-off charges over", selection: $largeAmount) {
                Text("Off").tag(0.0)
                ForEach([100.0, 250, 500, 1000, 2500], id: \.self) { v in
                    Text(currency.string(from: NSNumber(value: v)) ?? "").tag(v)
                }
            }
            Toggle("Send a notification for new alerts", isOn: $notify)
                .onChange(of: notify) { _, on in
                    if on { Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) } }
                }
        } header: {
            Text("Spending alerts")
        } footer: {
            Text("Looks at the last \(SpendingAlertService.lookbackDays) days in the accounts that count toward spending. Notifications are sent from this device only.")
        }
    }
}

/// The list of alerts, as a List section (empty state included).
struct SpendingAlertsSection: View {
    let alerts: [SpendingAlert]
    @Environment(\.modelContext) private var context

    var body: some View {
        Section {
            if alerts.isEmpty {
                Text("Nothing unusual right now.").foregroundStyle(.secondary)
            }
            ForEach(alerts) { a in
                SpendingAlertRow(alert: a) { SpendingAlertService.dismiss([a], in: context) }
            }
        } header: {
            HStack {
                Text("Alerts")
                Spacer()
                if alerts.count > 1 {
                    Button("Dismiss All") { SpendingAlertService.dismiss(alerts, in: context) }
                        .font(.caption)
                }
            }
        }
    }
}

/// Sends notifications for new alerts when the data changes or the app comes to the front.
struct SpendingAlertWatcher: ViewModifier {
    var current = CurrentAlerts()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    @State private var wakes = 0

    func body(content: Content) -> some View {
        let alerts = current.alerts
        let key = alerts.map(\.key).joined(separator: ",") + "#\(wakes)"
        content
            .task(id: key) {
                SpendingAlertService.pruneDismissed(in: context)
                await SpendingAlertNotifier.notifyNew(alerts, settings: current.settingsValue)
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { wakes += 1 } }
    }
}

extension View {
    /// Notify about new spending alerts (see `SpendingAlertWatcher`).
    func spendingAlerts() -> some View { modifier(SpendingAlertWatcher()) }
}

/// A banner listing how many alerts there are, with the first one's title. Tap to see them all.
struct SpendingAlertsBanner: View {
    let alerts: [SpendingAlert]
    var body: some View {
        let urgent = alerts.contains { $0.kind == .duplicate || $0.kind == .overBudget }
        HStack(spacing: 10) {
            Image(systemName: "bell.badge.fill").foregroundStyle(urgent ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(alerts.count) spending alert\(alerts.count == 1 ? "" : "s")").font(.subheadline.bold())
                Text(alerts.prefix(2).map(\.title).joined(separator: " • ") + (alerts.count > 2 ? " …" : ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((urgent ? Color.red : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

/// All alerts plus their settings (the iPhone screen and the Mac sheet).
struct SpendingAlertsScreen: View {
    var current = CurrentAlerts()
    var body: some View {
        Form {
            SpendingAlertsSection(alerts: current.alerts)
            SpendingAlertSettings()
        }
        .navigationTitle("Spending Alerts")
    }
}
