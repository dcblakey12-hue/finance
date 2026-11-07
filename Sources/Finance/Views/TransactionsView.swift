import SwiftUI
import SwiftData

struct TransactionsView: View {
    @Query(sort: \TransactionRecord.date, order: .reverse) var transactions: [TransactionRecord]
    @Query(sort: \Account.name) var accounts: [Account]
    @Query var customCategories: [CustomCategory]
    @Environment(\.modelContext) private var context
    /// Active filters. Owned by ContentView so other screens can open Transactions pre-filtered.
    @Binding var filters: TransactionFilters
    /// Set when the user arrived by double-clicking from another screen; shows a Back button.
    var backLabel: String? = nil
    var onBack: () -> Void = {}
    @State private var search = ""
    @State private var status: String?
    @State private var scheduleEditor: ScheduleEditor?
    /// Transaction waiting for a newly created category.
    @State private var newCategoryFor: TransactionRecord?
    /// Transaction we're choosing a transfer partner for.
    @State private var linkingTx: TransactionRecord?
    /// Rows picked for bulk actions (Select All is Cmd-A in the list, or the button below).
    @State private var selection = Set<UUID>()
    @State private var confirmingDelete = false

    var filtered: [TransactionRecord] {
        transactions.filter { t in
            filters.matches(accountId: t.accountId, category: t.category, date: t.date, amount: t.amount) &&
            (search.isEmpty || t.name.localizedCaseInsensitiveContains(search) || t.memo.localizedCaseInsensitiveContains(search))
        }
    }
    /// Transactions in the selected account(s), ignoring search and category
    /// filters so the running balance stays correct while filtering.
    private var inScope: [TransactionRecord] {
        filters.accountId == nil ? transactions : transactions.filter { $0.accountId == filters.accountId }
    }
    /// Current balance the newest transaction should end at: the selected
    /// account's balance, or all accounts combined.
    private var endingBalance: Double {
        filters.accountId == nil ? accounts.reduce(0) { $0 + $1.balance }
                             : (accounts.first { $0.accountId == filters.accountId }?.balance ?? 0)
    }
    private var balances: [UUID: Double] {
        RunningBalance.compute(newestFirst: inScope.map { ($0.id, $0.amount) }, endingBalance: endingBalance)
    }
    private var shownNet: Double { filtered.reduce(0) { $0 + $1.amount } }

    /// Picker tag for the "New Category…" row; never stored as a real category.
    private static let newCategoryChoice = "\u{0}new-category"

