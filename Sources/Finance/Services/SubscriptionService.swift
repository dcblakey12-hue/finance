import Foundation
import SwiftData

// MARK: - Your decisions about detected subscriptions

/// What you said about a recurring charge the app found: it's a real subscription, or it isn't.
/// Synced like the rest of your data, so a choice made on the Mac shows on the iPhone.
///
/// A decision is matched to a detected charge by merchant and cadence, and by amount within
/// `SubscriptionService.amountTolerance`, so a small price rise keeps your choice.
@Model
final class SubscriptionMark {
    var merchantKey: String = ""
    var cadenceRaw: String = "monthly"
    /// Account (OFX accountId) the charge goes through; empty matches any account.
    var accountId: String = ""
    /// Amount (positive) of the charge when you decided.
    var amount: Double = 0
    /// "confirmed" | "dismissed" | "cancelled"
    var statusRaw: String = "confirmed"
    var updatedAt: Date = Date()
    /// The day you cancelled it (status "cancelled" only).
    var cancelledAt: Date? = nil

    init(merchantKey: String, accountId: String = "", cadence: SubscriptionCadence, amount: Double, status: SubscriptionStatus, now: Date = Date()) {
        self.merchantKey = merchantKey; self.accountId = accountId; self.cadenceRaw = cadence.rawValue; self.amount = abs(amount)
        self.statusRaw = status.rawValue; self.updatedAt = now
    }
    var status: SubscriptionStatus { SubscriptionStatus(rawValue: statusRaw) ?? .confirmed }
    var cadence: SubscriptionCadence? { SubscriptionCadence(rawValue: cadenceRaw) }
}

/// unreviewed: found, not looked at yet. confirmed: a subscription you're keeping. dismissed: not a
/// subscription. cancelled: a subscription you've stopped (it leaves the totals and counts as a saving).
enum SubscriptionStatus: String, Codable { case unreviewed, confirmed, dismissed, cancelled }

enum SubscriptionCadence: String, CaseIterable, Codable, Identifiable {
    case weekly, biweekly, monthly, quarterly, yearly
    var id: String { rawValue }

    var label: String {
        switch self {
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 weeks"
        case .monthly: return "Monthly"
        case .quarterly: return "Every 3 months"
        case .yearly: return "Yearly"
        }
    }
    /// Gaps (in days) between charges that count as this cadence.
    var gapRange: ClosedRange<Double> {
        switch self {
        case .weekly: return 6...8
        case .biweekly: return 12...16
        case .monthly: return 26...35
        case .quarterly: return 84...98
        case .yearly: return 350...380
        }
    }
    var typicalDays: Double {
        switch self {
        case .weekly: return 7
        case .biweekly: return 14
        case .monthly: return 365.25 / 12
        case .quarterly: return 365.25 / 4
        case .yearly: return 365.25
        }
    }
    /// Fewest charges needed before calling it this cadence.
    var minimumCharges: Int {
        switch self {
        case .weekly: return 4
        case .biweekly, .monthly: return 3
        case .quarterly, .yearly: return 2
        }
    }
    /// How many charges a year.
    var perYear: Double {
        switch self {
        case .weekly: return 52
        case .biweekly: return 26
        case .monthly: return 12
        case .quarterly: return 4
        case .yearly: return 1
        }
    }
    func next(after d: Date, calendar: Calendar) -> Date {
        switch self {
        case .weekly: return calendar.date(byAdding: .day, value: 7, to: d) ?? d
        case .biweekly: return calendar.date(byAdding: .day, value: 14, to: d) ?? d
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: d) ?? d
        case .quarterly: return calendar.date(byAdding: .month, value: 3, to: d) ?? d
        case .yearly: return calendar.date(byAdding: .year, value: 1, to: d) ?? d
        }
    }
}

// MARK: - Detection

