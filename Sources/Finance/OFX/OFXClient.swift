import Foundation
import Security
import SwiftData
import Combine
import AppKit

/// Direct OFX server client (OFXHome). Many banks no longer support this;
/// file import is the reliable path. This client exists so both modes work
/// where a bank still exposes OFX.
actor OFXClient {
    private let session: URLSession
    private let parser = OFXParser.shared

    init(session: URLSession = .shared) { self.session = session }

    func downloadStatement(profile: OFXProfile, password: String) async throws -> ParsedOFXFile {
        guard let url = URL(string: profile.ofxHomeURL) else {
            throw NSError(domain: "OFX", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid OFX URL"])
        }
        // Replace placeholder password safely by rebuilding body.
        let body = OFXRequestBuilder.buildStatementRequest(profile: profile)
            .replacingOccurrences(of: "***STORED_IN_KEYCHAIN***", with: password)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-ofx", forHTTPHeaderField: "Content-Type")
        req.setValue("application/x-ofx", forHTTPHeaderField: "Accept")
        req.httpBody = body.data(using: .utf8)
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "OFX", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "OFX server returned HTTP \(http.statusCode). Your bank may have disabled direct OFX — use file import instead."])
        }
        return try parser.parse(data: data)
    }
}

/// Stores OFX passwords in macOS Keychain per profile. Never persists plaintext to disk.
final class KeychainStore: Sendable {
    static let shared = KeychainStore()
    private init() {}

    private func key(for profileID: UUID) -> String { "finance.ofx.password.\(profileID.uuidString)" }

