import Foundation
import SwiftData

// MARK: - What a sync brought down

/// Everything one bank sync did, so you can see what came down (Settings ▸ Last bank sync, or click
/// the sync message). Kept on this Mac only, for the most recent sync of each bank.
struct PlaidSyncReport: Codable, Equatable, Identifiable {
    struct Line: Codable, Equatable, Identifiable {
        var id = UUID()
        var date: Date
        var name: String
        var amount: Double
        var account: String
        /// Extra detail, e.g. which of your entries it replaced.
        var note: String? = nil
    }
    var id: String { institution }
    var institution: String
    var date: Date
    /// New posted transactions.
    var added: [Line] = []
    /// Posted transactions that replaced one you typed in (now reconciled).
    var matchedToYours: [Line] = []
    /// Posted transactions matched to ones already imported from a bank file.
    var matchedToFiles: [Line] = []
    /// Pending transactions now posted (same transaction, now final).
    var pendingPosted: [Line] = []
    /// New pending transactions (not in the balance until they post).
    var pending: [Line] = []
    /// Pending transactions that are the same purchase as one you typed in (yours stays outstanding until it posts).
    var pendingMatchedToYours: [Line] = []
    /// Changed by the bank.
    var updated: [Line] = []
    /// Taken back by the bank (including pending ones that dropped off).
    var removed: [Line] = []
    /// Already here, so nothing was done.
    var alreadyHad: Int = 0
    var error: String? = nil

    var isEmpty: Bool {
        added.isEmpty && matchedToYours.isEmpty && matchedToFiles.isEmpty && pendingPosted.isEmpty && pending.isEmpty
            && pendingMatchedToYours.isEmpty && updated.isEmpty && removed.isEmpty
    }

    /// The one-line message shown after syncing.
    var summary: String {
        var parts = ["\(added.count + matchedToYours.count) new"]
        if !matchedToYours.isEmpty { parts.append("\(matchedToYours.count) matched to entries you typed in") }
        if !matchedToFiles.isEmpty { parts.append("\(matchedToFiles.count) matched to imported transactions") }
        if !pendingPosted.isEmpty { parts.append("\(pendingPosted.count) pending now posted") }
        let p = pending.count + pendingMatchedToYours.count
        if p > 0 { parts.append("\(p) pending") }
        if !updated.isEmpty { parts.append("\(updated.count) updated") }
        if !removed.isEmpty { parts.append("\(removed.count) removed") }
        return "\(institution): " + parts.joined(separator: ", ") + "."
    }

    // Storage: the latest report per bank, in this Mac's settings.
    private static let key = "plaid.lastSyncReports"
    static func all(_ defaults: UserDefaults = .standard) -> [PlaidSyncReport] {
        guard !DemoMode.isOn, let d = defaults.data(forKey: key),
              let v = try? JSONDecoder().decode([PlaidSyncReport].self, from: d) else { return [] }
        return v.sorted { $0.date > $1.date }
    }
    static func save(_ r: PlaidSyncReport, _ defaults: UserDefaults = .standard) {
        guard !DemoMode.isOn else { return }
        var list = all(defaults).filter { $0.institution != r.institution }
        list.insert(r, at: 0)
        if let d = try? JSONEncoder().encode(list) { defaults.set(d, forKey: key) }
    }
}

