import SwiftUI
import SwiftData
import AppKit

struct AccountsView: View {
    @Query(sort: \Account.name) var accounts: [Account]
    @State private var showingAdd = false
    @State private var newName = ""
    @State private var newAccountId = ""
    @State private var newBalance = ""

    enum Field: Hashable { case name, accountId, balance }
    @FocusState private var focusedField: Field?

    var body: some View {
        List(accounts) { a in
            HStack {
                Image(systemName: "building.columns").foregroundStyle(.secondary)
                VStack(alignment: .leading) { Text(a.name).font(.headline); Text("\(a.typeRaw) • \(a.bankName) •••\(a.accountId.suffix(4))").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(currency.string(from: NSNumber(value: a.balance)) ?? "$0").monospacedDigit()
            }
            .padding(.vertical, 4)
        }
        .navigationTitle("Accounts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Add Account") { showingAdd = true } }
        }
        .sheet(isPresented: $showingAdd) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add Account").font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Checking", text: $newName)
                        .focused($focusedField, equals: .name)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit { focusedField = .accountId }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Account ID (OFX ACCTID)").font(.caption).foregroundStyle(.secondary)
                    TextField("•••• last 4 shown in UI", text: $newAccountId)
                        .focused($focusedField, equals: .accountId)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit { focusedField = .balance }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Opening balance (optional)").font(.caption).foregroundStyle(.secondary)
                    TextField("0.00", text: $newBalance)
                        .focused($focusedField, equals: .balance)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onSubmit { submit() }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { showingAdd = false }
                        .keyboardShortcut(.cancelAction)
                    Button(newName.isEmpty || newAccountId.isEmpty ? "Add (need name + ID)" : "Add Account") { submit() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(newName.isEmpty || newAccountId.isEmpty)
                }
            }
            .padding(20)
            .frame(width: 380)
            .onAppear {
                // Sheet + window must be key, then put cursor in Name.
                if let window = NSApp.keyWindow ?? NSApp.windows.first {
                    window.makeKeyAndOrderFront(nil)
                }
                // Delay so the sheet window is in the responder chain before focusing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    focusedField = .name
                }
            }
        }
    }
    @Environment(\.modelContext) private var context

    private func submit() {
        guard !newName.isEmpty, !newAccountId.isEmpty else { return }
        let a = Account(name: newName, type: .checking, accountId: newAccountId, bankName: "Manual", balance: Double(newBalance) ?? 0)
        context.insert(a); try? context.save()
        newName = ""; newAccountId = ""; newBalance = ""
        showingAdd = false
    }
}
