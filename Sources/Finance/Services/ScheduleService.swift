import Foundation

/// Plain values for creating or editing a scheduled transaction (RecurringBill).
struct ScheduleDraft: Equatable {
    var name: String
    var amount: Double      // always positive; `isIncome` gives the direction
    var dueDay: Int         // 1...28
    var category: String
    var isIncome: Bool
    var isActive: Bool = true
}

enum ScheduleService {
    /// Pre-fill a schedule from an existing transaction: same merchant, amount,
    /// and day of month (clamped to 28, the latest day every month has).
    static func draft(fromName name: String, amount: Double, date: Date, category: String,
                      calendar: Calendar = .current) -> ScheduleDraft {
        let isIncome = amount > 0
        let day = calendar.component(.day, from: date)
        let merchant = MerchantNormalizer.key(for: name)
        let displayName = merchant.isEmpty ? name : merchant.capitalized
        let cat: String
        if isIncome { cat = "Income" }
        else if category == Categorizer.uncategorized { cat = "Other" }
        else { cat = category }
        return ScheduleDraft(name: displayName, amount: abs(amount), dueDay: min(max(day, 1), 28),
                             category: cat, isIncome: isIncome)
    }

    /// Next date on or after `from` (start of day) that falls on `dueDay`.
    static func nextDueDate(dueDay: Int, from: Date, calendar: Calendar = .current) -> Date? {
        let day = min(max(dueDay, 1), 28)
        let today = calendar.startOfDay(for: from)
        for offset in 0..<2 {
            guard let monthDate = calendar.date(byAdding: .month, value: offset, to: today) else { continue }
            var comps = calendar.dateComponents([.year, .month], from: monthDate)
            comps.day = day
            if let due = calendar.date(from: comps), due >= today { return due }
        }
        return nil
    }
}
