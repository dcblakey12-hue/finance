import SwiftUI
import SwiftData

/// Sidebar section: what you're saving up for, how far along you are, and when you'll get there.
struct SavingsGoalsView: View {
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
    @State private var deleting: SavingsGoal?
    @State private var showArchived = false

    private var names: [String: String] { Dictionary(accounts.map { ($0.accountId, $0.name) }, uniquingKeysWith: { a, _ in a }) }
    private func money(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }

    var body: some View {
        let active = goals.filter { !$0.isArchived }
        let archived = goals.filter(\.isArchived)
        let progress = Dictionary(goals.map { ($0.id, SavingsGoalService.progress($0, accounts: accounts, transactions: transactions)) },
                                  uniquingKeysWith: { a, _ in a })
        let saved = active.reduce(0) { $0 + (progress[$1.id]?.saved ?? 0) }
        let target = active.reduce(0) { $0 + $1.target }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !active.isEmpty {
                    HStack(spacing: 24) {
                        total("Saved toward goals", money(saved))
                        total("Still to go", money(max(0, target - saved)))
                        total("Goals", "\(active.count)")
                        Spacer()
                    }
                }
                if goals.isEmpty {
                    ContentUnavailableView {
                        Label("No savings goals yet", systemImage: "target")
                    } description: {
                        Text("Set a target, like a trip or an emergency fund, and see how close you are and when you'll get there.")
                    } actions: {
                        Button("Add a Goal") { startEditing(nil) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                    ForEach(active) { g in card(g, progress[g.id]) }
                }
                if !archived.isEmpty {
                    DisclosureGroup("Reached and put away (\(archived.count))", isExpanded: $showArchived) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                            ForEach(archived) { g in card(g, progress[g.id]).opacity(0.7) }
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Savings Goals")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button { startEditing(nil) } label: { Label("Add Goal", systemImage: "plus") } }
        }
        .sheet(item: $editing) { e in
            NavigationStack {
                Form { GoalEditorForm(draft: $draft, isNew: e.goal == nil, accounts: goalAccounts(accounts)) }
                    .formStyle(.grouped)
                    .navigationTitle(e.goal == nil ? "New Goal" : "Edit Goal")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { draft.save(existing: e.goal, in: context); editing = nil }.disabled(!draft.isValid)
                        }
                    }
            }
            .frame(minWidth: 460, minHeight: 420)
        }
        .sheet(item: $adding) { g in
            NavigationStack {
                Form { AddToGoalForm(goal: g, amount: $amount, takeOut: $takeOut) }
                    .formStyle(.grouped)
                    .navigationTitle(g.name)
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
            .frame(minWidth: 380, minHeight: 240)
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let g = deleting { context.delete(g); try? context.save() }
                deleting = nil
            }
        } message: { Text("The goal goes away. Your accounts and transactions aren't touched.") }
    }

    private func card(_ g: SavingsGoal, _ p: GoalProgress?) -> some View {
        let p = p ?? SavingsGoalService.progress(g, accounts: accounts, transactions: transactions)
        return VStack(alignment: .leading, spacing: 10) {
            SavingsGoalCard(goal: g, progress: p, accountName: g.accountId.flatMap { names[$0] })
            HStack {
                if g.accountId == nil {
                    Button("Add Money…") { amount = nil; takeOut = false; adding = g }
                }
                Spacer()
                Menu {
                    Button("Edit…") { startEditing(g) }
                    Button(g.isArchived ? "Bring Back" : "Put Away") { g.isArchived.toggle(); try? context.save() }
                    Divider()
                    Button("Delete…", role: .destructive) { deleting = g }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .onTapGesture(count: 2) { startEditing(g) }
    }

    private func startEditing(_ g: SavingsGoal?) {
        draft = g.map(GoalDraft.init) ?? GoalDraft()
        editing = Editing(goal: g)
    }

    private func total(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
        }
    }
}
