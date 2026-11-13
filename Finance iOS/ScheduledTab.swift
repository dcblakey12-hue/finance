import SwiftUI
import SwiftData

struct ScheduledTab: View {
    @Query(sort: \RecurringBill.dueDay) private var schedules: [RecurringBill]
    @Query private var customCategories: [CustomCategory]
    @Query(sort: \Account.name) private var accounts: [Account]
    @Environment(\.modelContext) private var context

    @State private var editing: EditTarget?
    @State private var entering: EntryTarget?
    @State private var showingReminders = false

    private struct EditTarget: Identifiable { let id = UUID(); let existing: RecurringBill? }
    private var overdueItems: [OverdueItem] { ScheduleService.overdue(schedules) }
    private var names: [String: String] { Dictionary(accounts.map { ($0.accountId, $0.name) }, uniquingKeysWith: { a, _ in a }) }
    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }

    var body: some View {
        NavigationStack {
            List {
                if !overdueItems.isEmpty {
                    Section {
                        ForEach(overdueItems) { item in
                            Button { entering = EntryTarget(bill: item.bill, date: item.date) } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(item.bill.name).foregroundStyle(Color.primary)
                                        Text("due \(item.date.formatted(.dateTime.month(.abbreviated).day())) • \(item.daysLate()) day\(item.daysLate() == 1 ? "" : "s") late")
                                            .font(.caption).foregroundStyle(.red)
                                    }
                                    Spacer()
                                    Text(money(item.bill.signedAmount)).monospacedDigit().foregroundStyle(Color.primary)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Skip") { ScheduleService.skip(item.bill, occurrence: item.date, in: context) }.tint(.orange)
                            }
                        }
                    } header: { Text("Overdue — tap to enter, swipe to skip").foregroundStyle(.red) }
                }
                ForEach(ScheduleService.orderedByNextDue(schedules)) { s in
                    Button { if s.isActive { entering = EntryTarget(bill: s, date: nil) } else { editing = EditTarget(existing: s) } } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(s.name).foregroundStyle(s.isActive ? Color.primary : .secondary)
                                Text(s.isTransfer ? (s.item(accountNames: names).detail ?? "Transfer")
                                     : (names[s.accountId ?? ""].map { "\(s.category) • \($0)" } ?? s.category))
                                    .font(.caption).foregroundStyle(.secondary)
                                if s.isActive, let d = s.rule.nextDate(from: Date()) {
                                    Text("\(s.rule.summary()) • next \(d.formatted(.dateTime.month(.abbreviated).day().year()))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                } else {
                                    Text("Paused • \(s.rule.summary())").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(money(s.signedAmount)).monospacedDigit()
                                .foregroundStyle(s.isIncome ? .green : (s.isTransfer ? .blue : .primary))
                        }
                    }
                    .contextMenu {
                        if s.isActive {
                            Button("Enter next payment…") { entering = EntryTarget(bill: s, date: nil) }
                            Button("Skip next payment") {
                                if let due = s.rule.nextDate(from: Date()) { ScheduleService.skip(s, occurrence: due, in: context) }
                            }
                        }
                        Button("Edit schedule…") { editing = EditTarget(existing: s) }
                    }
                }
                .onDelete { idx in
                    let ordered = ScheduleService.orderedByNextDue(schedules)
                    idx.map { ordered[$0] }.forEach(context.delete)
                    try? context.save()
                }
            }
            .navigationTitle("Scheduled")
            .task { ScheduleService.ensureTracking(in: context) }
            .toolbar {
                Button { showingReminders = true } label: { Image(systemName: "bell") }
                Button { editing = EditTarget(existing: nil) } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $showingReminders) {
                NavigationStack {
                    Form { BillRemindersSettings() }
                        .navigationTitle("Reminders")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingReminders = false } } }
                }
            }
            .overlay {
                if schedules.isEmpty {
                    ContentUnavailableView("Nothing scheduled", systemImage: "calendar.badge.clock",
                        description: Text("Tap + to add a bill, payday or transfer."))
                }
            }
            .sheet(item: $entering) { target in
                EnterScheduledForm(bill: target.bill, occurrenceOverride: target.date, accounts: accounts) { entering = nil }
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
    /// 0 = never ends, 1 = after a number of payments, 2 = on a date.
    @State private var endMode = 0
    @State private var paymentsText = "12"
    @State private var endOn = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()

    /// The date of the nth upcoming payment under the pattern being edited.
    private func countedEnd(_ n: Int) -> Date? {
        var rule = draft.rule
        rule.end = nil
        rule.excluded = existing?.rule.excluded ?? []
        return rule.nthDate(n, from: Date())
    }

    private var kind: Binding<Int> {
        Binding(get: { draft.isTransfer ? 2 : (draft.isIncome ? 1 : 0) },
                set: { draft.isTransfer = $0 == 2; draft.isIncome = $0 == 1 })
    }
    private var amount: Double { Double(amountText.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")) ?? 0 }
    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && amount > 0 &&
        (!draft.isTransfer || (draft.fromAccountId != nil && draft.toAccountId != nil && draft.fromAccountId != draft.toAccountId)) &&
        draft.scheduleIsValid &&
        (endMode != 1 || ((Int(paymentsText) ?? 0) >= 1 && countedEnd(Int(paymentsText) ?? 1) != nil)) &&
        (draft.isTransfer || accounts.isEmpty || draft.accountId != nil)
    }
    private var startDateBinding: Binding<Date> {
        Binding(get: { draft.startDate ?? Date() }, set: { draft.startDate = $0 })
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: kind) {
                    Text("Bill").tag(0); Text("Income").tag(1); Text("Transfer").tag(2)
                }.pickerStyle(.segmented)
                TextField("Name", text: $draft.name)
                TextField("Amount", text: $amountText).keyboardType(.decimalPad)
                Picker("Repeats", selection: $draft.frequency) {
                    ForEach(ScheduleFrequency.allCases) { Text($0.label).tag($0) }
                }
                switch draft.frequency {
                case .monthly:
                    Picker("Day of month", selection: $draft.dueDay) {
                        ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                    }
                case .semimonthly:
                    Picker("First day", selection: $draft.dueDay) {
                        ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Second day", selection: $draft.secondDay) {
                        ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                    }
                case .weekly, .biweekly:
                    DatePicker("A date it lands on", selection: startDateBinding, displayedComponents: .date)
                    Text(draft.rule.summary()).font(.caption).foregroundStyle(.secondary)
                }
                Picker("Ends", selection: $endMode) {
                    Text("Never").tag(0)
                    Text("After a number of payments").tag(1)
                    Text("On a date").tag(2)
                }
                if endMode == 1 {
                    TextField("Number of payments", text: $paymentsText).keyboardType(.numberPad)
                    if let n = Int(paymentsText), n >= 1, let last = countedEnd(n) {
                        Text("The last one lands on \(last.formatted(.dateTime.month(.abbreviated).day().year())).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if endMode == 2 {
                    DatePicker("Last day", selection: $endOn, displayedComponents: .date)
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
                if !draft.isTransfer && !accounts.isEmpty {
                    Picker(draft.isIncome ? "Deposited to" : "Paid from", selection: $draft.accountId) {
                        Text("Choose…").tag(String?.none)
                        ForEach(accounts) { Text($0.name).tag(Optional($0.accountId)) }
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
                        if d.frequency == .weekly || d.frequency == .biweekly { d.startDate = d.startDate ?? Date() }
                        else { d.startDate = nil }
                        d.name = d.name.trimmingCharacters(in: .whitespaces)
                        switch endMode {
                        case 1: d.endDate = Int(paymentsText).flatMap { countedEnd($0) }
                        case 2: d.endDate = Calendar.current.startOfDay(for: endOn)
                        default: d.endDate = nil
                        }
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
                                      fromAccountId: s.fromAccountId, toAccountId: s.toAccountId,
                                      frequency: s.rule.frequency, secondDay: s.secondDay, startDate: s.anchorDate,
                                      accountId: s.accountId, endDate: s.endDate)
                amountText = String(format: "%.2f", abs(s.amount))
                if let e = s.endDate { endMode = 2; endOn = e }
            }
            if draft.accountId == nil && !draft.isTransfer {
                // A checking/savings account, not whichever card sorts first.
                draft.accountId = (accounts.first { [.checking, .savings, .cash].contains($0.type) } ?? accounts.first)?.accountId
            }
        }
    }
}


struct EntryTarget: Identifiable {
    let id = UUID()
    let bill: RecurringBill
    let date: Date?        // nil = the next payment
}

/// Enter (or skip) a payment of a schedule as a real transaction.
struct EnterScheduledForm: View {
    let bill: RecurringBill
    var occurrenceOverride: Date? = nil
    let accounts: [Account]
    let done: () -> Void

    @Environment(\.modelContext) private var context
    @State private var postedOn = Date()
    @State private var amountText = ""
    @State private var accountId: String?
    @State private var fromId: String?
    @State private var toId: String?

    private var occurrence: Date? { occurrenceOverride ?? bill.rule.nextDate(from: Date()) }
    private var amount: Double? { Double(amountText.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")) }
    private var canEnter: Bool {
        guard occurrence != nil, let a = amount, a > 0 else { return false }
        return bill.isTransfer ? (fromId != nil && toId != nil && fromId != toId) : accountId != nil
    }
    private func account(_ id: String?) -> Account? { accounts.first { $0.accountId == id } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let due = occurrence {
                        Text("\(bill.rule.summary()) • due \(due.formatted(date: .abbreviated, time: .omitted))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    DatePicker("Date", selection: $postedOn, displayedComponents: .date)
                    TextField("Amount", text: $amountText).keyboardType(.decimalPad)
                    if bill.isTransfer {
                        Picker("From", selection: $fromId) {
                            Text("Choose…").tag(String?.none)
                            ForEach(accounts) { Text($0.name).tag(Optional($0.accountId)) }
                        }
                        Picker("To", selection: $toId) {
                            Text("Choose…").tag(String?.none)
                            ForEach(accounts) { Text($0.name).tag(Optional($0.accountId)) }
                        }
                    } else {
                        Picker(bill.isIncome ? "Deposit to" : "Pay from", selection: $accountId) {
                            Text("Choose…").tag(String?.none)
                            ForEach(accounts) { Text($0.name).tag(Optional($0.accountId)) }
                        }
                    }
                } footer: {
                    Text("Enter adds a real transaction and updates the balance. Skip leaves this payment out.")
                }
                Section {
                    Button("Skip This One", role: .destructive) {
                        if let due = occurrence { ScheduleService.skip(bill, occurrence: due, in: context) }
                        done()
                    }.disabled(occurrence == nil)
                }
            }
            .navigationTitle(bill.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enter") {
                        guard let due = occurrence, let amt = amount else { return }
                        ScheduleService.enter(bill, occurrence: due, postedOn: postedOn, amount: amt,
                                              account: account(accountId), from: account(fromId), to: account(toId), in: context)
                        done()
                    }.disabled(!canEnter)
                }
            }
        }
        .onAppear {
            postedOn = occurrence ?? Date()
            amountText = String(format: "%.2f", abs(bill.amount))
            accountId = bill.accountId ?? accounts.first?.accountId
            fromId = bill.fromAccountId; toId = bill.toAccountId
        }
    }
}
