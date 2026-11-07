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

/// Settings section: add, rename and delete categories.
struct CategoriesSettingsSection: View {
    @Query(sort: \CustomCategory.name) var categories: [CustomCategory]
    @Query var transactions: [TransactionRecord]

    @State private var showingNew = false
    @State private var renaming: CustomCategory?
    @State private var deleting: CustomCategory?

    private var names: [String] { BudgetService.allCategories(stored: categories.map(\.name)) }

    var body: some View {
        Section {
            Text("Rename or delete any category. Renaming updates its transactions, budget, scheduled items and merchant rules. “Income” and “Uncategorized” are built into the app and can't be changed.")
                .font(.caption).foregroundStyle(.secondary)
            if categories.isEmpty { Text("No categories yet.").font(.caption).foregroundStyle(.secondary) }
            ForEach(categories) { c in
                HStack {
                    Text(c.name)
                    Spacer()
                    Text("\(usage(c.name)) transaction\(usage(c.name) == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Rename…") { renaming = c }.font(.caption)
                    Button("Delete…", role: .destructive) { deleting = c }.font(.caption)
                }
            }
            Button("Add Category…") { showingNew = true }
        } header: { Text("Categories") }
        .sheet(isPresented: $showingNew) {
            NewCategorySheet(existing: names, onCreate: { _ in showingNew = false }, onCancel: { showingNew = false })
        }
        .sheet(item: $renaming) { c in
            RenameCategorySheet(category: c, existing: names) { renaming = nil }
        }
        .sheet(item: $deleting) { c in
            DeleteCategorySheet(category: c, others: names.filter { $0 != c.name }, count: usage(c.name)) { deleting = nil }
        }
    }

    private func usage(_ name: String) -> Int { transactions.filter { $0.category == name }.count }
}

struct RenameCategorySheet: View {
    let category: CustomCategory
    let existing: [String]
    let onDone: () -> Void

    @Environment(\.modelContext) private var context
    @State private var name = ""
    @FocusState private var focused: Bool

    private var valid: String? { BudgetService.validatedRename(name, from: category.name, existing: existing) }
    private var collides: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != category.name && valid == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename “\(category.name)”").font(.headline)
            TextField("Category name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { save() }
            if collides {
                Text("That name is already used by another category (or is reserved). To combine two categories, delete one and move its transactions to the other.")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Rename") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(valid == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            name = category.name
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
        }
    }

    private func save() {
        guard let n = valid else { return }
        CategoryService.rename(category, to: n, in: context)
        onDone()
    }
}

struct DeleteCategorySheet: View {
    let category: CustomCategory
    let others: [String]
    let count: Int
    let onDone: () -> Void

    @Environment(\.modelContext) private var context
    @State private var target = Categorizer.uncategorized

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(category.name)”?").font(.headline)
            if count > 0 {
                Picker("Move its \(count) transaction\(count == 1 ? "" : "s") to", selection: $target) {
                    Text(Categorizer.uncategorized).tag(Categorizer.uncategorized)
                    Divider()
                    ForEach(others, id: \.self) { Text($0).tag($0) }
                }
            } else {
                Text("No transactions use this category.").foregroundStyle(.secondary)
            }
            Text("Scheduled items in this category move to the same place (or Other). Its budget amounts are added to the new category's budget for the same months, or dropped if Uncategorized. Merchant rules follow along or are forgotten.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Delete Category", role: .destructive) {
                    CategoryService.delete(category, moveTo: target, in: context)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