    func savePassword(_ password: String, for profileID: UUID) throws {
        let service = "com.finance.app"
        let data = password.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key(for: profileID),
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            throw NSError(domain: "Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Cannot save password to Keychain"])
        }
    }

    func password(for profileID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.finance.app",
            kSecAttrAccount as String: key(for: profileID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    func deletePassword(for profileID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.finance.app",
            kSecAttrAccount as String: key(for: profileID),
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Plaid

/// Small generic Keychain helper for the Plaid keys and access tokens (this Mac only, never synced).
enum SecretStore {
    private static let service = "com.finance.app.plaid"
    /// Everything (client ID, secret, bank tokens) lives in ONE Keychain item, so macOS asks for the
    /// password at most once per launch instead of once per secret.
    private static let vaultAccount = "vault"
    private static var vault: [String: String]?
    private static let lock = NSLock()

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func loadVault() -> [String: String] {
        if let vault { return vault }
        var loaded: [String: String] = [:]
        var q = baseQuery(vaultAccount)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data,
           let v = try? JSONDecoder().decode([String: String].self, from: d) {
            loaded = v
        } else {
            // First run after the upgrade: fold the old one-item-per-secret entries into the vault.
            var all: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                      kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
            var found: CFTypeRef?
            if SecItemCopyMatching(all as CFDictionary, &found) == errSecSuccess, let rows = found as? [[String: Any]] {
                for row in rows {
                    guard let account = row[kSecAttrAccount as String] as? String, account != vaultAccount else { continue }
                    var one = baseQuery(account)
                    one[kSecReturnData as String] = true; one[kSecMatchLimit as String] = kSecMatchLimitOne
                    var data: CFTypeRef?
                    if SecItemCopyMatching(one as CFDictionary, &data) == errSecSuccess, let d = data as? Data,
                       let str = String(data: d, encoding: .utf8) { loaded[account] = str }
                }
                all[kSecReturnAttributes as String] = nil
                if !loaded.isEmpty { saveVault(loaded) }
            }
        }
        vault = loaded
        return loaded
    }

    private static func saveVault(_ v: [String: String]) {
        guard let data = try? JSONEncoder().encode(v) else { return }
        SecItemDelete(baseQuery(vaultAccount) as CFDictionary)
        var a = baseQuery(vaultAccount)
        a[kSecValueData as String] = data
        a[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(a as CFDictionary, nil)
    }

    static func set(_ value: String, for key: String) {
        lock.lock(); defer { lock.unlock() }
        var v = loadVault()
        if value.isEmpty { v[key] = nil } else { v[key] = value }
        vault = v
        saveVault(v)
        SecItemDelete(baseQuery(key) as CFDictionary)     // drop any old per-secret item
    }

    static func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loadVault()[key]
    }
}

/// One linked bank (a Plaid "Item"). The access token itself is in the Keychain, keyed by `itemId`.
struct PlaidItem: Codable, Identifiable, Equatable {
    var itemId: String
    var institution: String
    var cursor: String? = nil
    var lastSync: Date? = nil
    /// Plaid account_id → the app's Account.accountId it feeds. Missing = a new account is created on sync.
    var accountMap: [String: String] = [:]
    var accounts: [PlaidAccountInfo] = []
    var id: String { itemId }
}

struct PlaidAccountInfo: Codable, Equatable, Identifiable {
    var accountId: String
    var name: String
    var mask: String?
    var type: String         // depository | credit | loan | investment | other
    var subtype: String?
    var current: Double?
    var id: String { accountId }

    var appType: AccountType {
        switch (type, subtype ?? "") {
        case ("credit", _): return .creditCard
        case ("loan", "mortgage"): return .mortgage
        case ("loan", _): return .mortgage
        case ("investment", _): return .investment
        case (_, "savings"), (_, "money market"), (_, "cd"): return .savings
        case (_, "cash management"): return .cash
        default: return .checking
        }
    }
    /// Plaid reports what you owe on cards and loans as a positive number; the app stores it negative.
    var appBalance: Double? {
        guard let c = current else { return nil }
        return (type == "credit" || type == "loan") ? -c : c
    }
}

struct PlaidTransactionDTO: Codable, Equatable {
    var transaction_id: String
    var account_id: String
    var amount: Double          // Plaid: positive = money out
    var date: String            // yyyy-MM-dd
    var name: String
    var merchant_name: String?
    var pending: Bool
}

/// Pure conversion and matching, separate from networking so it can be tested.
enum PlaidMapping {
    static let prefix = "plaid-"

    static func date(_ s: String, calendar: Calendar = .current) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }

    static func convert(_ t: PlaidTransactionDTO, accountId: String, calendar: Calendar = .current) -> OFXTransaction? {
        guard !t.pending, let d = date(t.date, calendar: calendar) else { return nil }
        let signed = -t.amount
        let name = (t.merchant_name?.isEmpty == false ? t.merchant_name! : t.name)
        return OFXTransaction(fitid: prefix + t.transaction_id, accountId: accountId, date: d, name: name, amount: signed,
                              type: signed < 0 ? .debit : .credit, memo: "")
    }

    /// Plaid's first sync can include transactions already imported from OFX files. Pair each one with
    /// an existing, unclaimed record of the same amount within 2 days so it isn't added twice.
    /// Returns the Plaid transactions that are genuinely new and the existing records to re-tag.
    @MainActor
    static func splitKnown(_ incoming: [OFXTransaction], existing: [TransactionRecord],
                           calendar: Calendar = .current) -> (new: [OFXTransaction], adopt: [(record: TransactionRecord, fitid: String)]) {
        var pool = existing.filter { !$0.fitid.hasPrefix(prefix) && !ManualTransactionService.isManual($0) }
        var new: [OFXTransaction] = [], adopt: [(record: TransactionRecord, fitid: String)] = []
        for t in incoming {
            if let i = pool.firstIndex(where: {
                $0.amount == t.amount &&
                abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: $0.date), to: calendar.startOfDay(for: t.date)).day ?? 99) <= 2
            }) {
                adopt.append((record: pool.remove(at: i), fitid: t.fitid))
            } else { new.append(t) }
        }
        return (new, adopt)
    }
}

enum PlaidError: LocalizedError {
    case missingKeys, api(String), badResponse
    var errorDescription: String? {
        switch self {
        case .missingKeys: return "Enter your Plaid client ID and secret first."
        case .api(let m): return m
        case .badResponse: return "Unexpected response from Plaid."
        }
    }
}

/// Talks to Plaid directly from this Mac with your own keys (kept in the Keychain).
struct PlaidClient {
    enum Environment: String, CaseIterable, Identifiable {
        case sandbox, production
        var id: String { rawValue }
        var host: String { "https://\(rawValue).plaid.com" }
    }
    static let clientIdKey = "plaid.client_id", secretKey = "plaid.secret", envKey = "plaidEnvironment"

    var environment: Environment {
        Environment(rawValue: UserDefaults.standard.string(forKey: Self.envKey) ?? "") ?? .sandbox
    }
    var hasKeys: Bool { (SecretStore.get(Self.clientIdKey) ?? "").isEmpty == false && (SecretStore.get(Self.secretKey) ?? "").isEmpty == false }

