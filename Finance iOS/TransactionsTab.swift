import SwiftUI
import SwiftData

/// Transaction list. Used as a tab (all accounts) or pushed from an account (accountId set).
struct TransactionsTab: View {
    var accountId: String? = nil
    var title: String = "Transactions"

    @Query(sort: \TransactionRecord.date, order: .reverse) private var transactions: [TransactionRecord]
    @Query private var customCategories: [CustomCategory]
    @Query(sort: \Account.name) private var accounts: [Account]
    @Environment(\.modelContext) private var context
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var search = ""
    @State private var accountFilter: String?     // used only when not pushed from an account
    @State private var categoryFilter = "All"
    @State private var adding = false
    /// Show only entries the bank hasn't reported yet.
    @State private var outstandingOnly = false
    @State private var editing: TransactionRecord?

    private var effectiveAccount: String? { accountId ?? accountFilter }
    private var rows: [TransactionRecord] {
        transactions.filter { t in
            if let a = effectiveAccount, t.accountId != a { return false }
            if categoryFilter != "All", t.category != categoryFilter { return false }
            if !search.isEmpty, !t.name.localizedCaseInsensitiveContains(search) { return false }
            if outstandingOnly, !t.isOutstanding { return false }
            return true
        }
    }
    /// Phone on its side: there's room for a running balance down the right.
    private var landscape: Bool { verticalSizeClass == .compact }
    /// Transactions in the chosen account(s), ignoring search/category so balances stay right while filtering.
    private var inScope: [TransactionRecord] {
        effectiveAccount == nil ? transactions : transactions.filter { $0.accountId == effectiveAccount }
    }
    private var endingBalance: Double {
        effectiveAccount == nil ? accounts.filter { !$0.type.isPropertyValue }.reduce(0) { $0 + $1.balance }
                                : (accounts.first { $0.accountId == effectiveAccount }?.balance ?? 0)
    }
    private var runningBalances: [UUID: Double] {
        landscape ? RunningBalance.compute(newestFirst: inScope.map { ($0.id, $0.amount) }, endingBalance: endingBalance) : [:]
    }
    /// Reconciled and outstanding balances for the account (or all accounts).
    private var reconciliation: ReconciliationSummary {
        ReconciliationService.summary(for: effectiveAccount == nil ? accounts : accounts.filter { $0.accountId == effectiveAccount },
                                      transactions: transactions)
    }
    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }

    var body: some View {
        if accountId == nil { NavigationStack { content } } else { content }
    }

    private var content: some View {
        List {
            let balances = runningBalances
            Section { ReconciliationSection(summary: reconciliation, outstandingOnly: $outstandingOnly) }
            Section {
            ForEach(rows.prefix(500)) { t in
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        ReconciliationMarker(transaction: t).font(.caption)
                        Text(t.name).lineLimit(1)
                        if t.wasEdited { Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary) }
                        if ManualTransactionService.isManual(t) {
                            Text("manual").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(money(t.amount)).monospacedDigit().foregroundStyle(t.amount < 0 ? Color.primary : .green)
                    }
                    HStack {
                        Text(t.date, format: .dateTime.month(.abbreviated).day().year())
                        if accountId == nil { Text("• \(t.accountName)") }
                        Spacer()
                        categoryMenu(for: t)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if landscape, let bal = balances[t.id] {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(money(bal)).monospacedDigit().font(.callout.weight(.semibold))
                            .foregroundStyle(bal < 0 ? .red : .primary)
                        Text("balance").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: 110, alignment: .trailing)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { editing = t }
            .swipeActions(edge: .leading) {
                Button { editing = t } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
                // Hand-entered entries can be ticked off against the bank (or unticked).
                if ReconciliationService.canToggle(t) {
                    Button { ReconciliationService.setReconciled(t, !t.isReconciled, in: context) } label: {
                        Label(t.isReconciled ? "Outstanding" : "Reconciled",
                              systemImage: t.isReconciled ? "circle.dashed" : "checkmark.circle")
                    }
                    .tint(t.isReconciled ? .orange : .green)
                }
            }
            }
            .onDelete { idx in
                // Only hand-entered transactions can be deleted; imported ones come from the bank.
                let shown = Array(rows.prefix(500))
                for i in idx { ManualTransactionService.delete(shown[i], from: accounts, in: context) }
            }
            }
        }
        .navigationTitle(title)
        .searchable(text: $search)
        .sheet(item: $editing) { t in
            EditTransactionSheet(tx: t, accounts: accounts, categories: allCategoryChoices(customCategories))
        }
        .sheet(isPresented: $adding) {
            AddTransactionSheet(accounts: accounts, preselected: accountId, categories: allCategoryChoices(customCategories))
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .disabled(accounts.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if accountId == nil {
                        Picker("Account", selection: $accountFilter) {
                            Text("All accounts").tag(String?.none)
                            ForEach(accounts) { Text($0.name).tag(Optional($0.accountId)) }
                        }
                    }
                    Toggle("Outstanding only", isOn: $outstandingOnly)
                    Picker("Category", selection: $categoryFilter) {
                        Text("All categories").tag("All")
                        ForEach(allCategoryChoices(customCategories), id: \.self) { Text($0).tag($0) }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            }
        }
        .overlay {
            if inScope.isEmpty { ContentUnavailableView("No transactions", systemImage: "list.bullet") }
        }
    }

    private func categoryMenu(for t: TransactionRecord) -> some View {
        Menu {
            ForEach(allCategoryChoices(customCategories), id: \.self) { c in
                Button(c) { set(c, on: t) }
            }
        } label: {
            Text(t.category).padding(.horizontal, 8).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }

    /// Same behavior as the Mac app: remember the merchant and update look-alikes.
    private func set(_ category: String, on t: TransactionRecord) {
        guard category != t.category else { return }
        if t.transferPeerId != nil && category != Categorizer.transfer {
            TransferLinkService.detach(t, among: transactions)
        }
        CategorizationService.learn(from: t, category: category, in: context)
    }
}


struct AddTransactionSheet: View {
    let accounts: [Account]
    let preselected: String?
    let categories: [String]

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var accountId: String?
    @State private var isIncome = false
    @State private var amountText = ""
    @State private var name = ""
    @State private var date = Date()
    @State private var category = Categorizer.uncategorized
    @State private var note = ""

    private var amount: Double { Double(amountText.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")) ?? 0 }
    private var canSave: Bool { accountId != nil && amount > 0 && !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Account", selection: $accountId) {
                    ForEach(accounts) { Text($0.name).tag(Optional($0.accountId)) }
                }
                Picker("Type", selection: $isIncome) {
                    Text("Expense").tag(false); Text("Income / deposit").tag(true)
                }.pickerStyle(.segmented)
                TextField("Payee or description", text: $name)
                TextField("Amount", text: $amountText).keyboardType(.decimalPad)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Picker("Category", selection: $category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
                TextField("Note (optional)", text: $note)
                Text("The account balance moves now. When the bank's own record of this arrives in an import, it replaces this entry.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Add Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let id = accountId, let account = accounts.first(where: { $0.accountId == id }) else { return }
                        let signed = isIncome ? amount : -amount
                        // Leave the category to auto-detect unless the user picked one.
                        ManualTransactionService.add(to: account, date: date, name: name, amount: signed,
                                                     category: category == Categorizer.uncategorized ? nil : category,
                                                     memo: note, in: context)
                        dismiss()
                    }.disabled(!canSave)
                }
            }
        }
        .onAppear { accountId = accountId ?? preselected ?? accounts.first?.accountId }
    }
}

