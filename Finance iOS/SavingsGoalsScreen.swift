import SwiftUI
import SwiftData

/// The phone's savings goals (opened from the Overview card). Tap a goal to edit it; swipe for more.
struct SavingsGoalsScreen: View {
    @Query(sort: \SavingsGoal.createdAt) private var goals: [SavingsGoal]
    @Query private var accounts: [Account]
    @Query private var transactions: [TransactionRecord]
    @Environment(\.modelContext) private var context

    private struct Editing: Identifiable { let id = UUID(); let goal: SavingsGoal? }
    @State private var editing: Editing?
    @State private var draft = GoalDraft()
    @State private var adding: SavingsGoal?
    @State private var amount: Double?
    @State private var takeOut = false

    private var names: [String: String] { Dictionary(accounts.map { ($0.accountId, $0.name) }, uniquingKeysWith: { a, _ in a }) }

    var body: some View {
        List {
            if goals.isEmpty {
                Section {
                    Text("Set a target, like a trip or an emergency fund, and see how close you are and when you'll get there.")
                        .foregroundStyle(.secondary)
                    Button("Add a Goal") { startEditing(nil) }
                }
            }
            ForEach([false, true], id: \.self) { archived in
                let list = goals.filter { $0.isArchived == archived }
                if !list.isEmpty {
                    Section(archived ? "Reached and put away" : "Goals") {
                        ForEach(list) { g in row(g) }
                    }
                }
            }
        }
        .navigationTitle("Savings Goals")
        .toolbar { Button { startEditing(nil) } label: { Image(systemName: "plus") } }
        .sheet(item: $editing) { e in
            NavigationStack {
                Form { GoalEditorForm(draft: $draft, isNew: e.goal == nil, accounts: goalAccounts(accounts)) }
                    .navigationTitle(e.goal == nil ? "New Goal" : "Edit Goal")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { draft.save(existing: e.goal, in: context); editing = nil }.disabled(!draft.isValid)
                        }
                    }
            }
        }
        .sheet(item: $adding) { g in
            NavigationStack {
                Form { AddToGoalForm(goal: g, amount: $amount, takeOut: $takeOut) }
                    .navigationTitle(g.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(takeOut ? "Take Out" : "Add") {
                                SavingsGoalService.add((takeOut ? -1 : 1) * abs(amount ?? 0), to: g, in: context)
                                adding = nil
                            }.disabled((amount ?? 0) == 0)
                        }
                    }
            }
            .presentationDetents([.medium])
        }
    }

    private func row(_ g: SavingsGoal) -> some View {
        Button { startEditing(g) } label: {
            SavingsGoalCard(goal: g, progress: SavingsGoalService.progress(g, accounts: accounts, transactions: transactions),
                            accountName: g.accountId.flatMap { names[$0] })
                .foregroundStyle(Color.primary)
        }
        .swipeActions(edge: .leading) {
            if g.accountId == nil {
                Button("Add") { amount = nil; takeOut = false; adding = g }.tint(.green)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { context.delete(g); try? context.save() }
            Button(g.isArchived ? "Bring Back" : "Put Away") { g.isArchived.toggle(); try? context.save() }.tint(.gray)
        }
    }

    private func startEditing(_ g: SavingsGoal?) {
        draft = g.map(GoalDraft.init) ?? GoalDraft()
        editing = Editing(goal: g)
    }
}

/// The Overview card's contents: up to three goals, tap to open them all.
struct GoalsOverviewContent: View {
    let goals: [SavingsGoal]
    let accounts: [Account]
    let transactions: [TransactionRecord]

    var body: some View {
        let active = goals.filter { !$0.isArchived }
        NavigationLink { SavingsGoalsScreen() } label: {
            VStack(alignment: .leading, spacing: 10) {
                if active.isEmpty {
                    HStack {
                        Text("Set a goal, like a trip or an emergency fund.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                ForEach(active.prefix(3)) { g in
                    SavingsGoalCard(goal: g, progress: SavingsGoalService.progress(g, accounts: accounts, transactions: transactions), compact: true)
                }
                if active.count > 3 {
                    Text("and \(active.count - 3) more ›").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
