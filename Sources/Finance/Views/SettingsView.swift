import SwiftUI
import SwiftData

struct SettingsView: View {
    @Query var profiles: [OFXProfile]
    @Environment(\.modelContext) private var context

    var body: some View {
        Form {
            Section("Privacy") {
                Text("All financial data is stored locally on your Mac (SwiftData + Keychain). No transactions, passwords, or calendar data leave the device except when you explicitly sync with your bank's OFX server or Apple Calendar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("OFX Profiles") {
                if profiles.isEmpty { Text("No direct OFX profiles. File import needs no setup.").font(.caption).foregroundStyle(.secondary) }
                ForEach(profiles) { p in
                    HStack {
                        VStack(alignment: .leading) { Text(p.bankName).font(.headline); Text("\(p.ofxHomeURL) • \(p.username)").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Delete", role: .destructive) {
                            KeychainStore.shared.deletePassword(for: p.id)
                            context.delete(p); try? context.save()
                        }.font(.caption)
                    }
                }
            }
            Section("Categories") {
                Text("Default envelope categories: \(BudgetService.defaultCategories.joined(separator: ", ")). Edit categories from the Transactions table.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                Text("Finance — native Mac app • SwiftUI + SwiftData + EventKit + Keychain. OFX 1.x/2.x parser built-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
