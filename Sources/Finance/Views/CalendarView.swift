import SwiftUI
import SwiftData

struct CalendarView: View {
    @Query(sort: \RecurringBill.dueDay) var bills: [RecurringBill]
    @Query var customCategories: [CustomCategory]
    @State private var calService = CalendarService()
    @State private var newName = ""
    @State private var newAmount = ""
    @State private var newDay = "15"
    @State private var newCategory = "Housing"
    @State private var newIsIncome = false
    @State private var status = ""
    @Environment(\.modelContext) private var context

    var expenses: [RecurringBill] { bills.filter { $0.isExpense } }
    var incomes: [RecurringBill] { bills.filter { $0.isIncome } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Bills & Calendar").font(.largeTitle.bold())
                Text("Scheduled transactions (bills + paydays) feed the cash-flow forecast and can sync to Apple Calendar as events in a 'Finance Bills' calendar.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button(calService.access == .authorized ? "Synced to Calendar ✓" : "Request Calendar Access") { Task { await calService.requestAccess() } }
                        .buttonStyle(.borderedProminent).disabled(calService.access == .authorized)
                    Button("Sync Bills to Calendar (12 mo)") { sync() }.buttonStyle(.bordered).disabled(calService.access != .authorized)
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }

                Text("Scheduled income (\(incomes.count))").font(.headline)
                if incomes.isEmpty { Text("Add your payday below. Forecast estimates income from history until you do.").foregroundStyle(.secondary).font(.caption) }
                ForEach(incomes) { b in scheduleRow(b, isIncome: true) }

                Text("Recurring bills (\(expenses.count))").font(.headline)
                if expenses.isEmpty { Text("Add your first bill below.").foregroundStyle(.secondary) }
                ForEach(expenses) { b in scheduleRow(b, isIncome: false) }

                Text("Add scheduled transaction").font(.headline)
                Form {
                    Picker("Type", selection: $newIsIncome) {
                        Text("Bill (expense)").tag(false)
                        Text("Income (payday)").tag(true)
                    }.pickerStyle(.segmented)
                    TextField("Name", text: $newName)
                    TextField("Amount", text: $newAmount)
                    TextField(newIsIncome ? "Payday (day 1-28)" : "Due day (1-28)", text: $newDay)
                    if !newIsIncome {
                        Picker("Category", selection: $newCategory) { ForEach(BudgetService.allCategories(custom: customCategories.map(\.name)), id: \.self) { Text($0).tag($0) } }
                    }
                    Button(newIsIncome ? "Add Income Schedule" : "Add Recurring Bill") { addSchedule() }
                        .buttonStyle(.borderedProminent).disabled(newName.isEmpty || newAmount.isEmpty)
                }.formStyle(.grouped)

                Text("Upcoming in 30 days").font(.headline)
                ForEach(calService.upcomingBills(bills)) { b in
                    HStack {
                        Text(b.name)
                        Text(b.isIncome ? "INCOME" : "BILL")
                            .font(.caption2.bold()).padding(3)
                            .background(b.isIncome ? Color.green.opacity(0.2) : Color.red.opacity(0.15), in: Capsule())
                        Spacer()
                        Text("\(currency.string(from: NSNumber(value: b.amount)) ?? "") on day \(b.dueDay)")
                    }
                }
            }.padding()
        }
        .navigationTitle("Bills & Calendar")
        .task { await calService.requestAccess() }
    }

    private func scheduleRow(_ b: RecurringBill, isIncome: Bool) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(b.name).font(.headline)
                Text("\(b.category) • due day \(b.dueDay)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(currency.string(from: NSNumber(value: b.amount)) ?? "").monospacedDigit()
                .foregroundStyle(isIncome ? .green : .primary)
            Toggle("Active", isOn: Binding(get: { b.isActive }, set: { b.isActive = $0; try? context.save() })).font(.caption)
        }.padding(.vertical, 2)
    }

    private func addSchedule() {
        let cat = newIsIncome ? "Income" : newCategory
        let b = RecurringBill(name: newName, amount: Double(newAmount) ?? 0, dueDay: Int(newDay) ?? 15, category: cat, isIncome: newIsIncome)
        context.insert(b); try? context.save(); newName = ""; newAmount = ""
    }
    private func sync() {
        do { let n = try calService.syncBills(bills); status = "Synced \(n) events to Finance Bills calendar." }
        catch { status = "Sync failed: \(error.localizedDescription)" }
    }
}
