import SwiftUI
import SwiftData

/// Sidebar section listing every scheduled transaction (bills and paydays).
struct ScheduledView: View {
    @Query(sort: \RecurringBill.dueDay) var schedules: [RecurringBill]
    @Query var customCategories: [CustomCategory]
    @Query var accounts: [Account]
    @Environment(\.modelContext) private var context

    @State private var selection = Set<UUID>()
    @State private var editor: ScheduleEditor?
    @State private var pendingDelete: RecurringBill?
    @State private var entering: EntryTarget?
    @State private var note = ""

    private var accountChoices: [AccountChoice] { accounts.map { AccountChoice(id: $0.accountId, name: $0.name, isCash: [.checking, .savings, .cash].contains($0.type)) }.sorted { $0.name < $1.name } }
    private var accountNames: [String: String] { Dictionary(accounts.map { ($0.accountId, $0.name) }, uniquingKeysWith: { a, _ in a }) }
    private func routeText(_ s: RecurringBill) -> String { s.item(accountNames: accountNames).detail ?? "Transfer" }
    private var categories: [String] { BudgetService.allCategories(stored: customCategories.map(\.name)) }
    private var monthlyIncome: Double { schedules.filter { $0.isActive && $0.isIncome }.reduce(0) { $0 + $1.monthlySize } }
    private var monthlyBills: Double { schedules.filter { $0.isActive && $0.isExpense }.reduce(0) { $0 + $1.monthlySize } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                total("Monthly income", monthlyIncome, .green)
                total("Monthly bills", monthlyBills, .red)
                total("Net", monthlyIncome - monthlyBills, monthlyIncome >= monthlyBills ? .green : .red)
                Spacer()
            }
            .padding()

            if !overdueItems.isEmpty { overdueBox }

