import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Query var profiles: [OFXProfile]
    @Query(sort: \CategoryRule.merchantKey) var rules: [CategoryRule]
    @Environment(\.modelContext) private var context
    @State private var backupNote = ""
    @State private var confirm: DataAction?

    enum DataAction: Identifiable { case restore(BackupFile), startNew; var id: String { switch self { case .restore: "restore"; case .startNew: "new" } } }

    var body: some View {
        Form {
            backupSection
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
            CategoriesSettingsSection()
            Section("Merchant rules") {
                Text("When you pick a category for a transaction, Finance remembers it for that merchant and applies it to future imports.")
                    .font(.caption).foregroundStyle(.secondary)
                if rules.isEmpty { Text("No rules learned yet.").font(.caption).foregroundStyle(.secondary) }
                ForEach(rules) { r in
                    HStack {
                        Text(r.merchantKey).font(.body.monospaced())
                        Spacer()
                        Text(r.category).foregroundStyle(.secondary)
                        Button("Forget", role: .destructive) {
                            context.delete(r); try? context.save()
                        }.font(.caption)
                    }
                }
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

// MARK: - Backup & new file

extension SettingsView {
    var backupSection: some View {
        Section("Backup & new file") {
            Text("Save everything (accounts, transactions, budget, schedules, rules) to a file you can keep or move to another Mac. Bank passwords are never included.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Back Up Data…") { backUp() }
                Button("Restore from Backup…") { chooseRestore() }
                Button("Start New Empty File…", role: .destructive) { confirm = .startNew }
            }
            if !backupNote.isEmpty { Text(backupNote).font(.caption).foregroundStyle(.secondary) }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button(confirmButton, role: .destructive) { performConfirmed() }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: {
            Text("A backup of your current data is saved automatically to Documents ▸ Finance Backups first. If iCloud sync is on, this also changes the data on your iPhone.")
        }
    }

    private var confirmTitle: String {
        switch confirm {
        case .restore(let f): return "Replace all data with this backup (\(f.summary))?"
        case .startNew: return "Erase everything and start a new empty file?"
        case nil: return ""
        }
    }
    private var confirmButton: String { if case .restore = confirm { return "Replace with Backup" } else { return "Erase and Start New" } }

    private func write(_ file: BackupFile, to url: URL) throws { try BackupService.encode(file).write(to: url, options: .atomic) }

    /// Safety copy before anything destructive.
    private func autoBackup() -> String? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Finance Backups")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(BackupService.suggestedName())
            try write(BackupService.snapshot(in: context), to: url)
            return url.lastPathComponent
        } catch { return nil }
    }

    private func backUp() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = BackupService.suggestedName()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snap = BackupService.snapshot(in: context)
        do { try write(snap, to: url); backupNote = "Saved \(snap.summary) to \(url.lastPathComponent)." }
        catch { backupNote = "Couldn't save the backup: \(error.localizedDescription)" }
    }

    private func chooseRestore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { confirm = .restore(try BackupService.decode(Data(contentsOf: url))) }
        catch { backupNote = "That file isn't a Finance backup: \(error.localizedDescription)" }
    }

    private func performConfirmed() {
        guard let action = confirm else { return }
        confirm = nil
        guard let saved = autoBackup() else { backupNote = "Couldn't save the safety backup, so nothing was changed."; return }
        switch action {
        case .restore(let f): BackupService.restore(f, in: context); backupNote = "Restored \(f.summary). Your previous data was saved as \(saved)."
        case .startNew: BackupService.startNew(in: context); backupNote = "Started a new empty file. Your previous data was saved as \(saved)."
        }
    }
}
