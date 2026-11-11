import SwiftUI
import SwiftData

/// iPhone companion. Shares its models and logic with the Mac app (same files, both targets)
/// and syncs through the same iCloud container.
@main
struct FinanceiOSApp: App {
    var container: ModelContainer = {
        let schema = Schema([
            Account.self, TransactionRecord.self, Envelope.self, RecurringBill.self,
            OFXProfile.self, CategoryRule.self, CustomCategory.self,
        ])
        // Same switch as the Mac app: add a "FinanceCloudContainer" string to this target's Info
        // (e.g. iCloud.com.blakey.finance). Empty or missing keeps the data on this phone only.
        let cloudID = (Bundle.main.object(forInfoDictionaryKey: "FinanceCloudContainer") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false,
                                        cloudKitDatabase: cloudID.isEmpty ? .none : .private(cloudID))
        do { return try ModelContainer(for: schema, configurations: [config]) }
        catch { fatalError("Could not create ModelContainer: \(error)") }
    }()

    var body: some Scene {
        WindowGroup { RootView() }
            .modelContainer(container)
    }
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
            // The Mac app owns the category list (it seeds the defaults); the phone must not
            // seed its own copy or it would bring back categories you renamed or deleted.
            DedupeService.run(in: context)
            ScheduleService.ensureTracking(in: context)
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
