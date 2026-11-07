import Foundation
import Security
import SwiftData

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
    static func set(_ value: String, for key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var a = q
        a[kSecValueData as String] = Data(value.utf8)
        a[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(a as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return nil }
        return String(data: d, encoding: .utf8)
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
    func startLink() async throws -> (linkToken: String, url: URL) {
        let r = try await call("/link/token/create", [
            "client_name": "Finance", "language": "en", "country_codes": ["US"],
            "user": ["client_user_id": "finance-mac"], "products": ["transactions"],
            "hosted_link": [String: Any](),
        ])
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
        guard let d = UserDefaults.standard.data(forKey: key), let v = try? JSONDecoder().decode([PlaidItem].self, from: d) else { return [] }
        return v
    }
    static func save(_ items: [PlaidItem]) {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
    static func token(for itemId: String) -> String? { SecretStore.get("plaid.token.\(itemId)") }
    static func setToken(_ t: String, for itemId: String) { SecretStore.set(t, for: "plaid.token.\(itemId)") }
    static func remove(_ itemId: String) {
        SecretStore.set("", for: "plaid.token.\(itemId)")
        save(items().filter { $0.itemId != itemId })
    }
}

@MainActor
enum PlaidSync {
    /// Pull new, changed and removed transactions and the latest balances for one linked bank.
    static func sync(_ itemId: String, in context: ModelContext, client: PlaidClient = PlaidClient()) async throws -> String {
        var items = PlaidStore.items()
        guard let idx = items.firstIndex(where: { $0.itemId == itemId }), let token = PlaidStore.token(for: itemId) else {
            throw PlaidError.api("This bank connection is missing its access token. Remove it and connect again.")
        }
        var item = items[idx]
        item.accounts = try await client.accounts(token)

        // Where each Plaid account goes: a chosen existing account, or a new one.
        var map = item.accountMap
        let accountsNow = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        for pa in item.accounts {
            let target = map[pa.accountId] ?? (PlaidMapping.prefix + pa.accountId)
            map[pa.accountId] = target
            if let existing = accountsNow.first(where: { $0.accountId == target }) {
                if let b = pa.appBalance { existing.balance = b }
            } else {
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
