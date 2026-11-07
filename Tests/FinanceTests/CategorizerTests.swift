import XCTest
@testable import Finance

final class CategorizerTests: XCTestCase {
    func testMerchantKeyStripsBankNoiseStoreNumbersAndCity() {
        XCTAssertEqual(MerchantNormalizer.key(for: "POS PURCHASE STARBUCKS #1234 SEATTLE WA"), "STARBUCKS")
        XCTAssertEqual(MerchantNormalizer.key(for: "Starbucks 0099"), "STARBUCKS")
        XCTAssertEqual(MerchantNormalizer.key(for: "PURCHASE AUTHORIZED ON 01/15 WHOLE FOODS MKT 10155"), "WHOLE FOODS")
        XCTAssertEqual(MerchantNormalizer.key(for: "Whole Foods Market"), "WHOLE FOODS")
        XCTAssertEqual(MerchantNormalizer.key(for: "SQ *BLUE BOTTLE COFFEE"), "BLUE BOTTLE")
        XCTAssertEqual(MerchantNormalizer.key(for: "12345"), "")
    }

    func testLearnedRuleBeatsBuiltInKeyword() {
        // Built-in says Dining, but the user filed Starbucks under Groceries (beans).
        XCTAssertEqual(Categorizer.category(forName: "STARBUCKS #12", rules: [:]), "Dining")
        XCTAssertEqual(Categorizer.category(forName: "STARBUCKS #12", rules: ["STARBUCKS": "Groceries"]), "Groceries")
    }

    func testBuiltInKeywordsAndNoMatch() {
        XCTAssertEqual(Categorizer.category(forName: "UBER EATS 8005928996", rules: [:]), "Dining")
        XCTAssertEqual(Categorizer.category(forName: "UBER *TRIP HELP.UBER.COM", rules: [:]), "Transport")
        XCTAssertEqual(Categorizer.category(forName: "ACME PAYROLL DIRECT DEP", rules: [:]), "Income")
        XCTAssertNil(Categorizer.category(forName: "Joe's Hardware", rules: [:]))
    }

    func testRuleAppliesAcrossStoreNumbers() {
        let rules = ["JOE'S HARDWARE": "Other"]
        XCTAssertEqual(Categorizer.category(forName: "JOE'S HARDWARE #44 PORTLAND OR", rules: rules), "Other")
    }

    func testKeywordsMatchWholeWordStartsOnly() {
        XCTAssertEqual(Categorizer.category(forName: "APT RENT PMT", rules: [:]), "Housing")
        XCTAssertNil(Categorizer.category(forName: "CURRENT CARD XFER", rules: [:]))
    }
}
