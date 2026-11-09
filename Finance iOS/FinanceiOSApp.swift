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

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query private var schedules: [RecurringBill]

    var body: some View {
        TabView {
            OverviewTab()
                .tabItem { Label("Overview", systemImage: "gauge.with.dots.needle.67percent") }
            AccountsTab()
                .tabItem { Label("Accounts", systemImage: "building.columns") }
            TransactionsTab()
                .tabItem { Label("Transactions", systemImage: "list.bullet") }
            CalendarTab()
                .tabItem { Label("Calendar", systemImage: "calendar") }
            ScheduledTab()
                .tabItem { Label("Scheduled", systemImage: "calendar.badge.clock") }
                .badge(ScheduleService.overdue(schedules).count)
        }
        .task {
            // The Mac app owns the category list (it seeds the defaults); the phone must not
            // seed its own copy or it would bring back categories you renamed or deleted.
            DedupeService.run(in: context)
            ScheduleService.ensureTracking(in: context)
        }
    }
}

/// Category names for pickers: the user's own plus the reserved ones.
func allCategoryChoices(_ custom: [CustomCategory]) -> [String] {
    BudgetService.allCategories(stored: custom.map(\.name)) + ["Income", Categorizer.transfer, Categorizer.uncategorized]
}
