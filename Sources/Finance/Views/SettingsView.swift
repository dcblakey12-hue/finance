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
            if DemoMode.isOn {
                Section("Demo mode") {
                    Text(DemoMode.isShared
                         ? "You're looking at made-up data for showing the app. It has its own file and its own iCloud space, separate from your real data, so your iPhone can show the same demo (on the phone: Overview ▸ ••• ▸ Show Demo Data). It never goes to your banks or your calendar, and a fresh copy is made each time you start the demo. Your own data is untouched."
                         : "You're looking at made-up data for showing the app. It has its own file on this Mac, never goes to iCloud, your banks or your calendar, and a fresh copy is made each time you start the demo. Your own data is untouched.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Leave Demo Mode…") { DemoMode.confirmAndSwitch() }
                }
            }
            SpendingAlertSettings()
            backupSection
            if !DemoMode.isOn { PlaidSettingsSection() }
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


// MARK: - Plaid bank connections

struct PlaidSettingsSection: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.name) private var accounts: [Account]
    @AppStorage(PlaidClient.envKey) private var envRaw = PlaidClient.Environment.sandbox.rawValue
    @State private var clientId = ""
    @State private var secret = ""
    @State private var items = PlaidStore.items()
    @State private var status = ""
    @State private var busy = false
    @State private var linking: Task<Void, Never>?
    @State private var hasKeys = PlaidClient().hasKeys
    @EnvironmentObject private var syncer: SyncCoordinator

    var body: some View {
        Section("Bank connections (Plaid)") {
            Text("Connect your banks through Plaid to download transactions and balances automatically. Your Plaid keys and the bank access tokens stay in this Mac's Keychain; the iPhone gets the data through iCloud.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Environment", selection: $envRaw) {
                Text("Sandbox (fake banks, for testing)").tag(PlaidClient.Environment.sandbox.rawValue)
                Text("Production (your real banks)").tag(PlaidClient.Environment.production.rawValue)
            }
            HStack {
                TextField("Client ID", text: $clientId).textFieldStyle(.roundedBorder)
                SecureField(hasKeys ? "Secret (saved — type to replace)" : "Secret", text: $secret).textFieldStyle(.roundedBorder)
                Button("Save Keys") {
                    let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
                    let sec = secret.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !id.isEmpty { SecretStore.set(id, for: PlaidClient.clientIdKey) }
                    if !sec.isEmpty { SecretStore.set(sec, for: PlaidClient.secretKey) }
                    clientId = ""; secret = ""
                    hasKeys = PlaidClient().hasKeys
                    status = hasKeys ? "Keys saved to your Keychain." : "Enter both the client ID and the secret."
                }.disabled(clientId.isEmpty && secret.isEmpty)
            }
            Text("Use the secret that matches the environment above (Plaid shows a separate Sandbox and Production secret). Never share these keys.")
                .font(.caption2).foregroundStyle(.secondary)

            HStack {
                Button("Connect a Bank…") { connect() }.disabled(!hasKeys || busy || linking != nil)
                if linking != nil {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in to your bank in the browser…").font(.caption)
                    Button("Cancel") { linking?.cancel(); linking = nil; status = "Cancelled." }
                }
                Spacer()
                if items.count > 1 { Button("Sync All") { syncAll() }.disabled(busy) }
            }

            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.institution).font(.headline)
                        Text(item.lastSync.map { "synced \($0.formatted(.relative(presentation: .named)))" } ?? "not synced yet")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Sync Now") { syncOne(item.itemId) }.disabled(busy || syncer.reconnecting != nil)
                        Button("Reconnect…") { syncer.reconnect(item.itemId, in: context) }
                            .disabled(busy || syncer.busy || syncer.reconnecting != nil)
                            .help("Sign in to this bank again through Plaid when it asks for it. Keeps the same connection and history; no duplicates.")
                        Button("Remove", role: .destructive) {
                            PlaidStore.remove(item.itemId); items = PlaidStore.items()
                            PlaidSync.forgetUnlinked(in: context)
                        }
                    }
                    if syncer.reconnecting == item.itemId {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Finish signing in to \(item.institution) in your browser…").font(.caption)
                            Button("Cancel") { syncer.cancelReconnect() }
                        }
                    } else if let problem = failure(of: item) {
                        Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(item.accounts) { pa in
                        Picker("\(pa.name)\(pa.mask.map { " ••\($0)" } ?? "")", selection: mapping(item.itemId, pa.accountId)) {
                            Text("New account").tag("")
                            ForEach(accounts) { Text($0.name).tag($0.accountId) }
                        }
                    }
                    Text("Pick an account you already have to feed it, or leave on New account. Choose before the first sync; anything already imported from files is matched, not duplicated.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
    }

    /// What's wrong with a bank connection, if its accounts' last sync failed.
    private func failure(of item: PlaidItem) -> PlaidProblem? {
        let ids = PlaidSync.targets(of: item)
        return accounts.lazy.filter { ids.contains($0.accountId) }.compactMap { PlaidSyncStatus($0)?.problem }.first
    }

    private func mapping(_ itemId: String, _ plaidAccount: String) -> Binding<String> {
        Binding(
            get: { items.first { $0.itemId == itemId }?.accountMap[plaidAccount].flatMap { $0.hasPrefix(PlaidMapping.prefix) ? "" : $0 } ?? "" },
            set: { v in
                guard let i = items.firstIndex(where: { $0.itemId == itemId }) else { return }
                items[i].accountMap[plaidAccount] = v.isEmpty ? nil : v
                PlaidStore.save(items)
                PlaidSync.forgetUnlinked(in: context)
            })
    }

    private func connect() {
        status = "Opening Plaid…"
        linking = Task {
            let client = PlaidClient()
            do {
                let (token, url) = try await client.startLink()
                NSWorkspace.shared.open(url)
                for _ in 0..<300 {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    if let done = try await client.finishedLink(token) {
                        let ex = try await client.exchange(done.publicToken)
                        PlaidStore.setToken(ex.accessToken, for: ex.itemId)
                        var all = PlaidStore.items().filter { $0.itemId != ex.itemId }
                        all.append(PlaidItem(itemId: ex.itemId, institution: done.institution, accounts: try await client.accounts(ex.accessToken)))
                        PlaidStore.save(all)
                        items = all
                        status = "Connected \(done.institution). Choose which of your accounts each one feeds, then Sync Now."
                        linking = nil
                        return
                    }
                }
                status = "Timed out waiting for the bank sign-in. Try Connect a Bank again."
            } catch is CancellationError {
            } catch { status = "Couldn't connect: \(error.localizedDescription)" }
            linking = nil
        }
    }

    private func syncOne(_ id: String) {
        busy = true; status = "Syncing…"
        Task {
            do { status = try await PlaidSync.sync(id, in: context) } catch { status = "Sync failed: \(error.localizedDescription)" }
            items = PlaidStore.items(); busy = false
        }
    }

    private func syncAll() {
        busy = true; status = "Syncing all banks…"
        Task {
            var lines: [String] = []
            for item in PlaidStore.items() {
                do { lines.append(try await PlaidSync.sync(item.itemId, in: context)) }
                catch { lines.append("\(item.institution): \(error.localizedDescription)") }
            }
            status = lines.joined(separator: " ")
            items = PlaidStore.items(); busy = false
        }
    }
}