/// Top of the transaction list: what the bank should show, what's outstanding, and the balance with it.
private struct ReconciliationSection: View {
    let summary: ReconciliationSummary
    @Binding var outstandingOnly: Bool

    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }

    var body: some View {
        LabeledContent("Reconciled balance") {
            Text(money(summary.reconciledBalance)).monospacedDigit().fontWeight(.semibold)
        }
        Button { outstandingOnly.toggle() } label: {
            LabeledContent {
                Text(money(summary.outstandingTotal)).monospacedDigit()
                    .foregroundStyle(summary.hasOutstanding ? Color.orange : Color.secondary)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "circle.dashed").foregroundStyle(summary.hasOutstanding ? Color.orange : Color.secondary)
                    Text(summary.outstandingCount == 1 ? "1 outstanding" : "\(summary.outstandingCount) outstanding")
                    if outstandingOnly { Text("· showing only these").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .disabled(!summary.hasOutstanding && !outstandingOnly)
        .tint(.primary)
        LabeledContent("Unreconciled balance") {
            Text(money(summary.balance)).monospacedDigit()
        }
    }
}

/// Change a transaction's date, payee, amount, category, account and notes. Same rules as on the Mac.
struct EditTransactionSheet: View {
    let tx: TransactionRecord
    let accounts: [Account]
    let categories: [String]

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var edit: TransactionEdit
    @State private var isIncome: Bool
    @State private var amountText: String

    init(tx: TransactionRecord, accounts: [Account], categories: [String]) {
        self.tx = tx; self.accounts = accounts; self.categories = categories
        _edit = State(initialValue: TransactionEdit(tx))
        _isIncome = State(initialValue: tx.amount > 0)
        _amountText = State(initialValue: TransactionAmountText.format(abs(tx.amount)))
    }

    private var magnitude: Double? { TransactionAmountText.parse(amountText) }
    private var canSave: Bool { (magnitude ?? 0) > 0 && !edit.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $edit.date, displayedComponents: .date)
                TextField("Payee or description", text: $edit.name)
                Picker("Type", selection: $isIncome) {
                    Text("Expense").tag(false); Text("Income / deposit").tag(true)
                }.pickerStyle(.segmented)
                TextField("Amount", text: $amountText).keyboardType(.decimalPad)
                Picker("Category", selection: $edit.category) {
                    ForEach(categories.contains(edit.category) ? categories : categories + [edit.category], id: \.self) { Text($0).tag($0) }
                }
                Picker("Account", selection: $edit.accountId) {
                    ForEach(accounts) { Text($0.name).tag($0.accountId) }
                }
                TextField("Note (optional)", text: $edit.memo, axis: .vertical)
                Text(TransactionEditNotes.text(for: tx)).font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var e = edit
                        e.amount = (isIncome ? 1 : -1) * (magnitude ?? abs(tx.amount))
                        TransactionEditService.apply(e, to: tx, accounts: accounts, in: context)
                        dismiss()
                    }.disabled(!canSave)
                }
            }
        }
    }
}
