import SwiftUI
import SwiftData

private func goalMoney(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "" }

/// One goal: name, progress bar, saved of target, and how it's going.
struct SavingsGoalCard: View {
    let goal: SavingsGoal
    let progress: GoalProgress
    /// Name of the linked account, if any.
    var accountName: String? = nil
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: goal.symbol).foregroundStyle(progress.isReached ? .green : .accentColor).frame(width: 22)
                Text(goal.name).font(.headline).lineLimit(1)
                Spacer()
                Text("\(Int((progress.fraction * 100).rounded()))%").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: progress.fraction)
                .tint(progress.isReached ? .green : (progress.onTrack == false ? .orange : .accentColor))
            HStack {
                Text("\(goalMoney(progress.saved)) of \(goalMoney(progress.target))").font(.callout.monospacedDigit())
                Spacer()
                if let d = progress.targetDate {
                    Text("by \(d.formatted(.dateTime.month(.abbreviated).year()))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !compact {
                Text(SavingsGoalService.summary(progress))
                    .font(.caption).foregroundStyle(progress.onTrack == false ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(accountName.map { "Counts the balance of \($0)" } ?? "Tracked by hand")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Values being edited, for a new goal or an existing one.
struct GoalDraft {
    var name = ""
    var target: Double? = nil
    var hasDate = false
    var targetDate = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    /// "" = tracked by hand.
    var accountId = ""
    /// Starting amount for a goal tracked by hand.
    var startingAmount: Double? = nil
    var symbol = "star"

    init() {}
    init(_ g: SavingsGoal) {
        name = g.name; target = g.target; hasDate = g.targetDate != nil
        targetDate = g.targetDate ?? targetDate; accountId = g.accountId ?? ""; symbol = g.symbol
    }
    var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && (target ?? 0) > 0 }

    @MainActor
    func save(existing: SavingsGoal?, in context: ModelContext) {
        let g = existing ?? SavingsGoal(name: "", target: 0)
        g.name = name.trimmingCharacters(in: .whitespaces)
        g.target = target ?? 0
        g.targetDate = hasDate ? targetDate : nil
        g.accountId = accountId.isEmpty ? nil : accountId
        g.symbol = symbol
        if existing == nil {
            context.insert(g)
            if accountId.isEmpty, let start = startingAmount, start > 0 { g.savedByHand = start }
        }
        try? context.save()
    }
}

/// The form for adding or editing a goal (shared by the Mac and iPhone).
struct GoalEditorForm: View {
    @Binding var draft: GoalDraft
    let isNew: Bool
    /// Accounts that can hold savings.
    let accounts: [Account]

    var body: some View {
        Section {
            TextField("Name (e.g. Summer trip)", text: $draft.name)
            TextField("Target amount", value: $draft.target, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
            Toggle("Reach it by a date", isOn: $draft.hasDate)
            if draft.hasDate {
                DatePicker("Target date", selection: $draft.targetDate, in: Date()..., displayedComponents: .date)
            }
            Picker("Icon", selection: $draft.symbol) {
                ForEach(SavingsGoalService.symbols, id: \.self) { s in Label(s, systemImage: s).labelStyle(.iconOnly).tag(s) }
            }
        }
        Section {
            Picker("Saved in", selection: $draft.accountId) {
                Text("Tracked by hand").tag("")
                ForEach(accounts) { a in Text(a.name).tag(a.accountId) }
            }
            if draft.accountId.isEmpty && isNew {
                TextField("Already saved (optional)", value: $draft.startingAmount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
            }
        } footer: {
            Text(draft.accountId.isEmpty
                 ? "Add money to the goal yourself as you save."
                 : "The account's balance counts as saved, and money going into it sets your pace. Best for an account kept just for this goal.")
        }
    }
}

/// Add or take out money on a goal tracked by hand.
struct AddToGoalForm: View {
    let goal: SavingsGoal
    @Binding var amount: Double?
    @Binding var takeOut: Bool
    var body: some View {
        Section {
            Picker("", selection: $takeOut) {
                Text("Add money").tag(false)
                Text("Take money out").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            TextField("Amount", value: $amount, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))
        } footer: {
            Text("\(goal.name): \(goalMoney(goal.savedByHand)) saved so far.")
        }
    }
}

/// Accounts a goal can be linked to: savings, checking, cash and investments.
func goalAccounts(_ accounts: [Account]) -> [Account] {
    accounts.filter { [.savings, .checking, .cash, .investment].contains($0.type) }.sorted { $0.name < $1.name }
}