/// A recurring charge that might be a subscription.
struct DetectedSubscription: Identifiable, Equatable {
    var id: String { "\(merchantKey)|\(accountId)|\(cadence.rawValue)|\(String(format: "%.2f", amount))" }
    let merchantKey: String
    /// Readable name, from the latest charge.
    let name: String
    let cadence: SubscriptionCadence
    /// Latest charge (positive).
    let amount: Double
    /// True when every charge was the same amount.
    let isFixedAmount: Bool
    let chargeCount: Int
    let firstCharge: Date
    let lastCharge: Date
    let nextExpected: Date
    let category: String
    let accountName: String
    /// The latest charge's account (OFX accountId).
    let accountId: String
    /// Ids of the matched transactions, oldest first.
    let transactionIds: [UUID]
    /// No charge for a while after it was due: maybe cancelled.
    let mayHaveStopped: Bool
    /// Stopped so long ago it's only worth showing if you marked it cancelled.
    var isLongGone: Bool = false
    var status: SubscriptionStatus = .unreviewed
    /// When you cancelled it (cancelled only).
    var cancelledAt: Date? = nil
    /// Charges dated after the day you cancelled: it's still billing you.
    var chargesSinceCancel: [Date] = []

    var isCancelled: Bool { status == .cancelled }
    /// Cancelled, but a charge came through after the cancel date.
    var chargedAfterCancel: Bool { isCancelled && !chargesSinceCancel.isEmpty }

    var monthlyCost: Double { amount * cadence.perYear / 12 }
    var annualCost: Double { amount * cadence.perYear }
}

/// One charge, as plain values (so the detector can be tested without SwiftData).
struct ChargeRow {
    var id: UUID = UUID()
    var name: String
    var amount: Double
    var date: Date
    var category: String = Categorizer.uncategorized
    var accountId: String = ""
    var accountName: String = ""
    var isTransfer: Bool = false
}

enum SubscriptionService {
    /// Charges within this share of each other count as "the same price" (covers price rises and tax wobble).
    static let amountTolerance = 0.2
    /// Categories that are never subscriptions: money moving between your accounts, pay, rent and loans.
    static let excludedCategories: Set<String> = [Categorizer.transfer, "Income", "Housing", "Debt"]
    /// How far back to look.
    static let lookbackMonths = 25

