import XCTest
@testable import DetailCore

final class DocumentTotalsTests: XCTestCase {

    func testLineTotalRoundsQuantityTimesPriceHalfUp() {
        // 1.5 × 333 = 499.5 -> 500
        XCTAssertEqual(TotalsLine(quantity: Decimal(string: "1.5")!, unitPriceCents: 333).lineTotalCents, 500)
        // 0.25 × 10 = 2.5 -> 3
        XCTAssertEqual(TotalsLine(quantity: Decimal(string: "0.25")!, unitPriceCents: 10).lineTotalCents, 3)
        // 2.33 × 1999 = 4657.67 -> 4658
        XCTAssertEqual(TotalsLine(quantity: Decimal(string: "2.33")!, unitPriceCents: 1_999).lineTotalCents, 4_658)
        // Quantity beyond numeric(10,2) is stored rounded: 1.005 -> 1.01
        XCTAssertEqual(TotalsLine(quantity: Decimal(string: "1.005")!, unitPriceCents: 10_000).lineTotalCents, 10_100)
    }

    func testLineDiscountNeverGoesBelowZero() {
        XCTAssertEqual(TotalsLine(quantity: 2, unitPriceCents: 5_000, discountCents: 1_500).lineTotalCents, 8_500)
        XCTAssertEqual(TotalsLine(quantity: 1, unitPriceCents: 5_000, discountCents: 9_000).lineTotalCents, 0)
        XCTAssertEqual(TotalsLine(quantity: 1, unitPriceCents: 5_000, discountCents: -100).lineTotalCents, 5_000)
    }

    func testSimpleTotalsWithTax() {
        // 2 × $50 taxable + $30 non-taxable, 8.25% tax on $100 = 825
        let totals = DocumentTotals(
            lines: [
                TotalsLine(quantity: 2, unitPriceCents: 5_000, taxable: true),
                TotalsLine(quantity: 1, unitPriceCents: 3_000, taxable: false),
            ],
            taxRateBps: 825
        )
        XCTAssertEqual(totals.subtotalCents, 13_000)
        XCTAssertEqual(totals.discountCents, 0)
        XCTAssertEqual(totals.taxableBaseCents, 10_000)
        XCTAssertEqual(totals.taxCents, 825)
        XCTAssertEqual(totals.totalCents, 13_825)
    }

    func testTaxRoundsHalfUp() {
        // $10.10 at 5% = 50.5 cents -> 51
        let totals = DocumentTotals(lines: [TotalsLine(unitPriceCents: 1_010)], taxRateBps: 500)
        XCTAssertEqual(totals.taxCents, 51)
        XCTAssertEqual(totals.totalCents, 1_061)
        // $0.10 at 5% = 0.5 -> 1
        XCTAssertEqual(DocumentTotals(lines: [TotalsLine(unitPriceCents: 10)], taxRateBps: 500).taxCents, 1)
        // $0.09 at 5% = 0.45 -> 0
        XCTAssertEqual(DocumentTotals(lines: [TotalsLine(unitPriceCents: 9)], taxRateBps: 500).taxCents, 0)
    }

    func testFixedDiscountCappedAtSubtotal() {
        let totals = DocumentTotals(
            lines: [TotalsLine(unitPriceCents: 4_000)],
            discount: .fixed(cents: 10_000),
            taxRateBps: 1_000
        )
        XCTAssertEqual(totals.subtotalCents, 4_000)
        XCTAssertEqual(totals.discountCents, 4_000)
        XCTAssertEqual(totals.taxableBaseCents, 0)
        XCTAssertEqual(totals.taxCents, 0)
        XCTAssertEqual(totals.totalCents, 0)
    }

    func testPercentDiscountRoundsHalfUpAndCaps() {
        // 12.5% of $19.99 = 249.875 -> 250
        XCTAssertEqual(DocumentDiscount.percent(basisPoints: 1_250).cents(forSubtotal: 1_999), 250)
        // 150% is capped at the subtotal
        XCTAssertEqual(DocumentDiscount.percent(basisPoints: 15_000).cents(forSubtotal: 1_000), 1_000)
        XCTAssertEqual(DocumentDiscount.fixed(cents: -50).cents(forSubtotal: 1_000), 0)
        XCTAssertEqual(DocumentDiscount.none.cents(forSubtotal: 1_000), 0)
    }

