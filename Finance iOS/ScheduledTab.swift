import SwiftUI
import SwiftData

struct ScheduledTab: View {
    @Query(sort: \RecurringBill.dueDay) private var schedules: [RecurringBill]
    @Query private var customCategories: [CustomCategory]
    @Query(sort: \Account.name) private var accounts: [Account]
    @Environment(\.modelContext) private var context

    @State private var editing: EditTarget?

    private struct EditTarget: Identifiable { let id = UUID(); let existing: RecurringBill? }
    private var names: [String: String] { Dictionary(accounts.map { ($0.accountId, $0.name) }, uniquingKeysWith: { a, _ in a }) }
    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }

    var body: some View {
        NavigationStack {
            List {
                ForEach(ScheduleService.orderedByNextDue(schedules)) { s in
                    Button { editing = EditTarget(existing: s) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(s.name).foregroundStyle(s.isActive ? Color.primary : .secondary)
                                Text(s.isTransfer ? (s.item(accountNames: names).detail ?? "Transfer") : s.category)
                                    .font(.caption).foregroundStyle(.secondary)
                                if s.isActive, let d = ScheduleService.nextDueDate(dueDay: s.dueDay, from: Date()) {
                                    Text("Next: \(d.formatted(.dateTime.month(.abbreviated).day().year()))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                } else {
                                    Text("Paused • day \(s.dueDay)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(money(s.signedAmount)).monospacedDigit()
                                .foregroundStyle(s.isIncome ? .green : (s.isTransfer ? .blue : .primary))
                        }
                    }
                }
                .onDelete { idx in
                    let ordered = ScheduleService.orderedByNextDue(schedules)
                    idx.map { ordered[$0] }.forEach(context.delete)
                    try? context.save()
                }
            }
            .navigationTitle("Scheduled")
            .toolbar { Button { editing = EditTarget(existing: nil) } label: { Image(systemName: "plus") } }
            .overlay {
                if schedules.isEmpty {
                    ContentUnavailableView("Nothing scheduled", systemImage: "calendar.badge.clock",
                        description: Text("Tap + to add a bill, payday or transfer."))
                }
            }
            .sheet(item: $editing) { target in
                ScheduleForm(existing: target.existing,
                             categories: BudgetService.allCategories(stored: customCategories.map(\.name)),
                             accounts: accounts) { editing = nil }
            }
        }
    }
}

struct ScheduleForm: View {
    let existing: RecurringBill?
    let categories: [String]
    let accounts: [Account]
    let done: () -> Void

    @Environment(\.modelContext) private var context
    @State private var draft = ScheduleDraft(name: "", amount: 0, dueDay: 1, category: "Other", isIncome: false)
    @State private var amountText = ""

    private var kind: Binding<Int> {
        Binding(get: { draft.isTransfer ? 2 : (draft.isIncome ? 1 : 0) },
                set: { draft.isTransfer = $0 == 2; draft.isIncome = $0 == 1 })
    }
    private var amount: Double { Double(amountText.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")) ?? 0 }
    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && amount > 0 &&
        (!draft.isTransfer || (draft.fromAccountId != nil && draft.toAccountId != nil && draft.fromAccountId != draft.toAccountId))
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: kind) {
                    Text("Bill").tag(0); Text("Income").tag(1); Text("Transfer").tag(2)
                }.pickerStyle(.segmented)
                TextField("Name", text: $draft.name)
                TextField("Amount", text: $amountText).keyboardType(.decimalPad)
                Picker("Day of month", selection: $draft.dueDay) {
                    ForEach(1...28, id: \.self) { Text("\($0)").tag($0) }
                }
                if draft.isTransfer {
                    Picker("From", selection: $draft.fromAccountId) {
                        Text("Choose…").tag(String?.none)
                        ForEach(accounts) { Text($0.name).tag(Optional($0.accountId)) }
                    }
                    Picker("To", selection: $draft.toAccountId) {
                        Text("Choose…").tag(String?.none)
                        ForEach(accounts) { Text($0.name).tag(Optional($0.accountId)) }
                    }
                } else if !draft.isIncome {
                    Picker("Category", selection: $draft.category) {
                        ForEach(Array(Set(categories + [draft.category])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                }
                Toggle("Active", isOn: $draft.isActive)
            }
            .navigationTitle(existing == nil ? "New Scheduled" : "Edit Scheduled")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var d = draft
                        d.amount = amount
                        d.name = d.name.trimmingCharacters(in: .whitespaces)
                        if d.isTransfer { d.isIncome = false }
                        else if d.category == "Income" || d.category == Categorizer.transfer { d.category = "Other" }
                        ScheduleService.save(d, existing: existing, in: context)
                        done()
                    }.disabled(!canSave)
                }
            }
        }
        .onAppear {
            if let s = existing {
                draft = ScheduleDraft(name: s.name, amount: abs(s.amount), dueDay: s.dueDay, category: s.category,
                                      isIncome: s.isIncome, isActive: s.isActive, isTransfer: s.isTransfer,
                                      fromAccountId: s.fromAccountId, toAccountId: s.toAccountId)
                amountText = String(format: "%.2f", abs(s.amount))
            }
        }
    }
}