    /// Categories in use, for the filter menu.
    var usedCategories: [String] { Array(Set(transactions.map { $0.category })).sorted() }
    /// Every category a transaction can be set to.
    var assignableCategories: [String] {
        BudgetService.allCategories(stored: customCategories.map(\.name)) + ["Income", Categorizer.transfer, Categorizer.uncategorized]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Account", selection: $filters.accountId) {
                    Text("All accounts").tag(String?.none)
                    ForEach(accounts) { a in Text(a.name).tag(String?.some(a.accountId)) }
                }
                .frame(maxWidth: 220)
                Picker("Period", selection: $filters.period) {
                    ForEach(DashboardPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(maxWidth: 170)
                TextField("Search transactions", text: $search).textFieldStyle(.roundedBorder)
                Picker("Category", selection: $filters.category) {
                    Text("All").tag("All")
                    ForEach(Array(Set(usedCategories + [filters.category]).subtracting(["All"])).sorted(), id: \.self) { c in Text(c).tag(c) }
                }
                Button("Auto-categorize") {
                    let n = CategorizationService.categorizeUncategorized(in: context)
                    status = n == 0 ? "No uncategorized transactions matched a rule." : "Categorized \(n) transaction\(n == 1 ? "" : "s")."
                }
                .help("Apply learned merchant rules and built-in keywords to uncategorized transactions")
                Button("Find Transfers") {
                    let r = CategorizationService.markTransfers(in: context)
                    if r.linked > 0 {
                        status = "Linked \(r.linked) transfer\(r.linked == 1 ? "" : "s") between your accounts."
                    } else if r.lookalikes > 0 {
                        status = "No new transfers. \(r.lookalikes) equal-and-opposite pair\(r.lookalikes == 1 ? "" : "s") already have a category or are more than 5 days apart. Set one side to Transfer yourself and the app will remember that merchant."
                    } else {
                        status = "No transfers found among \(r.checked) uncategorized transactions. A transfer needs equal and opposite amounts in two different accounts within 5 days."
                    }
                }
                .help("Match equal and opposite amounts in different accounts within 5 days and mark them as Transfer")
            }.padding()
            if filters.month != nil || filters.flow != .all || filters.accountIds != nil {
                HStack(spacing: 8) {
                    if let m = filters.month { chip(Self.monthLabel(m)) { filters.month = nil } }
                    if filters.flow != .all { chip(filters.flow.rawValue) { filters.flow = .all } }
                    if filters.accountIds != nil { chip("Checking accounts only") { filters.accountIds = nil } }
                    Spacer()
                }
                .padding(.horizontal).padding(.bottom, 6)
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.bottom, 6)
            }
            let runningBalances = balances
            let byId = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
            List(filtered, selection: $selection) { tx in
                HStack {
                    Text(tx.date, format: .dateTime.month(.abbreviated).day().year())
                        .monospacedDigit()
                        .frame(width: 100, alignment: .leading)
                    VStack(alignment: .leading) {
                        Text(tx.name).font(.headline)
                        Text(accountLine(tx, byId)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Category", selection: Binding(
                        get: { tx.category },
                        set: { choice in
                            if choice == Self.newCategoryChoice { newCategoryFor = tx }
                            else { setCategory(choice, on: tx) }
                        }
                    )) {
                        ForEach(Array(Set(assignableCategories + [tx.category])).sorted(), id: \.self) { c in Text(c).tag(c) }
                        Divider()
                        Text("New Category…").tag(Self.newCategoryChoice)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Text(currency.string(from: NSNumber(value: tx.amount)) ?? "$0")
                        .foregroundStyle(tx.isExpense ? .red : .green)
                        .monospacedDigit()
                        .frame(width: 100, alignment: .trailing)
                    Text(runningBalances[tx.id].flatMap { currency.string(from: NSNumber(value: $0)) } ?? "")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 110, alignment: .trailing)
                        .help("Running balance after this transaction")
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Schedule as Recurring…") {
                        // A linked transfer pre-fills the From/To accounts.
                        let peer = tx.transferPeerId.flatMap { byId[$0] }
                        let out = tx.amount < 0 ? tx : peer, into = tx.amount < 0 ? peer : tx
                        scheduleEditor = ScheduleEditor(existing: nil, draft: ScheduleService.draft(
                            fromName: tx.name, amount: tx.amount, date: tx.date, category: tx.category,
                            accountId: tx.accountId,
                            transferFrom: peer == nil ? nil : out?.accountId,
                            transferTo: peer == nil ? nil : into?.accountId))
                    }
                    Divider()
                    if let pid = tx.transferPeerId {
                        if let peer = byId[pid] {
                            Button("Show Other Side of Transfer") { showOtherSide(peer) }
                        }
                        Button("Unlink Transfer") {
                            TransferLinkService.unlink(tx, in: context)
                            status = "Unlinked. Both sides are Uncategorized again."
                        }
                    } else {
                        Button("Link to Matching Transaction…") { linkingTx = tx }
                    }
                    Divider()
                    Button(selection.contains(tx.id) && selection.count > 1 ? "Delete \(selection.count) Transactions…" : "Delete Transaction…", role: .destructive) {
                        if !selection.contains(tx.id) { selection = [tx.id] }
                        confirmingDelete = true
                    }
                }
            }
            .onDeleteCommand { if !selection.isEmpty { confirmingDelete = true } }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 16) {
                Text("\(filtered.count) transaction\(filtered.count == 1 ? "" : "s")")
                Button("Select All") { selection = Set(filtered.map(\.id)) }
                    .disabled(filtered.isEmpty)
                    .help("Select every transaction shown (Cmd-A also works in the list)")
                if !selection.isEmpty {
                    Text("\(selection.count) selected").foregroundStyle(.secondary)
                    Button("Clear") { selection = [] }
                    Button("Delete…", role: .destructive) { confirmingDelete = true }
                }
                Spacer()
                HStack(spacing: 4) {
                    Text("Net shown:").foregroundStyle(.secondary)
                    Text(currency.string(from: NSNumber(value: shownNet)) ?? "")
                        .foregroundStyle(shownNet < 0 ? Color.red : Color.green)
                }
                HStack(spacing: 4) {
                    Text("Balance:").foregroundStyle(.secondary)
                    Text(currency.string(from: NSNumber(value: endingBalance)) ?? "")
                }
            }
            .font(.callout.monospacedDigit())
            .padding(.horizontal).padding(.vertical, 6)
            .background(.bar)
        }
        .navigationTitle(accounts.first { $0.accountId == filters.accountId }?.name ?? "Transactions")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if let backLabel {
                    Button(action: onBack) { Label("Back to \(backLabel)", systemImage: "chevron.left") }
                        .help("Return to \(backLabel)")
                }
            }
        }
        .confirmationDialog("Delete \(selection.count) transaction\(selection.count == 1 ? "" : "s")?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let chosen = transactions.filter { selection.contains($0.id) }
                // Bank-synced rows only come back if the next sync starts from scratch.
                if chosen.contains(where: { $0.fitid.hasPrefix(PlaidMapping.prefix) }) { PlaidStore.resetCursors() }
                let n = TransactionDeletionService.delete(chosen, accounts: accounts, all: transactions, in: context)
                selection = []
                status = "Deleted \(n) transaction\(n == 1 ? "" : "s"). Bank-synced ones come back on the next Sync Now."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They are removed from this Mac and, with iCloud sync, from your iPhone. This can't be undone, so use File ▸ Back Up Data first if you're unsure.")
        }
        .sheet(item: $scheduleEditor) { ed in
            ScheduleEditorSheet(editor: ed, categories: BudgetService.allCategories(stored: customCategories.map(\.name)),
                                accounts: accounts.map { AccountChoice(id: $0.accountId, name: $0.name) }) { draft in
                ScheduleEditor.save(draft, existing: nil, in: context)
                scheduleEditor = nil
                status = "Scheduled \(draft.name): \(draft.rule.summary()). See Scheduled Transactions."
            } onCancel: { scheduleEditor = nil }
        }
        .sheet(item: $linkingTx) { tx in
            TransferLinkSheet(source: tx, candidates: linkCandidates(for: tx)) { other in
                TransferLinkService.link(tx, other, in: context)
                linkingTx = nil
                status = "Linked to \(other.accountName) as a transfer."
            } onCancel: { linkingTx = nil }
        }
        .sheet(item: $newCategoryFor) { tx in
            NewCategorySheet(existing: BudgetService.allCategories(stored: customCategories.map(\.name))) { name in
                newCategoryFor = nil
                setCategory(name, on: tx)
            } onCancel: { newCategoryFor = nil }
        }
    }

    private func chip(_ title: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) { Label(title, systemImage: "xmark.circle.fill") }
            .buttonStyle(.bordered).controlSize(.small)
            .help("Remove this filter")
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()
    private static func monthLabel(_ d: Date) -> String { monthFormatter.string(from: d) }

    private func accountLine(_ tx: TransactionRecord, _ byId: [UUID: TransactionRecord]) -> String {
        guard let pid = tx.transferPeerId, let peer = byId[pid] else { return tx.accountName }
        return tx.amount < 0 ? "\(tx.accountName) — Transfer → \(peer.accountName)"
                             : "\(tx.accountName) — Transfer ← \(peer.accountName)"
    }

    private func showOtherSide(_ peer: TransactionRecord) {
        filters = TransactionFilters(accountId: peer.accountId, month: peer.date)
        search = peer.name
        status = "Showing the other side of the transfer in \(peer.accountName)."
    }

    private func linkCandidates(for tx: TransactionRecord) -> [TransactionRecord] {
        func cand(_ t: TransactionRecord) -> TransferDetector.Candidate {
            .init(id: t.id, accountId: t.accountId, amount: t.amount, date: t.date)
        }
        let pool = transactions.filter { $0.transferPeerId == nil }
        let byId = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0) })
        return TransferDetector.candidates(for: cand(tx), among: pool.map(cand)).compactMap { byId[$0] }
    }

    private func setCategory(_ newCat: String, on tx: TransactionRecord) {
        guard newCat != tx.category else { return }
        // Moving a linked transfer to another category breaks the link (the other side keeps Transfer).
        if tx.transferPeerId != nil && newCat != Categorizer.transfer {
            TransferLinkService.detach(tx, among: transactions)
        }
        let n = CategorizationService.learn(from: tx, category: newCat, in: context)
        guard newCat != Categorizer.uncategorized else { return }
        let merchant = MerchantNormalizer.key(for: tx.name)
        status = n > 0
            ? "Remembered \(merchant) → \(newCat) and updated \(n) other transaction\(n == 1 ? "" : "s")."
            : "Remembered \(merchant) → \(newCat) for future imports."
    }

    private func ordinalSuffix(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "th" }
        switch n % 10 { case 1: return "st"; case 2: return "nd"; case 3: return "rd"; default: return "th" }
    }
}