            if schedules.isEmpty {
                ContentUnavailableView("No scheduled transactions",
                    systemImage: "calendar.badge.clock",
                    description: Text("Click Add, or right-click a transaction and choose Schedule as Recurring…"))
            } else {
                Table(ScheduleService.orderedByNextDue(schedules), selection: $selection) {
                    TableColumn("Name") { s in
                        Text(s.name).foregroundStyle(s.isActive ? .primary : .secondary)
                    }
                    TableColumn("Type") { s in
                        Text(s.isTransfer ? "Transfer" : (s.isIncome ? "Income" : "Bill"))
                            .font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(s.isTransfer ? Color.blue.opacity(0.18) : (s.isIncome ? Color.green.opacity(0.2) : Color.red.opacity(0.15)), in: Capsule())
                    }.width(80)
                    TableColumn("Category / accounts") { s in
                        Text(s.isTransfer ? routeText(s)
                             : (accountNames[s.accountId ?? ""].map { "\(s.category) • \($0)" } ?? s.category))
                    }
                    TableColumn("Repeats") { s in Text(s.rule.summary()) }.width(min: 130, ideal: 170)
                    TableColumn("Next due") { s in
                        if s.isActive, let d = s.rule.nextDate(from: Date()) {
                            // Click the date to change it; picking a new one saves immediately.
                            DueDateCell(date: d) { ScheduleService.setNextDue(s, to: $0, in: context) }
                        } else { Text("—").foregroundStyle(.secondary) }
                    }.width(120)
                    TableColumn("Amount") { s in
                        Text(currency.string(from: NSNumber(value: s.signedAmount)) ?? "")
                            .monospacedDigit().foregroundStyle(s.isIncome ? .green : (s.isTransfer ? .blue : .primary))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(100)
                    TableColumn("Active") { s in
                        Toggle("", isOn: Binding(get: { s.isActive }, set: { s.isActive = $0; try? context.save() }))
                            .labelsHidden()
                    }.width(50)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let s = schedule(for: ids) {
                        if s.isActive {
                            Button("Enter Next Payment…") { entering = EntryTarget(bill: s, date: nil) }
                            Button("Skip Next Payment") { skipNext(s) }
                        }
                        Button("Edit Schedule…") { editor = ScheduleEditor(existing: s, draft: draft(of: s)) }
                        if !s.occurrenceLogRaw.isEmpty {
                            Button("Forget Entered/Skipped History") { s.occurrenceLogRaw = ""; try? context.save() }
                        }
                        Button(s.isActive ? "Pause" : "Resume") { s.isActive.toggle(); try? context.save() }
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDelete = s }
                    }
                } primaryAction: { ids in
                    // Double-click: adjust the schedule. Enter / skip the next payment from the right-click menu.
                    if let s = schedule(for: ids) { editor = ScheduleEditor(existing: s, draft: draft(of: s)) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(.bar)
            }
        }
        .task { ScheduleService.ensureTracking(in: context) }
        .navigationTitle("Scheduled Transactions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add") {
                    editor = ScheduleEditor(existing: nil, draft: ScheduleDraft(name: "", amount: 0, dueDay: 1, category: "Other", isIncome: false))
                }
            }
        }
        .sheet(item: $entering) { target in
            EnterScheduledSheet(bill: target.bill, occurrenceOverride: target.date, accounts: accounts) { message in
                entering = nil
                if let message { note = message }
            }
        }
        .sheet(item: $editor) { ed in
            ScheduleEditorSheet(editor: ed, categories: categories, accounts: accountChoices) { result in
                ScheduleEditor.save(result, existing: ed.existing, in: context)
                editor = nil
            } onCancel: { editor = nil } onNextDue: { date in
                if let b = ed.existing { ScheduleService.setNextDue(b, to: date, in: context) }
            }
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

    private var overdueItems: [OverdueItem] { ScheduleService.overdue(schedules) }

    private var overdueBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Overdue (\(overdueItems.count))").font(.headline).foregroundStyle(.red)
                Text("Past payments you haven't entered or skipped").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Skip All") {
                    for i in overdueItems { ScheduleService.skip(i.bill, occurrence: i.date, in: context) }
                    note = "Skipped all overdue payments."
                }.buttonStyle(.link).font(.caption)
            }
            ForEach(overdueItems) { item in
                HStack {
                    Text(item.bill.name)
                    Text("due \(item.date.formatted(.dateTime.month(.abbreviated).day())) • \(item.daysLate()) day\(item.daysLate() == 1 ? "" : "s") late")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(currency.string(from: NSNumber(value: item.bill.signedAmount)) ?? "").monospacedDigit()
                    Button("Enter…") { entering = EntryTarget(bill: item.bill, date: item.date) }
                    Button("Skip") {
                        ScheduleService.skip(item.bill, occurrence: item.date, in: context)
                        note = "Skipped \(item.bill.name) on \(item.date.formatted(.dateTime.month(.abbreviated).day()))."
                    }
                }
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func skipNext(_ s: RecurringBill) {
        guard let due = s.rule.nextDate(from: Date()) else { return }
        ScheduleService.skip(s, occurrence: due, in: context)
        note = "Skipped \(s.name) on \(due.formatted(.dateTime.month(.abbreviated).day()))."
    }

    private func schedule(for ids: Set<UUID>) -> RecurringBill? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return schedules.first { $0.id == id }
    }

    private func draft(of s: RecurringBill) -> ScheduleDraft {
        ScheduleDraft(name: s.name, amount: abs(s.amount), dueDay: s.dueDay, category: s.category, isIncome: s.isIncome,
                      isActive: s.isActive, isTransfer: s.isTransfer,
                      fromAccountId: s.fromAccountId, toAccountId: s.toAccountId,
                      frequency: s.rule.frequency, secondDay: s.secondDay, startDate: s.anchorDate,
                      accountId: s.accountId)
    }

    private func total(_ title: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(currency.string(from: NSNumber(value: value)) ?? "").font(.title3.bold()).monospacedDigit().foregroundStyle(color)
        }
    }
}

/// A due date shown as MM/DD/YYYY (zero-padded); click it to pick another date.
struct DueDateCell: View {
    let date: Date
    let onChange: (Date) -> Void
    @State private var open = false
    @State private var picked = Date()

    var body: some View {
        Button {
            picked = date; open = true
        } label: {
            Text(date, format: .dateTime.month(.twoDigits).day(.twoDigits).year())
                .monospacedDigit()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            DatePicker("", selection: $picked, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden().padding(10)
                .onChange(of: picked) { _, new in
                    if Calendar.current.startOfDay(for: new) != Calendar.current.startOfDay(for: date) {
                        open = false
                        onChange(new)
                    }
                }
        }
        .help("Click to change the next due date")
    }
}

// MARK: - Editor (shared with Transactions' "Schedule as Recurring…")

struct ScheduleEditor: Identifiable {
    let id = UUID()
    let existing: RecurringBill?   // nil = new schedule
    let draft: ScheduleDraft

    @MainActor
    static func save(_ d: ScheduleDraft, existing: RecurringBill?, in context: ModelContext) {
        ScheduleService.save(d, existing: existing, in: context)
    }
}

struct AccountChoice: Identifiable, Hashable {
    let id: String      // OFX accountId
    let name: String
    /// Checking, savings or cash: where paydays and bills normally belong.
    var isCash: Bool = true
}

struct ScheduleEditorSheet: View {
    let editor: ScheduleEditor
    let categories: [String]
    let accounts: [AccountChoice]
    let onSave: (ScheduleDraft) -> Void
    let onCancel: () -> Void
    /// Called after saving when the next due date was changed (existing schedules only).
    var onNextDue: (Date) -> Void = { _ in }

