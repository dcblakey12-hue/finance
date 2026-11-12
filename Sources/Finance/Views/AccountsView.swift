import SwiftUI
import SwiftData
import AppKit

struct AccountsView: View {
    @Query(sort: \Account.name) var accounts: [Account]
    @Query var transactions: [TransactionRecord]
    private var book: BalanceBook { BalanceBook(transactions: transactions) }
    @Environment(\.modelContext) private var context

    /// Called with an account's OFX `accountId` to show its transactions.
    var onOpenTransactions: (String) -> Void = { _ in }

    @State private var selection = Set<UUID>()
    @State private var editor: AccountEditor?
    @State private var pendingDelete: Account?

    var body: some View {
        List(selection: $selection) {
            ForEach(AccountType.grouped(accounts, by: \.type), id: \.type) { group in
                Section {
                    ForEach(group.items) { a in
                        HStack {
                            Image(systemName: icon(for: a.type)).foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(a.name).font(.headline)
                                Text("\(a.bankName) •••\(a.accountId.suffix(4))").font(.caption).foregroundStyle(.secondary)
                                if !a.countsInCashFlow {
                                    Text("Not in spending or cash flow").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(currency.string(from: NSNumber(value: book.today(a))) ?? "$0").monospacedDigit()
                        }
                        .padding(.vertical, 4)
                        .tag(a.id)
                    }
                } header: {
                    HStack {
                        Label(accountTypeLabel(group.type), systemImage: icon(for: group.type)).font(.subheadline.bold())
                        Spacer()
                        Text(currency.string(from: NSNumber(value: book.today(group.items))) ?? "")
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let a = account(for: ids) {
                Button("Show Transactions") { onOpenTransactions(a.accountId) }
                Button("Edit…") { editor = AccountEditor(account: a) }
                Toggle("Include in Spending & Cash Flow", isOn: Binding(
                    get: { a.countsInCashFlow }, set: { a.countsInCashFlow = $0; try? context.save() }))
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = a }
            }
        } primaryAction: { ids in
            // Double-click (or Return) opens the account's transactions.
            if let a = account(for: ids) { onOpenTransactions(a.accountId) }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Total balance").font(.headline)
                Text("all accounts, cards and loans subtracted").font(.caption).foregroundStyle(.secondary)
                Spacer()
                let total = book.today(accounts)
                Text(currency.string(from: NSNumber(value: total)) ?? "$0")
                    .font(.headline.monospacedDigit()).foregroundStyle(total < 0 ? .red : .primary)
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle("Accounts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Add Account") { editor = AccountEditor(account: nil) } }
        }
        .sheet(item: $editor) { ed in
            AccountEditorSheet(editor: ed, existingIds: Set(accounts.map(\.accountId))) { result in
                save(result, editing: ed.account)
                editor = nil
            } onCancel: { editor = nil }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Account and Transactions", role: .destructive) {
                if let a = pendingDelete { delete(a) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This can't be undone. Re-importing the account's OFX file brings its transactions back.")
        }
    }

    // MARK: - Helpers

    private func account(for ids: Set<UUID>) -> Account? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return accounts.first { $0.id == id }
    }

    private var deleteTitle: String {
        guard let a = pendingDelete else { return "Delete account?" }
        let n = transactions.filter { $0.accountId == a.accountId }.count
        return "Delete “\(a.name)” and its \(n) transaction\(n == 1 ? "" : "s")?"
    }

    private func delete(_ a: Account) {
        let acctId = a.accountId
        // Transfers linked to this account's transactions lose their link on the other side.
        let doomed = Set(transactions.filter { $0.accountId == acctId }.map(\.id))
        for tx in transactions where tx.accountId != acctId {
            if let p = tx.transferPeerId, doomed.contains(p) { tx.transferPeerId = nil }
        }
        for tx in transactions where tx.accountId == acctId { context.delete(tx) }
        selection.remove(a.id)
        context.delete(a)
        try? context.save()
    }

    private func save(_ r: AccountEditor.Result, editing existing: Account?) {
        if let a = existing {
            let oldId = a.accountId
            a.name = r.name; a.typeRaw = r.type.rawValue; a.bankName = r.bankName
            a.accountId = r.accountId; a.balance = r.balance
            a.countsInCashFlow = r.countsInCashFlow
            // Keep transactions linked to the account and showing its current name.
            for tx in transactions where tx.accountId == oldId {
                tx.accountId = r.accountId; tx.accountName = r.name
            }
        } else {
            let a = Account(name: r.name, type: r.type, accountId: r.accountId, bankName: r.bankName, balance: r.balance)
            a.countsInCashFlow = r.countsInCashFlow
            context.insert(a)
        }
        try? context.save()
    }

    private func icon(for t: AccountType) -> String {
        switch t {
        case .checking, .savings: return "building.columns"
        case .creditCard: return "creditcard"
        case .mortgage: return "house"
        case .investment: return "chart.line.uptrend.xyaxis"
        case .cash: return "banknote"
        case .property: return "house.fill"
        }
    }
}

func accountTypeLabel(_ t: AccountType) -> String {
    switch t {
    case .checking: return "Checking"
    case .savings: return "Savings"
    case .creditCard: return "Credit Card"
    case .mortgage: return "Mortgage"
    case .investment: return "Investment / Brokerage"
    case .cash: return "Cash"
    case .property: return "Property (home value)"
    }
}

// MARK: - Add / Edit sheet

struct AccountEditor: Identifiable {
    let id = UUID()
    let account: Account?   // nil = adding a new account

    struct Result {
        var name: String; var type: AccountType; var bankName: String; var accountId: String; var balance: Double
        var countsInCashFlow: Bool = true
    }
}

private struct AccountEditorSheet: View {
    let editor: AccountEditor
    let existingIds: Set<String>
    let onSave: (AccountEditor.Result) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var type: AccountType = .checking
    @State private var bankName = ""
    @State private var accountId = ""
    @State private var balance = ""
    @State private var countsInCashFlow = true

    enum Field: Hashable { case name, bank, accountId, balance }
    @FocusState private var focusedField: Field?

    private var isEditing: Bool { editor.account != nil }
    private var idTaken: Bool { accountId != editor.account?.accountId && existingIds.contains(accountId) }
    private var canSave: Bool { !name.isEmpty && (!accountId.isEmpty || type == .property) && !idTaken }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEditing ? "Edit Account" : "Add Account").font(.headline)
            field("Name") {
                TextField("Checking", text: $name)
                    .focused($focusedField, equals: .name)
                    .onSubmit { focusedField = .bank }
            }
            field("Type") {
                // Picking a type suggests its default (mortgages and property start out left out).
                Picker("Type", selection: Binding(get: { type }, set: { type = $0; countsInCashFlow = $0.countsInCashFlowByDefault })) {
                    ForEach(AccountType.allCases, id: \.self) { Text(accountTypeLabel($0)).tag($0) }
                }.labelsHidden()
            }
            field(type == .property ? "Address or note (optional)" : "Bank") {
                TextField(type == .property ? "123 Main St" : "Manual", text: $bankName)
                    .focused($focusedField, equals: .bank)
                    .onSubmit { focusedField = .accountId }
            }
            if type != .property {
                field(idTaken ? "Account ID (already used by another account)" : "Account ID (OFX ACCTID)") {
                    TextField("•••• last 4 shown in UI", text: $accountId)
                        .focused($focusedField, equals: .accountId)
                        .onSubmit { focusedField = .balance }
                }
            }
            field(type == .property ? "Estimated value" : (isEditing ? "Balance" : "Opening balance (optional)")) {
                TextField("0.00", text: $balance)
                    .focused($focusedField, equals: .balance)
                    .onSubmit { submit() }
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Include in spending & cash flow", isOn: $countsInCashFlow)
                Text("Turn off for accounts like a mortgage that pays escrow and property tax. They still count in net worth and balances.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add Account") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if let a = editor.account {
                name = a.name; type = a.type; bankName = a.bankName; accountId = a.accountId
                balance = String(format: "%.2f", a.balance)
                countsInCashFlow = a.countsInCashFlow
            } else {
                bankName = "Manual"
                countsInCashFlow = type.countsInCashFlowByDefault
            }
            // Sheet + window must be key, then put cursor in Name.
            if let window = NSApp.keyWindow ?? NSApp.windows.first { window.makeKeyAndOrderFront(nil) }
            // Delay so the sheet window is in the responder chain before focusing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focusedField = .name }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(idTaken && title.hasPrefix("Account ID") ? .red : .secondary)
            content()
        }
    }

    private func submit() {
        guard canSave else { return }
        let cleanedBalance = balance.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
        // A property has no bank ID: give it its own.
        let id = (type == .property && accountId.isEmpty) ? "property-\(UUID().uuidString.prefix(8))" : accountId
        onSave(.init(name: name, type: type, bankName: bankName.isEmpty ? "Manual" : bankName,
                     accountId: id, balance: Double(cleanedBalance) ?? 0, countsInCashFlow: countsInCashFlow))
    }
}
