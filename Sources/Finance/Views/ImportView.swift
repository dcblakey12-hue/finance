import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportView: View {
    @Environment(\.modelContext) private var context
    @State private var showingPicker = false
    @State private var preview: ParsedOFXFile?
    @State private var status = ""
    @State private var isImporting = false

    // OFX server sync
    @Query var profiles: [OFXProfile]
    @State private var bankName = ""
    @State private var ofxURL = ""
    @State private var username = ""
    @State private var acctId = ""
    @State private var password = ""
    @State private var syncStatus = ""
    @State private var isSyncing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Import & Sync").font(.largeTitle.bold())

                VStack(alignment: .leading, spacing: 8) {
                    Text("Import OFX file (recommended — works with every bank)").font(.headline)
                    Text("Download an .ofx statement from your bank website, then import it. Files are deduplicated by FITID, so you can re-import safely. Nothing leaves your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Choose OFX File…") { showingPicker = true }
                        .buttonStyle(.borderedProminent)
                    if let p = preview {
                        Text("Found \(p.transactions.count) transactions — \(p.accountName) (•••\(p.accountId.suffix(4))) • Bank \(p.bankId)")
                            .font(.callout)
                        if let org = p.institutionOrg {
                            Text("Institution: \(org)\(p.institutionFid.map { " (FID \($0))" } ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Import \(p.transactions.count) Transactions") { doImport() }
                                .buttonStyle(.borderedProminent).disabled(isImporting)
                            Button("Use for Server Sync") { prefillSync(from: p) }
                                .help("Fill the server sync form below with this file's bank name and account ID")
                        }
                    }
                    if !status.isEmpty { Text(status).font(.caption) }
                }
                .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 8) {
                    Text("OFX server sync (where your bank still supports it)").font(.headline)
                    Text("An OFX file doesn't include the server address. Enter the bank's OFX URL (search for your bank's “OFX Direct Connect” URL, or ask the bank). Password is stored only in your Keychain. Many banks have disabled direct OFX — file import above is the fallback.")
                        .font(.caption).foregroundStyle(.secondary)
                    Form {
                        TextField("Bank name / ID", text: $bankName)
                        TextField("OFX URL (https://…)", text: $ofxURL)
                        TextField("Username", text: $username)
                        TextField("Account ID", text: $acctId)
                        SecureField("Password (stored in Keychain)", text: $password)
                        Button(isSyncing ? "Syncing…" : "Save & Sync") { syncDirect() }
                            .buttonStyle(.borderedProminent).disabled(isSyncing || ofxURL.isEmpty || username.isEmpty)
                    }.formStyle(.grouped)
                    if !syncStatus.isEmpty { Text(syncStatus).font(.caption) }
                    ForEach(profiles) { p in
                        HStack { Text("\(p.bankName) • \(p.username)"); Spacer(); Text(p.lastSync?.formatted(date: .abbreviated, time: .omitted) ?? "Never synced").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }.padding()
        }
        .navigationTitle("Import & Sync")
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.data, .plainText], allowsMultipleSelection: false) { result in
            handlePicker(result)
        }
    }

    private func handlePicker(_ result: Result<[URL], Error>) {
        do {
            let url = try result.get().first!
            guard url.startAccessingSecurityScopedResource() else { status = "Cannot access file."; return }
            defer { url.stopAccessingSecurityScopedResource() }
            let data = try Data(contentsOf: url)
            preview = try OFXParser.shared.parse(data: data)
            status = ""
        } catch { status = "Parse failed: \(error.localizedDescription)" }
    }

    private func prefillSync(from p: ParsedOFXFile) {
        let name = p.institutionOrg ?? p.bankId
        bankName = [name, p.institutionFid.map { "FID \($0)" }].compactMap { $0 }.joined(separator: " ")
        acctId = p.accountId
        syncStatus = "Filled in bank and account ID. Add the OFX URL and your username."
    }

    private func doImport() {
        guard let p = preview else { return }
        isImporting = true
        Task { @MainActor in
            let (inserted, skipped) = await TransactionImportService().importParsed(p, into: context)
            status = "Imported \(inserted) new transactions. Skipped \(skipped) duplicates."
            preview = nil; isImporting = false
        }
    }

    private func syncDirect() {
        isSyncing = true; syncStatus = "Connecting…"
        Task {
            do {
                let profile = OFXProfile(bankName: bankName, ofxHomeURL: ofxURL, username: username, accountId: acctId)
                try KeychainStore.shared.savePassword(password, for: profile.id)
                context.insert(profile); try? context.save()
                let parsed = try await OFXClient().downloadStatement(profile: profile, password: password)
                await MainActor.run {
                    let (ins, skip) = TransactionImportService().importParsed(parsed, into: context)
                    syncStatus = "Sync complete: \(ins) new, \(skip) duplicates."
                    profile.lastSync = Date(); try? context.save()
                    password = ""
                }
            } catch {
                await MainActor.run { syncStatus = "Sync failed: \(error.localizedDescription)" }
            }
            await MainActor.run { isSyncing = false }
        }
    }
}
