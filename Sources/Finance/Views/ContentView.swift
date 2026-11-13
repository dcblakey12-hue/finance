import SwiftUI
import SwiftData

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", accounts = "Accounts", transactions = "Transactions",
         budget = "Budget", scheduled = "Scheduled Transactions", subscriptions = "Subscriptions", goals = "Savings Goals", calendar = "Bills & Calendar", forecast = "Cash Flow Forecast", yearInReview = "Year in Review", reports = "Reports", importData = "Import & Sync", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .accounts: return "building.columns"
        case .transactions: return "list.bullet"
        case .budget: return "envelope"
        case .scheduled: return "calendar.badge.clock"
        case .subscriptions: return "repeat.circle"
        case .goals: return "target"
        case .calendar: return "calendar"
        case .forecast: return "chart.line.uptrend.xyaxis"
        case .yearInReview: return "sparkles.rectangle.stack"
        case .reports: return "doc.text.magnifyingglass"
        case .importData: return "square.and.arrow.down.on.square"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query private var schedules: [RecurringBill]
    @StateObject private var sync = SyncCoordinator()
    @StateObject private var cloud = CloudSyncMonitor()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppSection? = .dashboard
    /// OFX accountId shown in Transactions; nil = all accounts.
    @State private var transactionFilters = TransactionFilters()
    /// True while a double-click drill-down is switching to Transactions, so the
    /// filters it set aren't cleared by the sidebar-navigation reset below.
    @State private var isDrillDown = false
    /// Screen to return to via the Back button after a drill-down; nil when opened from the sidebar.
    @State private var returnTo: AppSection?
    @State private var showingSyncReport = false
    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { s in
                Label(s.rawValue, systemImage: s.icon)
                    .badge(s == .scheduled ? ScheduleService.overdue(schedules).count : 0)
                    .tag(s)   // tag last, or the badge wrapper can swallow the sidebar selection
            }
            .navigationTitle(DemoMode.isOn ? "Finance (Demo)" : "Finance")
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
                case .subscriptions: SubscriptionsView()
                case .goals: SavingsGoalsView()
                case .calendar: CalendarView()
                case .forecast: ForecastView(onOpenTransactions: { openTransactions($0) })
                case .yearInReview:
                    YearInReviewView(onOpenCategory: { category, year in
                        let now = Calendar.current.component(.year, from: Date())
                        let period: DashboardPeriod = year == now ? .thisYear : (year == now - 1 ? .lastYear : .allTime)
                        openTransactions(TransactionFilters(category: category, period: period))
                    })
                case .reports: ReportsView()
                case .importData: ImportView()
                case .settings: SettingsView()
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .billReminders()
        .spendingAlerts()
        .sheet(isPresented: $showingSyncReport) { PlaidSyncReportView() }
        .environmentObject(sync)
        .task {
            DemoMode.prepare(in: context)
            CategoryService.seedIfNeeded(in: context)
            DedupeService.run(in: context)
            ScheduleService.ensureTracking(in: context)
            ScheduleService.reconcileRecent(in: context)   // payments that arrived early or late
            sync.syncIfStale(in: context)      // sync automatically when the app opens
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                sync.syncIfStale(in: context)
                if !DemoMode.isOn || DemoMode.isShared { cloud.checkNow(context: context, nudge: false) }   // the system imports on activation; show it
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    if DemoMode.isOn {
                        Button { DemoMode.confirmAndSwitch() } label: {
                            Text("DEMO DATA").font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.orange.opacity(0.85))).foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .help(DemoMode.isShared
                              ? "Made-up data for showing the app, shared with your iPhone through a separate demo iCloud space. Your own data isn't touched. Click to go back to it."
                              : "Made-up data for showing the app, kept on this Mac. Your own data isn't touched. Click to go back to it.")
                    }
                    if !DemoMode.isOn || DemoMode.isShared {
                    Button { cloud.checkNow(context: context) } label: {
                        Image(systemName: cloud.symbol(receiving: cloud.checking))
                            .foregroundStyle(cloud.hasProblem ? Color.orange : (cloud.checking ? Color.accentColor : Color.secondary))
                            .symbolEffect(.pulse, isActive: cloud.checking || cloud.working)
                    }
                    .buttonStyle(.borderless)
                    .help(cloud.summary + " Click to check iCloud for changes now.")
                    }
                    if sync.busy { ProgressView().controlSize(.small) }
                    else if !sync.status.isEmpty {
                        Button { showingSyncReport = true } label: {
                            Text(sync.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 360)
                        }
                        .buttonStyle(.plain)
                        .help("Click to see what the bank sync brought down")
                    }
                    Button { sync.syncAll(in: context) } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(sync.busy || !sync.hasBanks)
                        .keyboardShortcut("r", modifiers: .command)
                        .help(sync.hasBanks ? "Sync your connected banks now (⌘R)" : "Connect a bank in Settings first")
                }
            }
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