    /// Find recurring charges: same merchant, similar amount, regular gaps.
    static func detect(_ rows: [ChargeRow], marks: [SubscriptionMark] = [], today: Date = Date(),
                       calendar: Calendar = .current) -> [DetectedSubscription] {
        let cutoff = calendar.date(byAdding: .month, value: -lookbackMonths, to: today) ?? .distantPast
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today)) ?? today
        let charges = rows.filter {
            $0.amount < 0 && !$0.isTransfer && !excludedCategories.contains($0.category)
                && $0.date >= cutoff && $0.date < endOfToday
        }
        // Per merchant and per account: the same service billed to two cards is two subscriptions.
        struct Group: Hashable { let merchant: String; let accountId: String }
        var byMerchant: [Group: [ChargeRow]] = [:]
        for c in charges {
            let key = MerchantNormalizer.key(for: c.name)
            if !key.isEmpty { byMerchant[Group(merchant: key, accountId: c.accountId), default: []].append(c) }
        }

        var found: [DetectedSubscription] = []
        for (group, list) in byMerchant {
            let key = group.merchant
            for cluster in amountClusters(list) {
                guard let s = recurring(cluster, merchantKey: key, today: today, calendar: calendar) else { continue }
                // Two charges a quarter or a year apart are thin evidence: only believe it when the price is
                // the same both times and the merchant isn't somewhere you shop often (two grocery runs
                // three months apart would otherwise look like a quarterly plan).
                if s.chargeCount < 3 {
                    let amounts = cluster.map { abs($0.amount) }
                    let samePrice = (amounts.max() ?? 0) - (amounts.min() ?? 0) <= max(0.01, s.amount * 0.02)
                    if !samePrice || list.count > cluster.count { continue }
                }
                found.append(s)
            }
        }
        return found.compactMap { s in
            var s = s
            let mark = match(s, in: marks)
            s.status = mark?.status ?? .unreviewed
            if s.isCancelled {
                let cancelled = calendar.startOfDay(for: mark?.cancelledAt ?? mark?.updatedAt ?? today)
                s.cancelledAt = cancelled
                let dayAfter = calendar.date(byAdding: .day, value: 1, to: cancelled) ?? cancelled
                s.chargesSinceCancel = rows.filter { s.transactionIds.contains($0.id) && $0.date >= dayAfter }.map(\.date).sorted()
            } else if s.isLongGone {
                return nil
            }
            return s
        }
        .sorted { ($0.mayHaveStopped ? 1 : 0, -$0.monthlyCost, $0.name) < ($1.mayHaveStopped ? 1 : 0, -$1.monthlyCost, $1.name) }
    }

    /// Group a merchant's charges by price: each group's amounts are within `amountTolerance` of its cheapest.
    static func amountClusters(_ list: [ChargeRow]) -> [[ChargeRow]] {
        let sorted = list.sorted { abs($0.amount) < abs($1.amount) }
        var clusters: [[ChargeRow]] = []
        var current: [ChargeRow] = []
        for c in sorted {
            if let first = current.first {
                let base = abs(first.amount)
                if abs(c.amount) - base > max(base * amountTolerance, 1) {
                    clusters.append(current); current = []
                }
            }
            current.append(c)
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
    }

    /// The cadence a cluster of charges repeats at, if it repeats regularly.
    private static func recurring(_ cluster: [ChargeRow], merchantKey: String, today: Date,
                                  calendar: Calendar) -> DetectedSubscription? {
        // One charge per day (a refund-and-recharge or a split shows up twice).
        var perDay: [Date: ChargeRow] = [:]
        for c in cluster.sorted(by: { $0.date < $1.date }) { perDay[calendar.startOfDay(for: c.date)] = c }
        let days = perDay.keys.sorted()
        guard days.count >= 2 else { return nil }
        let gaps = zip(days, days.dropFirst()).map { Double(calendar.dateComponents([.day], from: $0, to: $1).day ?? 0) }
        let median = gaps.sorted()[gaps.count / 2]
        guard let cadence = SubscriptionCadence.allCases.first(where: { $0.gapRange.contains(median) }),
              days.count >= cadence.minimumCharges else { return nil }
        // Most gaps must fit the cadence (one missed or doubled month is fine in a long run).
        let fitting = gaps.filter { cadence.gapRange.contains($0) }.count
        let allowedMisfits = gaps.count >= 5 ? gaps.count / 5 : 0
        guard gaps.count - fitting <= allowedMisfits else { return nil }

        let ordered = days.compactMap { perDay[$0] }
        guard let last = ordered.last, let first = ordered.first else { return nil }
        let lastDay = calendar.startOfDay(for: last.date)
        let next = cadence.next(after: lastDay, calendar: calendar)
        // Overdue by more than half a cycle (at least a week) → probably stopped.
        let grace = max(7, cadence.typicalDays / 2)
        let overdue = Double(calendar.dateComponents([.day], from: next, to: calendar.startOfDay(for: today)).day ?? 0)
        let stopped = overdue > grace
        // Long-gone charges are only kept if you marked them cancelled (see `detect`).
        let longGone = stopped && overdue > max(cadence.typicalDays * 2, 90)
        let amounts = ordered.map { abs($0.amount) }
        return DetectedSubscription(
            merchantKey: merchantKey, name: displayName(merchantKey), cadence: cadence,
            amount: abs(last.amount),
            isFixedAmount: amounts.allSatisfy { abs($0 - amounts[0]) < 0.005 },
            chargeCount: ordered.count, firstCharge: first.date, lastCharge: last.date, nextExpected: next,
            category: last.category, accountName: last.accountName, accountId: last.accountId,
            transactionIds: ordered.map(\.id), mayHaveStopped: stopped, isLongGone: longGone)
    }

    /// Readable merchant name from its key: "TUNEBOX MUSIC" → "Tunebox Music".
    static func displayName(_ key: String) -> String {
        key.lowercased().split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Your saved decision for a detected charge, if any: same merchant and cadence, closest amount within tolerance.
    static func match(_ s: DetectedSubscription, in marks: [SubscriptionMark]) -> SubscriptionMark? {
        marks.filter { matches($0, s) }
        .min { (abs($0.amount - s.amount), -$0.updatedAt.timeIntervalSince1970) < (abs($1.amount - s.amount), -$1.updatedAt.timeIntervalSince1970) }
    }

    private static func matches(_ m: SubscriptionMark, _ s: DetectedSubscription) -> Bool {
        m.merchantKey == s.merchantKey && m.cadenceRaw == s.cadence.rawValue
            && (m.accountId.isEmpty || m.accountId == s.accountId)
            && abs(m.amount - s.amount) <= max(m.amount * amountTolerance, 1)
    }

    /// Detect from stored transactions.
    static func detect(transactions: [TransactionRecord], marks: [SubscriptionMark], today: Date = Date(),
                       calendar: Calendar = .current) -> [DetectedSubscription] {
        detect(transactions.map {
            ChargeRow(id: $0.id, name: $0.name, amount: $0.amount, date: $0.date, category: $0.category,
                      accountId: $0.accountId, accountName: $0.accountName, isTransfer: $0.transferPeerId != nil)
        }, marks: marks, today: today, calendar: calendar)
    }

    /// Save your decision (confirmed / dismissed / cancelled), or clear it with `.unreviewed`.
    /// A cancellation is dated `cancelledOn` (default: today).
    @MainActor
    static func set(_ status: SubscriptionStatus, for s: DetectedSubscription, in context: ModelContext, now: Date = Date(),
                    cancelledOn: Date? = nil) {
        let marks = (try? context.fetch(FetchDescriptor<SubscriptionMark>())) ?? []
        let existing = marks.filter { matches($0, s) }
        for m in existing { context.delete(m) }
        if status != .unreviewed {
            let mark = SubscriptionMark(merchantKey: s.merchantKey, accountId: s.accountId, cadence: s.cadence, amount: s.amount, status: status, now: now)
            if status == .cancelled { mark.cancelledAt = cancelledOn ?? now }
            context.insert(mark)
        }
        try? context.save()
    }

    /// Subscriptions grouped by the account they're charged to, biggest monthly cost first.
    struct AccountGroup: Identifiable {
        var id: String { accountId }
        let accountId: String
        let accountName: String
        let items: [DetectedSubscription]
        var totals: (monthly: Double, annual: Double) { SubscriptionService.totals(items) }
    }
    static func byAccount(_ list: [DetectedSubscription]) -> [AccountGroup] {
        Dictionary(grouping: list, by: \.accountId).map { id, items in
            AccountGroup(accountId: id, accountName: items.first?.accountName ?? id, items: items)
        }
        .sorted { ($0.totals.monthly, $1.accountName) > ($1.totals.monthly, $0.accountName) }
    }

    /// What your cancellations save a year (at the price you were paying). One that still charges you saves nothing.
    static func savings(_ list: [DetectedSubscription]) -> Double {
        list.filter { $0.isCancelled && !$0.chargedAfterCancel }.reduce(0) { $0 + $1.annualCost }
    }

    /// Estimated cost of the charges that count: confirmed or not yet reviewed and still going, plus any you
    /// cancelled that still charge you.
    static func totals(_ list: [DetectedSubscription]) -> (monthly: Double, annual: Double) {
        let counted = list.filter { (($0.status == .confirmed || $0.status == .unreviewed) && !$0.mayHaveStopped) || $0.chargedAfterCancel }
        let monthly = counted.reduce(0) { $0 + $1.monthlyCost }
        return (monthly, monthly * 12)
    }
}
