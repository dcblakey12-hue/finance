import XCTest
@testable import Finance

import SwiftData

// Plain-struct builders for the testable ForecastService core.
private func bill(_ name: String, _ amount: Double, day: Int, cat: String = "Other", income: Bool = false)
    -> (name: String, amount: Double, dueDay: Int, category: String, isIncome: Bool) {
    (name, amount, day, cat, income)
}
private func env(_ cat: String, year: Int, month: Int, amount: Double)
    -> (category: String, year: Int, month: Int, allocated: Double) {
    (cat, year, month, amount)
}

final class CashFlowForecastTests: XCTestCase {
    private var baseDate: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 10))! // Jun 10 (local, like app)
    }

    func testIncomeMinusBillsRollsForward() {
        let months = CashFlowForecastService.forecastPlain(
            bills: [bill("Paycheck", 2000, day: 1, cat: "Income", income: true),
                    bill("Rent", 1500, day: 5, cat: "Housing")],
            envelopes: [], transactions: [],
            options: ForecastOptions(months: 3, includeEnvelopes: false, fallbackAverageVariable: false,
                                     inferIncomeFromHistory: false, startingBalance: 1000, from: baseDate))
        XCTAssertEqual(months.count, 3)
        // Jun: income day 1 excluded (before Jun 10)? No - day 1 < Jun 10 so only Rent counts? Wait: both excluded?
        // Paycheck day 1 = Jun 1 < Jun 10 -> excluded. Rent day 5 = Jun 5 < Jun 10 -> excluded.
        // So Jun net should be 0. Jul onward net +500.
        XCTAssertEqual(months[0].net, 0, accuracy: 0.001)
        XCTAssertEqual(months[1].net, 500, accuracy: 0.001)
        XCTAssertEqual(months[2].closingBalance, 2000, accuracy: 0.001)
    }

    func testEnvelopeAvoidsDoubleCount() {
        // Housing envelope 1500, Rent bill 1200 -> envelope variable 300, total 1500.
        let months = CashFlowForecastService.forecastPlain(
            bills: [bill("Paycheck", 3000, day: 1, cat: "Income", income: true),
                    bill("Rent", 1200, day: 1, cat: "Housing")],
            envelopes: [env("Housing", year: 2026, month: 7, amount: 1500)],
            transactions: [],
            options: ForecastOptions(months: 3, includeEnvelopes: true, fallbackAverageVariable: false,
                                     inferIncomeFromHistory: false, startingBalance: 0, from: baseDate))
        // Month 1 (Jun): no envelope defined for Jun, falls back to template (Jul) -> Housing 1500.
        XCTAssertEqual(months[0].scheduledExpenses, 0, accuracy: 0.001) // both day 1 excluded (before Jun 10)
        // Month 2 (Jul): scheduled 1200 + remainder 300 = 1500 total.
        let jul = months[1]
        XCTAssertEqual(jul.scheduledIncome, 3000, accuracy: 0.001)
        XCTAssertEqual(jul.scheduledExpenses, 1200, accuracy: 0.001)
        XCTAssertEqual(jul.envelopeSpend, 300, accuracy: 0.001)
        XCTAssertEqual(jul.totalExpenses, 1500, accuracy: 0.001)
        XCTAssertEqual(jul.net, 1500, accuracy: 0.001)
    }

    func testIntraMonthLowCapturesTiming() {
        // Start Jun 1 so June's day-5 bill + day-15 income are both in the first month.
        let start = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let months = CashFlowForecastService.forecastPlain(
            bills: [bill("Paycheck", 1000, day: 15, cat: "Income", income: true),
                    bill("Rent", 900, day: 5, cat: "Housing")],
            envelopes: [], transactions: [],
            options: ForecastOptions(months: 3, includeEnvelopes: false, fallbackAverageVariable: false,
                                     inferIncomeFromHistory: false, startingBalance: 100, from: start))
        let first = months[0]
        XCTAssertEqual(first.intraMonthLow, -800, accuracy: 0.001) // 100 - 900
        XCTAssertEqual(first.closingBalance, 200, accuracy: 0.001)  // 100 + 100
        XCTAssertTrue(first.goesNegative)
    }
}
