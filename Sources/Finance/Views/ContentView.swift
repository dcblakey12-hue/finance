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

let currency: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .currency; f.locale = .current; return f
}()

struct ContentView: View {
    @State private var selection: AppSection? = .dashboard
    /// OFX accountId shown in Transactions; nil = all accounts.
    @State private var transactionsAccount: String?
    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationTitle("Finance")
        } detail: {
            if let sel = selection {
                switch sel {
                case .dashboard: DashboardView()
                case .accounts:
                    AccountsView(onOpenTransactions: { acctId in
                        transactionsAccount = acctId
                        selection = .transactions
                    })
                case .transactions: TransactionsView(accountFilter: $transactionsAccount)
                case .budget: BudgetView()
                case .scheduled: ScheduledView()
                case .calendar: CalendarView()
                case .forecast: ForecastView()
                case .importData: ImportView()
                case .settings: SettingsView()
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