    func testDiscountProratedToTaxableLines() {
        // Taxable $60, non-taxable $40, subtotal $100, $10 discount.
        // Taxable share of discount = round(1000 × 6000 / 10000) = 600.
        // Taxable base = 6000 − 600 = 5400; tax 10% = 540.
        let totals = DocumentTotals(
            lines: [
                TotalsLine(unitPriceCents: 6_000, taxable: true),
                TotalsLine(unitPriceCents: 4_000, taxable: false),
            ],
            discount: .fixed(cents: 1_000),
            taxRateBps: 1_000
        )
        XCTAssertEqual(totals.discountCents, 1_000)
        XCTAssertEqual(totals.taxableBaseCents, 5_400)
        XCTAssertEqual(totals.taxCents, 540)
        XCTAssertEqual(totals.totalCents, 10_000 - 1_000 + 540)
    }

    func testProratedDiscountRoundsHalfUp() {
        // Taxable 3333 of subtotal 6666 with a 1-cent discount:
        // share = 1 × 3333 / 6666 = 0.5 -> 1, so the base is 3332.
        let totals = DocumentTotals(
            lines: [
                TotalsLine(unitPriceCents: 3_333, taxable: true),
                TotalsLine(unitPriceCents: 3_333, taxable: false),
            ],
            discount: .fixed(cents: 1),
            taxRateBps: 0
        )
        XCTAssertEqual(totals.taxableBaseCents, 3_332)
        XCTAssertEqual(totals.totalCents, 6_665)
    }

    func testAllNonTaxable() {
        let totals = DocumentTotals(
            lines: [TotalsLine(unitPriceCents: 2_500, taxable: false)],
            discount: .percent(basisPoints: 1_000),
            taxRateBps: 900
        )
        XCTAssertEqual(totals.discountCents, 250)
        XCTAssertEqual(totals.taxCents, 0)
        XCTAssertEqual(totals.totalCents, 2_250)
    }

    func testOptionalLinesCountOnlyWhenSelected() {
        let lines = [
            TotalsLine(unitPriceCents: 20_000),
            TotalsLine(unitPriceCents: 5_000, isOptional: true, isSelected: false),
            TotalsLine(unitPriceCents: 3_000, isOptional: true, isSelected: true),
        ]
        let totals = DocumentTotals(lines: lines, taxRateBps: 1_000)
        XCTAssertEqual(totals.lineTotalsCents, [20_000, 0, 3_000])
        XCTAssertEqual(totals.subtotalCents, 23_000)
        XCTAssertEqual(totals.taxCents, 2_300)
        XCTAssertEqual(totals.totalCents, 25_300)
    }

    func testDiscountFromDatabasePair() {
        XCTAssertEqual(DocumentDiscount(kind: "percent", value: 1_000), .percent(basisPoints: 1_000))
        XCTAssertEqual(DocumentDiscount(kind: "fixed", value: 500), .fixed(cents: 500))
        XCTAssertEqual(DocumentDiscount(kind: "none", value: 500), DocumentDiscount.none)
        XCTAssertEqual(DocumentDiscount.percent(basisPoints: 5).kindRawValue, "percent")
    }

    func testEmptyDocument() {
        let totals = DocumentTotals(lines: [], discount: .fixed(cents: 500), taxRateBps: 800)
        XCTAssertEqual(totals.subtotalCents, 0)
        XCTAssertEqual(totals.discountCents, 0)
        XCTAssertEqual(totals.taxCents, 0)
        XCTAssertEqual(totals.totalCents, 0)
    }

    func testBalanceIgnoresTips() {
        // Tips are never part of amount_paid; balance = total − paid.
        XCTAssertEqual(DocumentTotals.balanceCents(totalCents: 10_000, amountPaidCents: 2_500), 7_500)
        XCTAssertEqual(DocumentTotals.balanceCents(totalCents: 10_000, amountPaidCents: 10_000), 0)
    }
}