// MARK: - Manual transfer linking

struct TransferLinkSheet: View {
    let source: TransactionRecord
    let candidates: [TransactionRecord]
    let onLink: (TransactionRecord) -> Void
    let onCancel: () -> Void

    @State private var selection: UUID?

    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link transfer").font(.headline)
            Text("\(source.name) • \(money(source.amount)) • \(source.date.formatted(date: .abbreviated, time: .omitted)) • \(source.accountName)")
                .font(.callout).foregroundStyle(.secondary)
            if candidates.isEmpty {
                Text("No unlinked transactions in other accounts with the opposite sign within 10 days.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Pick the other side. Closest amounts and dates are first. Double-click to link.")
                    .font(.caption).foregroundStyle(.secondary)
                List(candidates, selection: $selection) { c in
                    HStack {
                        Text(c.date, format: .dateTime.month(.abbreviated).day().year()).frame(width: 100, alignment: .leading)
                        VStack(alignment: .leading) {
                            Text(c.name)
                            Text(c.accountName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(money(c.amount)).monospacedDigit()
                    }
                    .tag(c.id)
                }
                .frame(height: 260)
                .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
                    if let c = candidates.first(where: { ids.contains($0.id) }) { onLink(c) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Link") {
                    if let c = candidates.first(where: { $0.id == selection }) { onLink(c) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}