extension PlaidSync {
    /// Apply one sync's added / modified / removed transactions to the store and note what happened.
    /// - map: Plaid account id → app accountId.
    /// - creditAccounts: Plaid account ids that are credit cards.
    @MainActor
    static func apply(added: [PlaidTransactionDTO], modified: [PlaidTransactionDTO], removed: [String],
                      map: [String: String], accountNames: [String: String], institution: String,
                      creditAccounts: Set<String> = [], report: inout PlaidSyncReport, in context: ModelContext,
                      calendar: Calendar = .current) {
        let prefix = PlaidMapping.prefix
        let all = (try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? []
        var byFitid = Dictionary(all.map { ($0.fitid, $0) }, uniquingKeysWith: { a, _ in a })
        func line(_ o: OFXTransaction, note: String? = nil) -> PlaidSyncReport.Line {
            .init(date: o.date, name: o.name, amount: o.amount, account: accountNames[o.accountId] ?? o.accountId, note: note)
        }
        func line(_ r: TransactionRecord, note: String? = nil) -> PlaidSyncReport.Line {
            .init(date: r.date, name: r.name, amount: r.amount, account: r.accountName, note: note)
        }

        // Posted transactions that replace a pending one (Plaid removes the pending id at the same time).
        var postedFor: [String: PlaidTransactionDTO] = [:]
        for t in added where !t.pending { if let p = t.pending_transaction_id { postedFor[p] = t } }
        var handled = Set<String>()       // posted Plaid ids already dealt with
        var pendingIdsForImport: [String: String] = [:]   // posted fitid → pending id, for hand-entered links

        // Removed by the bank. A pending one that has now posted becomes the posted one, keeping your
        // category, notes and edits.
        for id in removed {
            guard let r = byFitid[prefix + id] else { continue }
            if r.isPending, let posted = postedFor[id], let acct = map[posted.account_id],
               let o = PlaidMapping.convert(posted, accountId: acct, calendar: calendar) {
                byFitid[r.fitid] = nil
                r.fitid = o.fitid
                r.isPending = false
                PlaidMapping.applyModified(o, to: r)
                byFitid[r.fitid] = r
                handled.insert(posted.transaction_id)
                report.pendingPosted.append(line(r))
            } else {
                report.removed.append(line(r, note: r.isPending ? "pending, dropped by the bank" : nil))
                context.delete(r)
                byFitid[r.fitid] = nil
            }
        }
        // Posted ones whose pending version was matched to an entry you typed in.
        for (pid, posted) in postedFor where !handled.contains(posted.transaction_id) {
            pendingIdsForImport[prefix + posted.transaction_id] = pid
        }

        // Changed: update in place (keeps your category and edits).
        var extraAdded: [PlaidTransactionDTO] = []
        for t in modified {
            guard let acct = map[t.account_id], let o = PlaidMapping.convert(t, accountId: acct, allowPending: true, calendar: calendar) else { continue }
            if let r = byFitid[o.fitid] {
                PlaidMapping.applyModified(o, to: r)
                r.isPending = t.pending
                report.updated.append(line(r))
            } else { extraAdded.append(t) }
        }
        let incomingAll = (added + extraAdded).filter { !handled.contains($0.transaction_id) }

        // New pending: link to a matching entry you typed in, or keep as pending.
        let rules = CategorizationService.ruleMap(in: context)
        let allowed = CategoryService.allowedBuiltIns(in: context)
        var claimedManual = Set<UUID>()
        for t in incomingAll where t.pending && byFitid[prefix + t.transaction_id] == nil {
            guard let acct = map[t.account_id], let o = PlaidMapping.convert(t, accountId: acct, allowPending: true, calendar: calendar) else { continue }
            if let m = all.first(where: { $0.accountId == acct && ManualTransactionService.isManual($0) && !$0.reconciledByHand
                                          && $0.bankPendingId == nil && !claimedManual.contains($0.id)
                                          && ManualTransactionService.matches($0, amount: o.amount, date: o.date, calendar: calendar) }) {
                m.bankPendingId = t.transaction_id
                claimedManual.insert(m.id)
                report.pendingMatchedToYours.append(line(o, note: "your entry “\(m.name)”"))
                continue
            }
            let r = TransactionRecord(fitid: o.fitid, accountId: acct, accountName: accountNames[acct] ?? acct, date: o.date,
                                      name: o.name, amount: o.amount, type: o.type,
                                      category: Categorizer.category(forName: o.name, rules: rules, allowed: allowed) ?? Categorizer.uncategorized)
            r.isPending = true
            context.insert(r)
            byFitid[r.fitid] = r
            report.pending.append(line(o))
        }
        // A pending entry that disappeared without posting frees the entry you typed in.
        for m in all where m.bankPendingId != nil && removed.contains(m.bankPendingId!) && postedFor[m.bankPendingId!] == nil {
            m.bankPendingId = nil
        }

        // New posted: per account, skipping ones already imported from files; the import replaces
        // matching entries you typed in.
        for (plaidAcct, target) in map {
            let posted = incomingAll.filter { !$0.pending && $0.account_id == plaidAcct }
            let fresh = posted.filter { byFitid[prefix + $0.transaction_id] == nil }
            report.alreadyHad += posted.count - fresh.count
            let incoming = fresh.compactMap { PlaidMapping.convert($0, accountId: target, calendar: calendar) }
            guard !incoming.isEmpty else { continue }
            let existing = all.filter { $0.accountId == target && !$0.fitid.isEmpty && !$0.isPending }
            let split = PlaidMapping.splitKnown(incoming, existing: existing, calendar: calendar)
            for (rec, fitid) in split.adopt {
                rec.fitid = fitid
                report.matchedToFiles.append(line(rec))
            }
            let parsed = ParsedOFXFile(bankId: institution, accountId: target, accountName: accountNames[target] ?? "Account", balance: nil,
                                       transactions: split.new, isCreditCard: creditAccounts.contains(plaidAcct))
            var matched = Set<String>()
            _ = TransactionImportService().importParsed(parsed, into: context, pendingIds: pendingIdsForImport) { bank, name, amount in
                matched.insert(bank.fitid)
                let differs = abs(bank.amount - amount) >= 0.005
                report.matchedToYours.append(line(bank, note: "replaced your entry “\(name)”"
                    + (differs ? " (\(currency.string(from: NSNumber(value: amount)) ?? ""))" : "")))
            }
            for o in split.new where !matched.contains(o.fitid) { report.added.append(line(o)) }
        }
    }
}
