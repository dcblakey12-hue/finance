import SwiftUI
import SwiftData

/// Small sheet for naming a new category. Calls `onCreate` with the saved name.
struct NewCategorySheet: View {
    let existing: [String]
    let onCreate: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var context
    @State private var name = ""
    @FocusState private var focused: Bool

    private var validName: String? { BudgetService.validatedNewCategory(name, existing: existing) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Category").font(.headline)
            TextField("e.g. Pets, Travel, Kids", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { create() }
            if !name.trimmingCharacters(in: .whitespaces).isEmpty && validName == nil {
                Text("That category already exists.").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Add Category") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validName == nil)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true } }
    }

    private func create() {
        guard let n = validName else { return }
        context.insert(CustomCategory(name: n))
        try? context.save()
        onCreate(n)
    }
}

/// Settings section: shows default categories and lets the user add/remove their own.
struct CategoriesSettingsSection: View {
    @Query(sort: \CustomCategory.name) var custom: [CustomCategory]
    @Query var transactions: [TransactionRecord]
    @Query var schedules: [RecurringBill]
    @Environment(\.modelContext) private var context

    @State private var showingNew = false
    @State private var pendingDelete: CustomCategory?

    var body: some View {
        Section {
            Text("Built in: \(BudgetService.defaultCategories.joined(separator: ", ")).")
                .font(.caption).foregroundStyle(.secondary)
            if custom.isEmpty { Text("No custom categories yet.").font(.caption).foregroundStyle(.secondary) }
            ForEach(custom) { c in
                HStack {
                    Text(c.name)
                    Spacer()
                    Text("\(usage(c.name)) transactions").font(.caption).foregroundStyle(.secondary)
                    Button("Delete", role: .destructive) { pendingDelete = c }.font(.caption)
                }
            }
            Button("Add Category…") { showingNew = true }
        } header: { Text("Categories") }
        .sheet(isPresented: $showingNew) {
            NewCategorySheet(existing: BudgetService.allCategories(custom: custom.map(\.name)),
                             onCreate: { _ in showingNew = false }, onCancel: { showingNew = false })
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Category", role: .destructive) {
                if let c = pendingDelete { delete(c) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Its transactions become Uncategorized, its scheduled transactions move to Other, and its budget envelopes and merchant rules are removed.")
        }
    }

    private func usage(_ name: String) -> Int { transactions.filter { $0.category == name }.count }

    private func delete(_ c: CustomCategory) {
        let name = c.name
        for tx in transactions where tx.category == name { tx.category = Categorizer.uncategorized }
        for s in schedules where s.category == name { s.category = "Other" }
        let envs = (try? context.fetch(FetchDescriptor<Envelope>(predicate: #Predicate { $0.category == name }))) ?? []
        envs.forEach { context.delete($0) }
        let rules = (try? context.fetch(FetchDescriptor<CategoryRule>(predicate: #Predicate { $0.category == name }))) ?? []
        rules.forEach { context.delete($0) }
        context.delete(c)
        try? context.save()
    }
}
