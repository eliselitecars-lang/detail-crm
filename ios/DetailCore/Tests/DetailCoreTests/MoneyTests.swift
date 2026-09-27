import XCTest
@testable import DetailCore

final class RoundingTests: XCTestCase {

    func testHalfAwayFromZeroPositive() {
        XCTAssertEqual(Rounding.divideHalfAwayFromZero(5, 10), 1)     // 0.5 -> 1
        XCTAssertEqual(Rounding.divideHalfAwayFromZero(15, 10), 2)    // 1.5 -> 2
        XCTAssertEqual(Rounding.divideHalfAwayFromZero(25, 10), 3)    // 2.5 -> 3 (not banker's 2)
        XCTAssertEqual(Rounding.divideHalfAwayFromZero(24, 10), 2)
        XCTAssertEqual(Rounding.divideHalfAwayFromZero(26, 10), 3)
        XCTAssertEqual(Rounding.divideHalfAwayFromZero(0, 7), 0)
        XCTAssertEqual(Rounding.divideHalfAwayFromZero(10, 3), 3)     // 3.33
        XCTAssertEqual(Rounding.divideHalfAwayFromZero(20, 3), 7)     // 6.67
    }

    func testHalfAwayFromZeroNegative() {
        XCTAssertEqual(Rounding.divideHalfAwayFromZero(-5, 10), -1)
        XCTAssertEqual(Rounding.divideHalfAwayFromZero(-25, 10), -3)
        XCTAssertEqual(Rounding.divideHalfAwayFromZero(-24, 10), -2)
    }

    func testDecimalRound() {
        XCTAssertEqual(Rounding.round(Decimal(string: "2.345")!, scale: 2), Decimal(string: "2.35")!)
        XCTAssertEqual(Rounding.round(Decimal(string: "-2.345")!, scale: 2), Decimal(string: "-2.35")!)
        XCTAssertEqual(Rounding.round(Decimal(string: "2.5")!, scale: 0), Decimal(3))
    }
}

final class MoneyTests: XCTestCase {
    let us = Locale(identifier: "en_US")

    func testFormatUSD() {
        XCTAssertEqual(Money.format(cents: 123_456, currencyCode: "usd", locale: us), "$1,234.56")
        XCTAssertEqual(Money.format(cents: 5, currencyCode: "USD", locale: us), "$0.05")
        XCTAssertEqual(Money.format(cents: 0, currencyCode: "USD", locale: us), "$0.00")
        XCTAssertEqual(Money.format(cents: 10_000, currencyCode: "USD", locale: us, showsZeroFraction: false), "$100")
        XCTAssertEqual(Money.format(cents: 10_050, currencyCode: "USD", locale: us, showsZeroFraction: false), "$100.50")
    }

    func testFormatNegativeContainsAmount() {
        let text = Money.format(cents: -2_500, currencyCode: "USD", locale: us)
        XCTAssertTrue(text.contains("25.00"), text)
        XCTAssertTrue(text.contains("-") || text.contains("("), text)
    }

    func testZeroDecimalCurrency() {
        XCTAssertEqual(Money.minorUnitDigits(for: "jpy"), 0)
        XCTAssertEqual(Money.minorUnitDigits(for: "USD"), 2)
        XCTAssertEqual(Money.parseCents("1,500", currencyCode: "JPY", locale: us), 1_500)
        XCTAssertNil(Money.parseCents("15.5", currencyCode: "JPY", locale: us))
    }

    func testParseCents() {
        XCTAssertEqual(Money.parseCents("12", locale: us), 1_200)
        XCTAssertEqual(Money.parseCents("12.5", locale: us), 1_250)
        XCTAssertEqual(Money.parseCents("12.50", locale: us), 1_250)
        XCTAssertEqual(Money.parseCents("$1,234.56", locale: us), 123_456)
        XCTAssertEqual(Money.parseCents("  $ 99.99 ", locale: us), 9_999)
        XCTAssertEqual(Money.parseCents(".99", locale: us), 99)
        XCTAssertEqual(Money.parseCents("0", locale: us), 0)
        XCTAssertEqual(Money.parseCents("USD 40", locale: us), 4_000)
    }

    func testParseRejectsAmbiguousInput() {
        XCTAssertNil(Money.parseCents("", locale: us))
        XCTAssertNil(Money.parseCents("abc", locale: us))
        XCTAssertNil(Money.parseCents("1.234", locale: us))       // too many decimals
        XCTAssertNil(Money.parseCents("1.2.3", locale: us))
        XCTAssertNil(Money.parseCents("-5", locale: us))          // negative not allowed by default
        XCTAssertNil(Money.parseCents(".", locale: us))
        XCTAssertNil(Money.parseCents("12a", locale: us))
        XCTAssertNil(Money.parseCents("99999999999999999999", locale: us))
    }

    func testParseNegativeWhenAllowed() {
        XCTAssertEqual(Money.parseCents("-5", locale: us, allowNegative: true), -500)
        XCTAssertEqual(Money.parseCents("-$5.25", locale: us, allowNegative: true), -525)
        XCTAssertEqual(Money.parseCents("($5.25)", locale: us, allowNegative: true), -525)
    }

    func testParseGermanLocale() {
        let de = Locale(identifier: "de_DE")
        XCTAssertEqual(Money.parseCents("1.234,56", currencyCode: "EUR", locale: de), 123_456)
        XCTAssertEqual(Money.parseCents("12,5 €", currencyCode: "EUR", locale: de), 1_250)
    }

    func testEditableString() {
        XCTAssertEqual(Money.editableString(cents: 123_450, locale: us), "1234.50")
        XCTAssertEqual(Money.editableString(cents: 5, locale: us), "0.05")
        XCTAssertEqual(Money.editableString(cents: -105, locale: us), "-1.05")
        XCTAssertEqual(Money.editableString(cents: 700, currencyCode: "JPY", locale: us), "700")
    }

    func testRoundTrip() {
        for cents in [0, 1, 9, 10, 99, 100, 101, 12_345, 999_999] {
            let text = Money.editableString(cents: cents, locale: us)
            XCTAssertEqual(Money.parseCents(text, locale: us), cents, text)
        }
    }
}
