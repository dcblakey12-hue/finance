import Foundation
import SwiftData

// MARK: - Persisted rule

/// A learned or user-defined "merchant → category" mapping.
/// `merchantKey` is the output of `MerchantNormalizer.key(for:)`, so
/// "STARBUCKS #1234 SEATTLE WA" and "Starbucks 0099" share one rule.
@Model
final class CategoryRule {
    @Attribute(.unique) var merchantKey: String
    var category: String
    var createdAt: Date
    var updatedAt: Date

    init(merchantKey: String, category: String, now: Date = Date()) {
        self.merchantKey = merchantKey; self.category = category
        self.createdAt = now; self.updatedAt = now
    }
}

// MARK: - Pure, testable core

enum MerchantNormalizer {
    /// Bank-added words that often appear before the merchant name.
    private static let leadingNoise: Set<String> = [
        "POS", "PURCHASE", "DEBIT", "CREDIT", "CARD", "CHECKCARD", "CHECK", "ACH", "VISA", "MC",
        "RECURRING", "PAYMENT", "ONLINE", "AUTHORIZED", "ON", "SQ", "TST", "PAYPAL", "SP", "WWW",
    ]

    /// Reduce a raw transaction name to a stable merchant key, e.g.
    /// "POS PURCHASE STARBUCKS #1234 SEATTLE WA" → "STARBUCKS" and
    /// "PURCHASE AUTHORIZED ON 01/15 WHOLE FOODS MKT 10155" → "WHOLE FOODS".
    ///
    /// Steps: split on whitespace, skip leading noise words and dates, stop at
    /// the first word containing a digit (store numbers come before the city),
    /// strip punctuation, keep at most two words.
    static func key(for rawName: String) -> String {
        let tokens = rawName.uppercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var words: [String] = []
        var started = false
        for token in tokens {
            let hasDigit = token.contains { $0.isNumber }
            let cleaned = String(token.filter { $0.isLetter || $0 == "&" || $0 == "'" || $0 == "-" })
            if !started {
                if hasDigit || cleaned.isEmpty || leadingNoise.contains(cleaned) { continue }
                started = true
            } else if hasDigit {
                break
            }
            if cleaned.isEmpty { continue }
            words.append(cleaned)
            if words.count == 2 { break }
        }
        return words.joined(separator: " ")
    }
}

enum Categorizer {
    static let uncategorized = "Uncategorized"

    /// Built-in keyword hints, checked only when no learned rule matches.
    /// A keyword matches at the start of a word, so "RENT" matches "RENT PMT"
    /// but not "CURRENT" or "PARENTS".
    static let builtInKeywords: [(keyword: String, category: String)] = [
        // Groceries
        ("WHOLE FOODS", "Groceries"), ("TRADER JOE", "Groceries"), ("KROGER", "Groceries"), ("SAFEWAY", "Groceries"),
        ("PUBLIX", "Groceries"), ("ALDI", "Groceries"), ("WEGMANS", "Groceries"), ("COSTCO", "Groceries"),
        ("H-E-B", "Groceries"), ("SPROUTS", "Groceries"), ("INSTACART", "Groceries"),
        // Dining
        ("STARBUCKS", "Dining"), ("MCDONALD", "Dining"), ("CHIPOTLE", "Dining"), ("DOORDASH", "Dining"),
        ("UBER EATS", "Dining"), ("GRUBHUB", "Dining"), ("DUNKIN", "Dining"), ("RESTAURANT", "Dining"),
        ("CAFE", "Dining"), ("PIZZA", "Dining"), ("CHICK-FIL-A", "Dining"),
        // Transport (after UBER EATS so food delivery wins)
        ("UBER", "Transport"), ("LYFT", "Transport"), ("SHELL", "Transport"), ("CHEVRON", "Transport"),
        ("EXXON", "Transport"), ("TEXACO", "Transport"), ("PARKING", "Transport"), ("TOLL", "Transport"),
        // Utilities
        ("COMCAST", "Utilities"), ("XFINITY", "Utilities"), ("VERIZON", "Utilities"), ("AT&T", "Utilities"),
        ("T-MOBILE", "Utilities"), ("ELECTRIC", "Utilities"), ("WATER", "Utilities"), ("PG&E", "Utilities"),
        // Entertainment
        ("NETFLIX", "Entertainment"), ("SPOTIFY", "Entertainment"), ("HULU", "Entertainment"),
        ("DISNEY PLUS", "Entertainment"), ("STEAM", "Entertainment"), ("AMC", "Entertainment"),
        // Health
        ("CVS", "Health"), ("WALGREENS", "Health"), ("PHARMACY", "Health"), ("DENTAL", "Health"),
        // Housing
        ("RENT", "Housing"), ("MORTGAGE", "Housing"), ("HOA", "Housing"),
        // Income
        ("PAYROLL", "Income"), ("DIRECT DEP", "Income"),
    ]

