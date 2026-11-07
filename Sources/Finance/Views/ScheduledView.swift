import SwiftUI
import SwiftData

/// Sidebar section listing every scheduled transaction (bills and paydays).
struct ScheduledView: View {
    @Query(sort: \RecurringBill.dueDay) var schedules: [RecurringBill]
    @Query var customCategories: [CustomCategory]
    @Environment(\.modelContext) private var context

    @State private var selection = Set<UUID>()
    @State private var editor: ScheduleEditor?
    @State private var pendingDelete: RecurringBill?

    private var categories: [String] { BudgetService.allCategories(stored: customCategories.map(\.name)) }
    private var monthlyIncome: Double { schedules.filter { $0.isActive && $0.isIncome }.reduce(0) { $0 + abs($1.amount) } }
    private var monthlyBills: Double { schedules.filter { $0.isActive && $0.isExpense }.reduce(0) { $0 + abs($1.amount) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                total("Monthly income", monthlyIncome, .green)
                total("Monthly bills", monthlyBills, .red)
                total("Net", monthlyIncome - monthlyBills, monthlyIncome >= monthlyBills ? .green : .red)
                Spacer()
            }
            .padding()

            if schedules.isEmpty {
                ContentUnavailableView("No scheduled transactions",
                    systemImage: "calendar.badge.clock",
                    description: Text("Click Add, or right-click a transaction and choose Schedule as Recurring…"))
            } else {
                Table(schedules, selection: $selection) {
                    TableColumn("Name") { s in
                        Text(s.name).foregroundStyle(s.isActive ? .primary : .secondary)
                    }
                    TableColumn("Type") { s in
                        Text(s.isIncome ? "Income" : "Bill")
                            .font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(s.isIncome ? Color.green.opacity(0.2) : Color.red.opacity(0.15), in: Capsule())
                    }.width(70)
                    TableColumn("Category") { s in Text(s.category) }
                    TableColumn("Day") { s in Text("\(s.dueDay)").monospacedDigit() }.width(40)
                    TableColumn("Next") { s in
                        if s.isActive, let d = ScheduleService.nextDueDate(dueDay: s.dueDay, from: Date()) {
                            Text(d, format: .dateTime.month(.abbreviated).day())
                        } else { Text("—").foregroundStyle(.secondary) }
                    }.width(70)
                    TableColumn("Amount") { s in
                        Text(currency.string(from: NSNumber(value: s.signedAmount)) ?? "")
                            .monospacedDigit().foregroundStyle(s.isIncome ? .green : .primary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(100)
                    TableColumn("Active") { s in
                        Toggle("", isOn: Binding(get: { s.isActive }, set: { s.isActive = $0; try? context.save() }))
                            .labelsHidden()
                    }.width(50)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let s = schedule(for: ids) {
                        Button("Edit…") { editor = ScheduleEditor(existing: s, draft: draft(of: s)) }
                        Button(s.isActive ? "Pause" : "Resume") { s.isActive.toggle(); try? context.save() }
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDelete = s }
                    }
                } primaryAction: { ids in
                    if let s = schedule(for: ids) { editor = ScheduleEditor(existing: s, draft: draft(of: s)) }
                }
            }
        }
        .navigationTitle("Scheduled Transactions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add") {
                    editor = ScheduleEditor(existing: nil, draft: ScheduleDraft(name: "", amount: 0, dueDay: 1, category: "Other", isIncome: false))
                }
            }
        }
        .sheet(item: $editor) { ed in
            ScheduleEditorSheet(editor: ed, categories: categories) { result in
                ScheduleEditor.save(result, existing: ed.existing, in: context)
                editor = nil
            } onCancel: { editor = nil }
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let s = pendingDelete { selection.remove(s.id); context.delete(s); try? context.save() }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("It will no longer count in the cash flow forecast. Events already synced to Apple Calendar stay there.")
        }
    }

    private func schedule(for ids: Set<UUID>) -> RecurringBill? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return schedules.first { $0.id == id }
    }

    private func draft(of s: RecurringBill) -> ScheduleDraft {
        ScheduleDraft(name: s.name, amount: abs(s.amount), dueDay: s.dueDay, category: s.category, isIncome: s.isIncome, isActive: s.isActive)
    }

    private func total(_ title: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(currency.string(from: NSNumber(value: value)) ?? "").font(.title3.bold()).monospacedDigit().foregroundStyle(color)
        }
    }
}

// MARK: - Editor (shared with Transactions' "Schedule as Recurring…")

struct ScheduleEditor: Identifiable {
    let id = UUID()
    let existing: RecurringBill?   // nil = new schedule
    let draft: ScheduleDraft

    @MainActor
    static func save(_ d: ScheduleDraft, existing: RecurringBill?, in context: ModelContext) {
        let category = d.isIncome ? "Income" : d.category
        if let s = existing {
            s.name = d.name; s.amount = abs(d.amount); s.dueDay = d.dueDay
            s.category = category; s.kindRaw = d.isIncome ? "credit" : "debit"; s.isActive = d.isActive
        } else {
            let s = RecurringBill(name: d.name, amount: abs(d.amount), dueDay: d.dueDay, category: category,
                                  isActive: d.isActive, isIncome: d.isIncome)
            context.insert(s)
        }
        try? context.save()
    }
}

struct ScheduleEditorSheet: View {
    let editor: ScheduleEditor
    let categories: [String]
    let onSave: (ScheduleDraft) -> Void
    let onCancel: () -> Void

    @State private var draft = ScheduleDraft(name: "", amount: 0, dueDay: 1, category: "Other", isIncome: false)
    @State private var amountText = ""

    private var parsedAmount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: ""))
    }
    private var canSave: Bool { !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && (parsedAmount ?? 0) > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor.existing == nil ? "Schedule Transaction" : "Edit Scheduled Transaction").font(.headline)
            Picker("Type", selection: $draft.isIncome) {
                Text("Bill (expense)").tag(false)
                Text("Income (payday)").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            Form {
                TextField("Name", text: $draft.name)
                TextField("Amount", text: $amountText)
                Picker(draft.isIncome ? "Payday" : "Due day", selection: $draft.dueDay) {
                    ForEach(1...28, id: \.self) { Text(ordinal($0)).tag($0) }
                }
                if !draft.isIncome {
                    Picker("Category", selection: $draft.category) {
                        ForEach(Array(Set(categories + [draft.category])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                }
                Toggle("Active", isOn: $draft.isActive)
            }
            .formStyle(.grouped)
            Text("Repeats monthly on that day. Days are capped at the 28th so every month has one.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(editor.existing == nil ? "Schedule" : "Save") {
                    var d = draft; d.amount = parsedAmount ?? 0
                    d.name = d.name.trimmingCharacters(in: .whitespaces)
                    if d.isIncome { d.category = "Income" } else if d.category == "Income" { d.category = "Other" }
                    onSave(d)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            draft = editor.draft
            amountText = editor.draft.amount > 0 ? String(format: "%.2f", editor.draft.amount) : ""
        }
    }

    private func ordinal(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .ordinal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
