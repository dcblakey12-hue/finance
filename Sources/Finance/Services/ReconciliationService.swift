import Foundation
import SwiftData
import SwiftUI

// MARK: - Reconciled vs outstanding
//
// One notion of "posted vs outstanding", shared with the rest of the app:
// - A transaction from a bank sync or file import is reconciled: the bank has it.
// - A hand-entered one (typed in, or entered from a scheduled payment, "manual-" id) is outstanding
//   until the bank reports it. The import replaces it with the bank's own record
//   (`ManualTransactionService.matches`, within 5 days), which is reconciled.
// - You can tick a hand-entered one as reconciled yourself (`reconciledByHand`), for accounts with
//   no bank feed, or when you can see it on your statement already.
//
// An account's `balance` is the bank's figure plus its outstanding entries (see
// `ManualTransactionService.balance`), so the reconciled balance is that less the outstanding.

extension TransactionRecord {
    /// Confirmed by the bank (synced or imported), or ticked as reconciled by you.
    @MainActor var isReconciled: Bool { (!ManualTransactionService.isManual(self) && !isPending) || reconciledByHand }
    /// Entered by hand and not reconciled yet: counted in the balance, but not in the bank's figure.
    /// (A pending bank transaction is neither: it isn't in the balance at all until it posts.)
    @MainActor var isOutstanding: Bool { !isReconciled && !isPending }
}

/// The two balances for an account (or several added together).
struct ReconciliationSummary: Equatable {
    /// The balance including outstanding entries: what you'll have once they all clear.
    var balance: Double
    /// How many entries are outstanding, and their total (signed: negative = money still to go out).
    var outstandingCount: Int
    var outstandingTotal: Double
    /// What the bank should show: the balance less the outstanding entries.
    var reconciledBalance: Double { balance - outstandingTotal }
    var hasOutstanding: Bool { outstandingCount > 0 }
}

@MainActor
enum ReconciliationService {
    /// Outstanding entries in the given accounts (nil = all accounts).
    static func outstanding(in accountIds: Set<String>?, from all: [TransactionRecord]) -> [TransactionRecord] {
        all.filter { t in t.isOutstanding && (accountIds?.contains(t.accountId) ?? true) }
    }

    /// Both balances for `accounts` added together. Property values aren't cash and are left out,
    /// the same as the transaction list's running balance.
    static func summary(for accounts: [Account], transactions: [TransactionRecord]) -> ReconciliationSummary {
        let cash = accounts.filter { !$0.type.isPropertyValue }
        let open = outstanding(in: Set(cash.map(\.accountId)), from: transactions)
        return ReconciliationSummary(balance: cash.reduce(0) { $0 + $1.balance },
                                     outstandingCount: open.count,
                                     outstandingTotal: open.reduce(0) { $0 + $1.amount })
    }

    /// Only hand-entered transactions can be ticked or unticked; bank ones are always reconciled.
    static func canToggle(_ t: TransactionRecord) -> Bool { ManualTransactionService.isManual(t) }

    /// Tick (or untick) a hand-entered transaction as reconciled. The account's balance doesn't move:
    /// it already counts the entry. Only the split between reconciled and outstanding changes.
    /// Returns false for bank transactions, which are left alone.
    @discardableResult
    static func setReconciled(_ t: TransactionRecord, _ reconciled: Bool, in context: ModelContext) -> Bool {
        guard canToggle(t) else { return false }
        t.reconciledByHand = reconciled
        try? context.save()
        return true
    }
}

/// The marker at the start of a transaction row: a green tick when reconciled (outlined when you
/// ticked it yourself), an orange dashed circle while outstanding.
struct ReconciliationMarker: View {
    let transaction: TransactionRecord

    var body: some View {
        let t = transaction
        let pending = t.isPending || (t.bankPendingId != nil && !t.isReconciled)
        Image(systemName: pending ? "clock" : !t.isReconciled ? "circle.dashed"
                          : t.reconciledByHand ? "checkmark.circle" : "checkmark.circle.fill")
            .foregroundStyle(pending ? Color.blue : t.isReconciled ? Color.green : Color.orange)
            .accessibilityLabel(Self.help(t))
    }

    static func help(_ t: TransactionRecord) -> String {
        if t.isPending { return "Pending at the bank: not posted yet, so it isn't in the balance" }
        if t.bankPendingId != nil && !t.isReconciled { return "Outstanding: the bank shows it as pending; it reconciles when the bank posts it" }
        if !t.isReconciled { return "Outstanding: entered by hand and not reported by the bank yet" }
        if ManualTransactionService.isManual(t) { return "Reconciled: entered by hand and marked reconciled by you" }
        return "Reconciled: confirmed by a bank sync or file import"
    }
}