    /// Category for a transaction, or nil if nothing matches.
    /// Learned rules (by merchant key) win over built-in keywords.
    static func category(forName name: String, rules: [String: String]) -> String? {
        let key = MerchantNormalizer.key(for: name)
        if !key.isEmpty, let cat = rules[key] { return cat }
        let haystack = " " + wordSpaced(name) + " "
        return builtInKeywords.first { haystack.contains(" " + $0.keyword) }?.category
    }

    /// Uppercase, with punctuation other than & ' - turned into spaces.
    private static func wordSpaced(_ s: String) -> String {
        String(s.uppercased().map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "&" || ch == "'" || ch == "-" ? ch : " "
        })
    }
}

// MARK: - SwiftData glue

@MainActor
enum CategorizationService {
    static func ruleMap(in context: ModelContext) -> [String: String] {
        let rules = (try? context.fetch(FetchDescriptor<CategoryRule>())) ?? []
        return Dictionary(rules.map { ($0.merchantKey, $0.category) }, uniquingKeysWith: { _, new in new })
    }

    /// Called when the user picks a category by hand. Remembers the choice for
    /// this merchant and applies it to other *uncategorized* transactions from
    /// the same merchant. Returns how many other transactions were updated.
    @discardableResult
    static func learn(from tx: TransactionRecord, category: String, in context: ModelContext) -> Int {
        tx.category = category
        let key = MerchantNormalizer.key(for: tx.name)
        guard !key.isEmpty else { try? context.save(); return 0 }

        let desc = FetchDescriptor<CategoryRule>(predicate: #Predicate { $0.merchantKey == key })
        if category == Categorizer.uncategorized {
            // Clearing a category also forgets the rule.
            if let existing = try? context.fetch(desc).first { context.delete(existing) }
            try? context.save()
            return 0
        }
        if let existing = try? context.fetch(desc).first {
            existing.category = category; existing.updatedAt = Date()
        } else {
            context.insert(CategoryRule(merchantKey: key, category: category))
        }

        let uncategorized = Categorizer.uncategorized
        let others = (try? context.fetch(FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.category == uncategorized }))) ?? []
        var updated = 0
        for other in others where other.id != tx.id && MerchantNormalizer.key(for: other.name) == key {
            other.category = category
            updated += 1
        }
        try? context.save()
        return updated
    }

    /// Run rules + built-in keywords over every uncategorized transaction.
    @discardableResult
    static func categorizeUncategorized(in context: ModelContext) -> Int {
        let rules = ruleMap(in: context)
        let uncategorized = Categorizer.uncategorized
        let txs = (try? context.fetch(FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.category == uncategorized }))) ?? []
        var updated = 0
        for tx in txs {
            if let cat = Categorizer.category(forName: tx.name, rules: rules) {
                tx.category = cat; updated += 1
            }
        }
        try? context.save()
        return updated
    }
}
