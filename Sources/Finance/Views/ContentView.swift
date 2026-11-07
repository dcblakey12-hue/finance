import SwiftUI
import SwiftData

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", accounts = "Accounts", transactions = "Transactions",
         budget = "Budget", scheduled = "Scheduled Transactions", calendar = "Bills & Calendar", forecast = "Cash Flow Forecast", importData = "Import & Sync", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .accounts: return "building.columns"
        case .transactions: return "list.bullet"
        case .budget: return "envelope"
        case .scheduled: return "calendar.badge.clock"
        case .calendar: return "calendar"
        case .forecast: return "chart.line.uptrend.xyaxis"
        case .importData: return "square.and.arrow.down.on.square"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @State private var selection: AppSection? = .dashboard
    /// OFX accountId shown in Transactions; nil = all accounts.
    @State private var transactionFilters = TransactionFilters()
    /// True while a double-click drill-down is switching to Transactions, so the
    /// filters it set aren't cleared by the sidebar-navigation reset below.
    @State private var isDrillDown = false
    /// Screen to return to via the Back button after a drill-down; nil when opened from the sidebar.
    @State private var returnTo: AppSection?
    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationTitle("Finance")
        } detail: {
            if let sel = selection {
                switch sel {
                case .dashboard:
                    DashboardView(
                        onOpenAccount: { openTransactions(TransactionFilters(accountId: $0)) },
                        onOpenCategory: { openTransactions(TransactionFilters(category: $0, period: $1)) })
                case .accounts:
                    AccountsView(onOpenTransactions: { openTransactions(TransactionFilters(accountId: $0)) })
                case .transactions:
                    TransactionsView(filters: $transactionFilters,
                                     backLabel: returnTo?.rawValue,
                                     onBack: { if let r = returnTo { selection = r } })
                case .budget: BudgetView(onOpenTransactions: { openTransactions($0) })
                case .scheduled: ScheduledView()
                case .calendar: CalendarView()
                case .forecast: ForecastView()
                case .importData: ImportView()
                case .settings: SettingsView()
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            CategoryService.seedIfNeeded(in: context)
            DedupeService.run(in: context)
        }
        .onChange(of: selection) { _, new in
            // Opening Transactions from the sidebar starts unfiltered; a drill-down keeps its filters.
            if new == .transactions && !isDrillDown {
                transactionFilters = TransactionFilters()
            }
            if new != .transactions || !isDrillDown { returnTo = nil }
            isDrillDown = false
        }
    }

    /// Jump to Transactions with the given filters.
    private func openTransactions(_ filters: TransactionFilters) {
        transactionFilters = filters
        isDrillDown = true
        returnTo = selection
        selection = .transactions
    }
}
