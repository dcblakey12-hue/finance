import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Query var profiles: [OFXProfile]
    @Query(sort: \CategoryRule.merchantKey) var rules: [CategoryRule]
    @Environment(\.modelContext) private var context
    private var backup: BackupCoordinator { .shared }

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

// MARK: - Backup & new file (also in the File menu)

extension SettingsView {
    var backupSection: some View {
        Section("Backup & new file") {
            Text("Save everything (accounts, transactions, budget, schedules, rules) to a file you can keep or move to another Mac. Bank passwords are never included. These are also in the File menu.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Back Up Data…") { backup.backUp(context) }
                Button("Restore from Backup…") { backup.chooseRestore(context) }
                Button("Start New Empty File…", role: .destructive) { backup.startNew(context) }
            }
            if !backup.note.isEmpty { Text(backup.note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Backup / restore / new-file actions, shared by the File menu and Settings.
@MainActor @Observable
final class BackupCoordinator {
    static let shared = BackupCoordinator()
    var note = ""

    private func write(_ file: BackupFile, to url: URL) throws { try BackupService.encode(file).write(to: url, options: .atomic) }

    /// Safety copy before anything destructive.
    private func autoBackup(_ context: ModelContext) -> String? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Finance Backups")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(BackupService.suggestedName())
            try write(BackupService.snapshot(in: context), to: url)
            return url.lastPathComponent
        } catch { return nil }
    }

    private func confirm(_ title: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = "A backup of your current data is saved automatically to Documents ▸ Finance Backups first. If iCloud sync is on, this also changes the data on your iPhone."
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func report(_ text: String) {
        note = text
        let alert = NSAlert(); alert.messageText = text; alert.runModal()
    }

    func backUp(_ context: ModelContext) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = BackupService.suggestedName()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snap = BackupService.snapshot(in: context)
        do { try write(snap, to: url); report("Saved \(snap.summary) to \(url.lastPathComponent).") }
        catch { report("Couldn't save the backup: \(error.localizedDescription)") }
    }

    func chooseRestore(_ context: ModelContext) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let file: BackupFile
        do { file = try BackupService.decode(Data(contentsOf: url)) }
        catch { report("That file isn't a Finance backup: \(error.localizedDescription)"); return }
        guard confirm("Replace all data with this backup (\(file.summary))?", button: "Replace with Backup") else { return }
        guard let saved = autoBackup(context) else { report("Couldn't save the safety backup, so nothing was changed."); return }
        BackupService.restore(file, in: context)
        report("Restored \(file.summary). Your previous data was saved as \(saved).")
    }

    func startNew(_ context: ModelContext) {
        guard confirm("Erase everything and start a new empty file?", button: "Erase and Start New") else { return }
        guard let saved = autoBackup(context) else { report("Couldn't save the safety backup, so nothing was changed."); return }
        BackupService.startNew(in: context)
        report("Started a new empty file. Your previous data was saved as \(saved).")
    }
}