    @State private var nextDue = Date()
    @State private var originalNextDue: Date?
    @State private var draft = ScheduleDraft(name: "", amount: 0, dueDay: 1, category: "Other", isIncome: false)
    @State private var amountText = ""

    private var parsedAmount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: ""))
    }
    private var transferOK: Bool {
        !draft.isTransfer || (draft.fromAccountId != nil && draft.toAccountId != nil && draft.fromAccountId != draft.toAccountId)
    }
    private var accountOK: Bool { draft.isTransfer || accounts.isEmpty || draft.accountId != nil }
    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && (parsedAmount ?? 0) > 0 && transferOK
            && draft.scheduleIsValid && accountOK
    }
    private var startDateBinding: Binding<Date> {
        Binding(get: { draft.startDate ?? Date() }, set: { draft.startDate = $0 })
    }
    /// 0 = bill, 1 = income, 2 = transfer
    private var kind: Binding<Int> {
        Binding(get: { draft.isTransfer ? 2 : (draft.isIncome ? 1 : 0) },
                set: { draft.isTransfer = $0 == 2; draft.isIncome = $0 == 1 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor.existing == nil ? "Schedule Transaction" : "Edit Scheduled Transaction").font(.headline)
            Picker("Type", selection: kind) {
                Text("Bill").tag(0)
                Text("Income").tag(1)
                Text("Transfer").tag(2)
            }.pickerStyle(.segmented).labelsHidden()
            Form {
                TextField("Name", text: $draft.name)
                TextField("Amount", text: $amountText)
                Picker("Repeats", selection: $draft.frequency) {
                    ForEach(ScheduleFrequency.allCases) { Text($0.label).tag($0) }
                }
                switch draft.frequency {
                case .monthly:
                    Picker(draft.isIncome ? "Payday" : (draft.isTransfer ? "Day" : "Due day"), selection: $draft.dueDay) {
                        ForEach(1...31, id: \.self) { Text(ordinal($0)).tag($0) }
                    }
                case .semimonthly:
                    Picker("First day", selection: $draft.dueDay) {
                        ForEach(1...31, id: \.self) { Text(ordinal($0)).tag($0) }
                    }
                    Picker("Second day", selection: $draft.secondDay) {
                        ForEach(1...31, id: \.self) { Text(ordinal($0)).tag($0) }
                    }
                    if !draft.scheduleIsValid { Text("Pick two different days.").font(.caption).foregroundStyle(.red) }
                case .weekly, .biweekly:
                    DatePicker(draft.isIncome ? "A payday" : "A date it lands on", selection: startDateBinding, displayedComponents: .date)
                    Text("Repeats \(draft.frequency == .weekly ? "every week" : "every 2 weeks") from this date: \(draft.rule.summary()).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if draft.isTransfer {
                    Picker("From account", selection: $draft.fromAccountId) {
                        Text("Choose…").tag(String?.none)
                        ForEach(accounts) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("To account", selection: $draft.toAccountId) {
                        Text("Choose…").tag(String?.none)
                        ForEach(accounts) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if accounts.count < 2 {
                        Text("Add at least two accounts (Accounts → Add or import a file) to schedule a transfer.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if draft.fromAccountId != nil && draft.fromAccountId == draft.toAccountId {
                        Text("Pick two different accounts.").font(.caption).foregroundStyle(.red)
                    }
                } else if !draft.isIncome {
                    Picker("Category", selection: $draft.category) {
                        ForEach(Array(Set(categories + [draft.category])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                }
                if !draft.isTransfer && !accounts.isEmpty {
                    Picker(draft.isIncome ? "Deposited to" : "Paid from", selection: $draft.accountId) {
                        Text("Choose…").tag(String?.none)
                        ForEach(accounts) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if editor.existing != nil, let original = originalNextDue {
                    DatePicker("Next due", selection: $nextDue, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                    if Calendar.current.startOfDay(for: nextDue) != original {
                        Text("Payments before this date will be skipped. Nothing is booked.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Active", isOn: $draft.isActive)
            }
            .formStyle(.grouped)
            Text(draft.isTransfer ? "Moves money between two of your accounts. It doesn't count as income or spending, and it shows on the calendar."
                                     : "Days past the end of a short month (29th–31st) land on that month's last day.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(editor.existing == nil ? "Schedule" : "Save") {
                    var d = draft; d.amount = parsedAmount ?? 0
                    if d.frequency == .weekly || d.frequency == .biweekly { d.startDate = d.startDate ?? Date() }
                    else { d.startDate = nil }
                    d.name = d.name.trimmingCharacters(in: .whitespaces)
                    if d.isTransfer { d.category = Categorizer.transfer; d.isIncome = false }
                    else if d.isIncome { d.category = "Income" }
                    else if d.category == "Income" || d.category == Categorizer.transfer { d.category = "Other" }
                    onSave(d)
                    if let original = originalNextDue, Calendar.current.startOfDay(for: nextDue) != original { onNextDue(nextDue) }
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
            if let b = editor.existing, b.isActive, let d = b.rule.nextDate(from: Date()) { nextDue = d; originalNextDue = d }
            if draft.accountId == nil && !draft.isTransfer {
                // Default to a checking/savings account the first time (never a card just because it sorts first).
                draft.accountId = (accounts.first { $0.isCash } ?? accounts.first)?.id
            }
            amountText = editor.draft.amount > 0 ? String(format: "%.2f", editor.draft.amount) : ""
        }
    }

    private func ordinal(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .ordinal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}


// MARK: - Enter or skip the next payment

struct EntryTarget: Identifiable {
    let id = UUID()
    let bill: RecurringBill
    let date: Date?        // nil = the next payment
}

struct EnterScheduledSheet: View {
    let bill: RecurringBill
    var occurrenceOverride: Date? = nil     // a specific (overdue) payment instead of the next one
    let accounts: [Account]
    /// Called with a status message, or nil if cancelled.
    let onDone: (String?) -> Void

    @Environment(\.modelContext) private var context
    @State private var postedOn = Date()
    @State private var amountText = ""
    @State private var accountId: String?
    @State private var fromId: String?
    @State private var toId: String?

    private var occurrence: Date? { occurrenceOverride ?? bill.rule.nextDate(from: Date()) }
    private var amount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: ""))
    }
    private var canEnter: Bool {
        guard occurrence != nil, let a = amount, a > 0 else { return false }
        return bill.isTransfer ? (fromId != nil && toId != nil && fromId != toId) : accountId != nil
    }
    private func account(_ id: String?) -> Account? { accounts.first { $0.accountId == id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(bill.name).font(.headline)
            if let due = occurrence {
                Text("\(bill.rule.summary()) • due \(due.formatted(date: .abbreviated, time: .omitted))")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("No upcoming payment.").foregroundStyle(.secondary)
            }
            Form {
                DatePicker("Date", selection: $postedOn, displayedComponents: .date)
                TextField("Amount", text: $amountText)
                if bill.isTransfer {
                    Picker("From account", selection: $fromId) {
                        Text("Choose…").tag(String?.none)
                        ForEach(accounts) { Text($0.name).tag(Optional($0.accountId)) }
                    }
                    Picker("To account", selection: $toId) {
                        Text("Choose…").tag(String?.none)
                        ForEach(accounts) { Text($0.name).tag(Optional($0.accountId)) }
                    }
                } else {
                    Picker(bill.isIncome ? "Deposit to" : "Pay from", selection: $accountId) {
                        Text("Choose…").tag(String?.none)
                        ForEach(accounts) { Text($0.name).tag(Optional($0.accountId)) }
                    }
                }
            }
            .formStyle(.grouped)
            Text("Enter adds a real transaction and updates the account balance; change the date or amount if this one differs. Save Date Only just moves the due date and books nothing. Skip leaves this payment out and moves to the next one. Importing your bank file later replaces an entered transaction that matches.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Skip This One") {
                    if let due = occurrence { ScheduleService.skip(bill, occurrence: due, in: context) }
                    onDone("Skipped \(bill.name).")
                }.disabled(occurrence == nil)
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Save Date Only") {
                    ScheduleService.setNextDue(bill, to: postedOn, in: context)
                    onDone("\(bill.name) is now next due \(postedOn.formatted(.dateTime.month(.twoDigits).day(.twoDigits).year())). Nothing was booked.")
                }
                .help("Change when this is next due without adding a transaction")
                .disabled(occurrenceOverride != nil || occurrence == nil
                          || Calendar.current.startOfDay(for: postedOn) == Calendar.current.startOfDay(for: occurrence ?? postedOn))
                Button("Enter Transaction") {
                    guard let due = occurrence, let amt = amount else { return }
                    let ok = ScheduleService.enter(bill, occurrence: due, postedOn: postedOn, amount: amt,
                                                   account: account(accountId), from: account(fromId), to: account(toId), in: context)
                    onDone(ok ? "Entered \(bill.name) for \(currency.string(from: NSNumber(value: amt)) ?? "")." : nil)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canEnter)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            postedOn = occurrence ?? Date()
            amountText = String(format: "%.2f", abs(bill.amount))
            accountId = bill.accountId ?? accounts.first?.accountId
            fromId = bill.fromAccountId; toId = bill.toAccountId
        }
    }
}