    func call(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let id = SecretStore.get(Self.clientIdKey), let secret = SecretStore.get(Self.secretKey), !id.isEmpty, !secret.isEmpty
        else { throw PlaidError.missingKeys }
        var payload = body; payload["client_id"] = id; payload["secret"] = secret
        var req = URLRequest(url: URL(string: environment.host + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 60
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PlaidError.badResponse }
        if let msg = json["error_message"] as? String {
            let code = json["error_code"] as? String ?? ""
            throw PlaidError.api("\(msg) (\(code))")
        }
        return json
    }

    /// Start connecting a bank: returns the link token and the page to open in the browser.
    /// With an access token, Plaid opens in update mode instead: the person signs in to the same bank
    /// again and the existing connection (and its history) carries on, with no new accounts.
    func startLink(updating accessToken: String? = nil) async throws -> (linkToken: String, url: URL) {
        var body: [String: Any] = [
            "client_name": "Finance", "language": "en", "country_codes": ["US"],
            "user": ["client_user_id": "finance-mac"], "hosted_link": [String: Any](),
        ]
        if let accessToken { body["access_token"] = accessToken } else { body["products"] = ["transactions"] }
        let r = try await call("/link/token/create", body)
        guard let tok = r["link_token"] as? String, let s = r["hosted_link_url"] as? String, let u = URL(string: s) else { throw PlaidError.badResponse }
        return (tok, u)
    }

    /// Nil until the person has finished the bank sign-in page.
    func finishedLink(_ linkToken: String) async throws -> (publicToken: String, institution: String)? {
        let r = try await call("/link/token/get", ["link_token": linkToken])
        for session in (r["link_sessions"] as? [[String: Any]]) ?? [] {
            let results = session["results"] as? [String: Any]
            if let add = (results?["item_add_results"] as? [[String: Any]])?.first, let pt = add["public_token"] as? String {
                let inst = (add["institution"] as? [String: Any])?["name"] as? String ?? "Bank"
                return (pt, inst)
            }
            if let ok = session["on_success"] as? [String: Any], let pt = ok["public_token"] as? String {
                let inst = ((ok["metadata"] as? [String: Any])?["institution"] as? [String: Any])?["name"] as? String ?? "Bank"
                return (pt, inst)
            }
        }
        return nil
    }

    enum UpdateOutcome: Equatable { case waiting, done, exited(String?) }

    /// How a reconnect (update mode) is going: still open, finished, or closed without finishing.
    func updateOutcome(_ linkToken: String) async throws -> UpdateOutcome {
        let r = try await call("/link/token/get", ["link_token": linkToken])
        for session in (r["link_sessions"] as? [[String: Any]]) ?? [] {
            if session["on_success"] is [String: Any] { return .done }
            if let add = (session["results"] as? [String: Any])?["item_add_results"] as? [[String: Any]], !add.isEmpty { return .done }
            let exit = (session["exit"] as? [String: Any]) ?? (session["on_exit"] as? [String: Any])
            if let exit {
                let err = exit["error"] as? [String: Any]
                let msg = (err?["display_message"] as? String) ?? (err?["error_message"] as? String)
                return .exited(msg)
            }
            if let f = session["finished_at"] as? String, !f.isEmpty { return .done }
        }
        return .waiting
    }

    func exchange(_ publicToken: String) async throws -> (accessToken: String, itemId: String) {
        let r = try await call("/item/public_token/exchange", ["public_token": publicToken])
        guard let a = r["access_token"] as? String, let i = r["item_id"] as? String else { throw PlaidError.badResponse }
        return (a, i)
    }

    func accounts(_ accessToken: String) async throws -> [PlaidAccountInfo] {
        let r = try await call("/accounts/get", ["access_token": accessToken])
        return ((r["accounts"] as? [[String: Any]]) ?? []).compactMap { a in
            guard let id = a["account_id"] as? String, let name = a["name"] as? String else { return nil }
            return PlaidAccountInfo(accountId: id, name: name, mask: a["mask"] as? String,
                                    type: a["type"] as? String ?? "other", subtype: a["subtype"] as? String,
                                    current: (a["balances"] as? [String: Any])?["current"] as? Double)
        }
    }

    struct SyncPage { var added: [PlaidTransactionDTO]; var modified: [PlaidTransactionDTO]; var removed: [String]; var cursor: String; var hasMore: Bool }

    func syncPage(_ accessToken: String, cursor: String?) async throws -> SyncPage {
        var body: [String: Any] = ["access_token": accessToken, "count": 500]
        if let cursor { body["cursor"] = cursor }
        let r = try await call("/transactions/sync", body)
        func dtos(_ key: String) -> [PlaidTransactionDTO] {
            ((r[key] as? [[String: Any]]) ?? []).compactMap { d in
                guard let id = d["transaction_id"] as? String, let acct = d["account_id"] as? String,
                      let amt = d["amount"] as? Double, let date = d["date"] as? String, let name = d["name"] as? String else { return nil }
                return PlaidTransactionDTO(transaction_id: id, account_id: acct, amount: amt, date: date, name: name,
                                           merchant_name: d["merchant_name"] as? String, pending: d["pending"] as? Bool ?? false)
            }
        }
        guard let next = r["next_cursor"] as? String else { throw PlaidError.badResponse }
        return SyncPage(added: dtos("added"), modified: dtos("modified"),
                        removed: ((r["removed"] as? [[String: Any]]) ?? []).compactMap { $0["transaction_id"] as? String },
                        cursor: next, hasMore: r["has_more"] as? Bool ?? false)
    }
}

/// Linked banks (metadata only) are kept in this Mac's UserDefaults; tokens and keys live in the Keychain.
enum PlaidStore {
    private static let key = "plaidItems"
    static func items() -> [PlaidItem] {
        guard !DemoMode.isOn else { return [] }   // the demo never touches your real bank links
        guard let d = UserDefaults.standard.data(forKey: key), let v = try? JSONDecoder().decode([PlaidItem].self, from: d) else { return [] }
        return v
    }
    static func save(_ items: [PlaidItem]) {
        guard !DemoMode.isOn else { return }
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
    /// Make the next sync re-download everything (used after deleting synced transactions).
    static func resetCursors() { save(items().map { var i = $0; i.cursor = nil; return i }) }
    static func token(for itemId: String) -> String? { SecretStore.get("plaid.token.\(itemId)") }
    static func setToken(_ t: String, for itemId: String) { SecretStore.set(t, for: "plaid.token.\(itemId)") }
    static func remove(_ itemId: String) {
        SecretStore.set("", for: "plaid.token.\(itemId)")
        save(items().filter { $0.itemId != itemId })
    }
}

/// Runs bank syncs for the whole app: the toolbar button, launch, and coming back to the app.
@MainActor
final class SyncCoordinator: ObservableObject {
    @Published var busy = false
    @Published var status = ""
    private var lastRun: Date?

