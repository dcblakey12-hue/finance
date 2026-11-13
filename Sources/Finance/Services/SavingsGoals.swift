import Foundation
import SwiftData

// MARK: - Model

/// Something you're saving up for. Progress comes from a linked account's balance (e.g. a
/// "Vacation Fund" savings account), or from money you add to it by hand.
@Model
final class SavingsGoal {
    var id: UUID = UUID()
    var name: String = ""
    var target: Double = 0
    /// When you'd like to have it by (optional).
    var targetDate: Date? = nil
    /// OFX accountId of the account whose balance counts as saved. Nil = tracked by hand.
    var accountId: String? = nil
    /// Saved so far, for goals tracked by hand.
    var savedByHand: Double = 0
    /// Money added by hand: "yyyy-MM-dd:amount" entries, comma separated (used to work out your pace).
    var contributionsRaw: String = ""
    var createdAt: Date = Date()
    /// Reached and put away.
    var isArchived: Bool = false
    /// SF Symbol shown on the goal.
    var symbol: String = "star"

    init(id: UUID = UUID(), name: String, target: Double, targetDate: Date? = nil, accountId: String? = nil,
         symbol: String = "star", createdAt: Date = Date()) {
        self.id = id; self.name = name; self.target = target; self.targetDate = targetDate
        self.accountId = accountId; self.symbol = symbol; self.createdAt = createdAt
    }

    var contributions: [(date: Date, amount: Double)] {
        get { SavingsGoalService.parse(contributionsRaw) }
        set { contributionsRaw = SavingsGoalService.serialize(newValue) }
    }
}

// MARK: - Progress

struct GoalProgress: Equatable {
    let saved: Double
    let target: Double
    /// Average saved per month lately (nil when there isn't enough to go on).
    let monthlyPace: Double?
    /// When you'll get there at that pace (nil if not growing, or already there).
    let projectedDate: Date?
    /// Per month needed to make the target date (nil without a date, or once reached).
    let neededPerMonth: Double?
    let targetDate: Date?

    var remaining: Double { max(0, target - saved) }
    var fraction: Double { target > 0 ? min(1, max(0, saved / target)) : 0 }
    var isReached: Bool { target > 0 && saved >= target }
    /// On course for the target date at the current pace.
    var onTrack: Bool? {
        guard let targetDate, !isReached else { return nil }
        guard let projectedDate else { return false }
        return projectedDate <= targetDate
    }
}

enum SavingsGoalService {
    /// How far back to look when working out your pace.
    static let paceDays = 90

    static let symbols = ["star", "airplane", "house", "car", "gift", "graduationcap", "heart", "laptopcomputer",
                          "umbrella", "cross.case", "pawprint", "camera", "bicycle", "sofa"]

    /// - Parameters:
    ///   - balance: the linked account's balance today (nil for goals tracked by hand).
    ///   - accountChanges: the linked account's transactions as (date, amount), for its pace.
    static func progress(target: Double, targetDate: Date?, createdAt: Date, balance: Double?, savedByHand: Double,
                         contributions: [(date: Date, amount: Double)], accountChanges: [(date: Date, amount: Double)],
                         today: Date = Date(), calendar: Calendar = .current) -> GoalProgress {
        let todayStart = calendar.startOfDay(for: today)
        let saved = balance ?? savedByHand
        // Pace: what came in over the last 90 days (or since the goal started, if newer), per month.
        let windowStart = calendar.date(byAdding: .day, value: -paceDays, to: todayStart) ?? todayStart
        let flows = balance == nil ? contributions : accountChanges
        let since = balance == nil ? max(windowStart, calendar.startOfDay(for: createdAt)) : windowStart
        let days = Double(calendar.dateComponents([.day], from: since, to: todayStart).day ?? 0)
        var pace: Double? = nil
        if days >= 28 {
            let added = flows.filter { $0.date >= since && $0.date < (calendar.date(byAdding: .day, value: 1, to: todayStart) ?? today) }
                .reduce(0) { $0 + $1.amount }
            pace = added / (days / (365.25 / 12))
        }
        let remaining = max(0, target - saved)
        var projected: Date? = nil
        if remaining > 0, let p = pace, p > 0.5 {
            let months = remaining / p
            projected = calendar.date(byAdding: .day, value: Int((months * 365.25 / 12).rounded(.up)), to: todayStart)
        }
        var needed: Double? = nil
        if remaining > 0, let targetDate {
            let monthsLeft = Double(calendar.dateComponents([.day], from: todayStart, to: calendar.startOfDay(for: targetDate)).day ?? 0) / (365.25 / 12)
            needed = monthsLeft > 0.25 ? remaining / monthsLeft : remaining
        }
        return GoalProgress(saved: saved, target: target, monthlyPace: pace, projectedDate: projected,
                            neededPerMonth: needed, targetDate: targetDate)
    }

