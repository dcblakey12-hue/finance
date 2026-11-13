import SwiftUI
import SwiftData

/// iPhone companion. Shares its models and logic with the Mac app (same files, both targets)
/// and syncs through the same iCloud container.
@main
struct FinanceiOSApp: App {
    /// Demo mode switch, saved on this phone. Flipping it swaps which data file the app shows;
    /// your real data stays where it is.
    @AppStorage(DemoMode.flagKey, store: .standard) private var demo = false
    private let stores = Stores()

    var body: some Scene {
        WindowGroup {
            if demo {
                RootView().id("demo")
                    .modelContainer(stores.demo)
                    .defaultAppStorage(DemoMode.defaults)
            } else {
                RootView().id("real")
                    .modelContainer(stores.real)
            }
        }
    }
}

/// The phone's two data files, each opened only when first shown.
final class Stores {
    static let schema = Schema([
        Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
        OFXProfile.self, CategoryRule.self, CustomCategory.self, SubscriptionMark.self, DismissedAlert.self, SavingsGoal.self,
    ])

    /// Your data. Same switch as the Mac app: a "FinanceCloudContainer" string in this target's Info
    /// (e.g. iCloud.com.blakey.finance) syncs it; empty or missing keeps it on this phone only.
    lazy var real: ModelContainer = {
        let cloudID = (Bundle.main.object(forInfoDictionaryKey: "FinanceCloudContainer") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let config = ModelConfiguration(schema: Self.schema, isStoredInMemoryOnly: false,
                                        cloudKitDatabase: cloudID.isEmpty ? .none : .private(cloudID))
        do { return try ModelContainer(for: Self.schema, configurations: [config]) }
        catch { fatalError("Could not create ModelContainer: \(error)") }
    }()

    /// The made-up household, in its own file and its own iCloud container (see DemoMode).
    lazy var demo: ModelContainer = {
        do { return try DemoMode.makeContainer(schema: Self.schema) }
        catch { fatalError("Could not create the demo ModelContainer: \(error)") }
    }()
}

enum AppTab: String, CaseIterable, Identifiable {
    case overview, accounts, transactions, calendar, scheduled
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .accounts: return "Accounts"
        case .transactions: return "Transactions"
        case .calendar: return "Calendar"
        case .scheduled: return "Scheduled"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .accounts: return "building.columns"
        case .transactions: return "list.bullet"
        case .calendar: return "calendar"
        case .scheduled: return "calendar.badge.clock"
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query private var schedules: [RecurringBill]
    @Query private var accounts: [Account]
    @AppStorage(DemoMode.flagKey, store: .standard) private var demo = false
    @State private var confirmingLeave = false
    /// Your tab order, saved on this phone (comma separated AppTab names).
    @AppStorage("tabOrder") private var tabOrderRaw = ""
    @State private var selected: AppTab = .overview
    @State private var reordering = false

    private var order: [AppTab] {
        let saved = tabOrderRaw.split(separator: ",").compactMap { AppTab(rawValue: String($0)) }
        var seen = Set<AppTab>(), out: [AppTab] = []
        for t in saved where !seen.contains(t) { seen.insert(t); out.append(t) }
        for t in AppTab.allCases where !seen.contains(t) { out.append(t) }
        return out
    }

    @ViewBuilder
    private func content(_ tab: AppTab) -> some View {
        switch tab {
        case .overview: OverviewTab(onReorderTabs: { reordering = true })
        case .accounts: AccountsTab()
        case .transactions: TransactionsTab()
        case .calendar: CalendarTab()
        case .scheduled: ScheduledTab()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if demo { demoBar }
            tabs
        }
        .billReminders()
        .spendingAlerts()
        .confirmationDialog("Leave the demo?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Leave Demo") { demo = false }
        } message: {
            Text("Finance will go back to your own data. Nothing from the demo is added to it.")
        }
    }

    /// Always on screen in demo mode, so it's clear the numbers are made up and how to get back.
    private var demoBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Demo data", systemImage: "theatermasks.fill").font(.subheadline.bold())
                Spacer()
                Button("Leave") { confirmingLeave = true }
                    .font(.subheadline.bold()).buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.orange)
                    .controlSize(.small)
            }
            if accounts.isEmpty {
                Text(DemoMode.isShared
                     ? "Waiting for the demo from your Mac. Turn it on there with File ▸ Show Demo Data…, then give it a minute with this app open."
                     : "Loading the demo…")
                    .font(.caption)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.orange)
    }

    private var tabs: some View {
        TabView(selection: $selected) {
            ForEach(order) { tab in
                content(tab)
                    .tabItem { Label(tab.title, systemImage: tab.icon) }
                    .badge(tab == .scheduled ? ScheduleService.overdue(schedules).count : 0)
                    .tag(tab)
            }
        }
        .sheet(isPresented: $reordering) {
            TabOrderSheet(order: order) { tabOrderRaw = $0.map(\.rawValue).joined(separator: ",") }
        }
        .task {
            DemoMode.prepare(in: context)
            // The Mac app owns the category list (it seeds the defaults); the phone must not
            // seed its own copy or it would bring back categories you renamed or deleted.
            DedupeService.run(in: context)
            ScheduleService.ensureTracking(in: context)
            ScheduleService.reconcileRecent(in: context)   // payments that arrived early or late
        }
    }
}

/// Drag the handles to put the tabs in the order you want.
struct TabOrderSheet: View {
    @State var order: [AppTab]
    let onSave: ([AppTab]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(order) { Label($0.title, systemImage: $0.icon) }
                    .onMove { order.move(fromOffsets: $0, toOffset: $1); onSave(order) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Tab Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

/// Category names for pickers: the user's own plus the reserved ones.
func allCategoryChoices(_ custom: [CustomCategory]) -> [String] {
    BudgetService.allCategories(stored: custom.map(\.name)) + ["Income", Categorizer.transfer, Categorizer.uncategorized]
}