    var hasBanks: Bool { !PlaidStore.items().isEmpty }

    func syncAll(in context: ModelContext) {
        guard !busy, reconnecting == nil, hasBanks else { return }
        busy = true; status = "Syncing…"
        Task {
            var lines: [String] = []
            for item in PlaidStore.items() {
                do { lines.append(try await PlaidSync.sync(item.itemId, in: context)) }
                catch { lines.append("\(item.institution): \(error.localizedDescription)") }
            }
            status = lines.joined(separator: " ")
            lastRun = Date(); busy = false
            // Clear the message after a while.
            let shown = status
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if status == shown && !busy { status = "" }
        }
    }

    /// The bank connection (Plaid item) that feeds an account, if this Mac has one.
    func item(feeding account: Account) -> PlaidItem? {
        PlaidStore.items().first { PlaidSync.targets(of: $0).contains(account.accountId) }
    }

    /// The bank being reconnected (its Plaid item ID), while the sign-in page is open.
    @Published var reconnecting: String?
    private var reconnectTask: Task<Void, Never>?

    /// Fix a broken connection: open Plaid in update mode so the person signs in to the bank again,
    /// then sync. The connection, its accounts and their history stay as they are.
    func reconnect(_ itemId: String, in context: ModelContext) {
        guard reconnecting == nil, !busy else { return }
        guard let item = PlaidStore.items().first(where: { $0.itemId == itemId }) else { return }
        guard let token = PlaidStore.token(for: itemId) else {
            status = "\(item.institution): this Mac has lost the key for this connection. Remove it in Settings and connect again."
            return
        }
        reconnecting = itemId
        status = "Opening Plaid to reconnect \(item.institution)…"
        reconnectTask = Task {
            defer { reconnecting = nil; reconnectTask = nil }
            let client = PlaidClient()
            do {
                let (linkToken, url) = try await client.startLink(updating: token)
                NSWorkspace.shared.open(url)
                status = "Sign in to \(item.institution) in your browser…"
                for _ in 0..<300 {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    switch try await client.updateOutcome(linkToken) {
                    case .waiting: continue
                    case .exited(let why):
                        status = "\(item.institution) wasn't reconnected" + (why.map { ": \($0)" } ?? ". Try again when you're ready.")
                        return
                    case .done:
                        status = "Reconnected \(item.institution). Syncing…"
                        busy = true
                        defer { busy = false }
                        do { status = "Reconnected. " + (try await PlaidSync.sync(itemId, in: context)) }
                        catch { status = "Reconnected \(item.institution), but the sync failed: \(error.localizedDescription)" }
                        lastRun = Date()
                        return
                    }
                }
                status = "Timed out waiting for the bank sign-in. Try Reconnect again."
            } catch is CancellationError {
                status = "Reconnect cancelled."
            } catch {
                status = "Couldn't reconnect \(item.institution): \(error.localizedDescription)"
            }
        }
    }