    /// Progress for a stored goal.
    @MainActor
    static func progress(_ goal: SavingsGoal, accounts: [Account], transactions: [TransactionRecord],
                         today: Date = Date(), calendar: Calendar = .current) -> GoalProgress {
        var balance: Double? = nil
        var changes: [(date: Date, amount: Double)] = []
        if let id = goal.accountId, let account = accounts.first(where: { $0.accountId == id }) {
            let txs = transactions.filter { $0.accountId == id }
            balance = BalanceBook(transactions: txs, today: today, calendar: calendar).today(account)
            changes = txs.map { ($0.date, $0.amount) }
        }
        return progress(target: goal.target, targetDate: goal.targetDate, createdAt: goal.createdAt, balance: balance,
                        savedByHand: goal.savedByHand, contributions: goal.contributions, accountChanges: changes,
                        today: today, calendar: calendar)
    }

    /// Add (or, with a negative amount, take out) money on a goal tracked by hand.
    @MainActor
    static func add(_ amount: Double, to goal: SavingsGoal, on date: Date = Date(), in context: ModelContext) {
        guard amount != 0 else { return }
        goal.savedByHand = max(0, goal.savedByHand + amount)
        goal.contributions = goal.contributions + [(date, amount)]
        try? context.save()
    }

    /// One line that says how it's going.
    static func summary(_ p: GoalProgress) -> String {
        func money(_ v: Double) -> String {
            let f = NumberFormatter(); f.numberStyle = .currency; f.maximumFractionDigits = v >= 100 ? 0 : 2; f.locale = .current
            return f.string(from: NSNumber(value: v)) ?? ""
        }
        func month(_ d: Date) -> String { d.formatted(.dateTime.month(.wide).year()) }
        if p.isReached { return "Goal reached. Nice work!" }
        var parts: [String] = []
        if let pace = p.monthlyPace, pace > 0.5, let when = p.projectedDate {
            parts.append("At \(money(pace)) a month you'll get there around \(month(when)).")
        } else if p.monthlyPace != nil {
            parts.append("Nothing added lately.")
        } else {
            parts.append("Add to it for a month to see when you'll get there.")
        }
        if let target = p.targetDate, let needed = p.neededPerMonth {
            if p.onTrack == true {
                parts.append("On track for \(month(target)).")
            } else {
                parts.append("Save \(money(needed)) a month to make \(month(target)).")
            }
        }
        return parts.joined(separator: " ")
    }

    // Contribution log
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; return f
    }()
    static func parse(_ raw: String) -> [(date: Date, amount: Double)] {
        raw.split(separator: ",").compactMap { part in
            let bits = part.split(separator: ":")
            guard bits.count == 2, let d = dayFormat.date(from: String(bits[0])), let a = Double(bits[1]) else { return nil }
            return (d, a)
        }
    }
    static func serialize(_ list: [(date: Date, amount: Double)]) -> String {
        list.map { "\(dayFormat.string(from: $0.date)):\(String(format: "%.2f", $0.amount))" }.joined(separator: ",")
    }
}