    func cancelReconnect() { reconnectTask?.cancel() }

    /// Automatic sync: at most once every `minutes`.
    func syncIfStale(minutes: Double = 30, in context: ModelContext) {
        if let lastRun, Date().timeIntervalSince(lastRun) < minutes * 60 { return }
        syncAll(in: context)
    }
}

@MainActor
enum PlaidSync {
    /// Pull new, changed and removed transactions and the latest balances for one linked bank.
    /// Each account it feeds records when this last worked, or that it failed (shown in the account lists).
    static func sync(_ itemId: String, in context: ModelContext, client: PlaidClient = PlaidClient()) async throws -> String {
        do { return try await syncItem(itemId, in: context, client: client) }
        catch {
            recordFailure(itemId, error: error, in: context)
            throw error
        }
    }

    /// The app accountIds a linked bank feeds, as far as this Mac knows.
    static func targets(of item: PlaidItem) -> Set<String> {
        Set(item.accounts.map { item.accountMap[$0.accountId] ?? (PlaidMapping.prefix + $0.accountId) })
            .union(item.accountMap.values)
    }

    /// Mark every account fed by this bank as having failed to sync. The last good sync time stays.
    static func recordFailure(_ itemId: String, error: Error, in context: ModelContext, at now: Date = Date()) {
        guard let item = PlaidStore.items().first(where: { $0.itemId == itemId }) else { return }
        let ids = targets(of: item)
        for a in (try? context.fetch(FetchDescriptor<Account>())) ?? [] where ids.contains(a.accountId) {
            a.plaidSyncFailedAt = now
            a.plaidSyncError = error.localizedDescription
        }
        try? context.save()
    }

    /// Mark accounts as freshly synced, clearing any earlier failure.
    static func recordSuccess(_ accountIds: Set<String>, in context: ModelContext, at now: Date = Date()) {
        for a in (try? context.fetch(FetchDescriptor<Account>())) ?? [] where accountIds.contains(a.accountId) {
            a.plaidLastSync = now
            a.plaidSyncFailedAt = nil
            a.plaidSyncError = nil
        }
    }

    /// Forget sync times on accounts no linked bank feeds any more (after removing a bank or re-pointing an account).
    static func forgetUnlinked(in context: ModelContext) {
        guard !DemoMode.isOn else { return }   // the demo has no bank links of its own
        let linked = PlaidStore.items().reduce(into: Set<String>()) { $0.formUnion(targets(of: $1)) }
        var changed = false
        for a in (try? context.fetch(FetchDescriptor<Account>())) ?? []
        where !linked.contains(a.accountId) && (a.plaidLastSync != nil || a.plaidSyncFailedAt != nil) {
            a.plaidLastSync = nil; a.plaidSyncFailedAt = nil; a.plaidSyncError = nil
            changed = true
        }
        if changed { try? context.save() }
    }

    private static func syncItem(_ itemId: String, in context: ModelContext, client: PlaidClient) async throws -> String {
        var items = PlaidStore.items()
        guard let idx = items.firstIndex(where: { $0.itemId == itemId }), let token = PlaidStore.token(for: itemId) else {
            throw PlaidError.api("This bank connection is missing its access token. Remove it and connect again.")
        }
        var item = items[idx]
        item.accounts = try await client.accounts(token)

        // Where each Plaid account goes: a chosen existing account, or a new one.
        var map = item.accountMap
        let accountsNow = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        var bankBalances: [String: Double] = [:]   // app accountId → the bank's balance
        for pa in item.accounts {
            let target = map[pa.accountId] ?? (PlaidMapping.prefix + pa.accountId)
            map[pa.accountId] = target
            if let b = pa.appBalance { bankBalances[target] = b }
            // Existing accounts get their balance below, once new transactions have replaced matching hand-entered ones.
            if !accountsNow.contains(where: { $0.accountId == target }) {
                let label = pa.mask.map { "\(item.institution) \(pa.name) ••\($0)" } ?? "\(item.institution) \(pa.name)"
                context.insert(Account(name: label, type: pa.appType, accountId: target, bankName: item.institution, balance: pa.appBalance ?? 0))
            }
        }
        item.accountMap = map

        // Page through everything since the last cursor.
        var added: [PlaidTransactionDTO] = [], modified: [PlaidTransactionDTO] = [], removed: [String] = []
        var cursor = item.cursor
        while true {
            let page = try await client.syncPage(token, cursor: cursor)
            added += page.added; modified += page.modified; removed += page.removed
            cursor = page.cursor
            if !page.hasMore { break }
        }

        let all = (try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? []
        var byFitid = Dictionary(all.map { ($0.fitid, $0) }, uniquingKeysWith: { a, _ in a })
        // Removed by the bank.
        var removedCount = 0
        for id in removed { if let r = byFitid[PlaidMapping.prefix + id] { context.delete(r); byFitid[r.fitid] = nil; removedCount += 1 } }
        // Changed: update in place (keeps your category).
        var modifiedCount = 0
        for t in modified {
            guard let acct = map[t.account_id], let o = PlaidMapping.convert(t, accountId: acct) else { continue }
            if let r = byFitid[o.fitid] { r.date = o.date; r.name = o.name; r.amount = o.amount; r.typeRaw = o.type.rawValue; modifiedCount += 1 }
            else { added.append(t) }
        }
        // New: group per destination account, skipping ones already imported from files.
        var insertedCount = 0, matchedCount = 0
        for (plaidAcct, target) in map {
            let incoming = added.filter { $0.account_id == plaidAcct && byFitid[PlaidMapping.prefix + $0.transaction_id] == nil }
                .compactMap { PlaidMapping.convert($0, accountId: target) }
            guard !incoming.isEmpty else { continue }
            let existing = all.filter { $0.accountId == target && !$0.fitid.isEmpty }
            let split = PlaidMapping.splitKnown(incoming, existing: existing)
            for (rec, fitid) in split.adopt { rec.fitid = fitid; matchedCount += 1 }
            let name = item.accounts.first { $0.accountId == plaidAcct }?.name ?? "Account"
            let parsed = ParsedOFXFile(bankId: item.institution, accountId: target, accountName: name, balance: nil,
                                       transactions: split.new, isCreditCard: item.accounts.first { $0.accountId == plaidAcct }?.type == "credit")
            insertedCount += TransactionImportService().importParsed(parsed, into: context).inserted
        }
        // The bank's balance plus hand-entered transactions (e.g. typed in on the phone) it hasn't reported yet.
        let remaining = (try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? []
        for a in (try? context.fetch(FetchDescriptor<Account>())) ?? [] {
            guard let bank = bankBalances[a.accountId] else { continue }
            a.balance = ManualTransactionService.balance(
                bank: bank, unreported: ManualTransactionService.unreported(in: a.accountId, from: remaining))
        }
        // Only a sync that was saved counts: if saving fails, the error is recorded as a failed sync.
        try context.save()
        // The accounts the bank reported this time are now up to date.
        recordSuccess(Set(item.accounts.compactMap { map[$0.accountId] }), in: context)
        try? context.save()

        item.cursor = cursor
        item.lastSync = Date()
        items[idx] = item
        PlaidStore.save(items)
        var msg = "\(item.institution): \(insertedCount) new"
        if matchedCount > 0 { msg += ", \(matchedCount) matched to transactions you already had" }
        if modifiedCount > 0 { msg += ", \(modifiedCount) updated" }
        if removedCount > 0 { msg += ", \(removedCount) removed" }
        return msg + "."
    }
}
