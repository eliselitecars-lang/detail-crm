import XCTest
@testable import DetailCore

final class InvoiceBalanceHeadlineTests: XCTestCase {

    func testPaidShowsTheAmountReceivedNotTheZeroBalance() {
        let headline = InvoiceBalanceHeadline.make(status: .paid, balanceCents: 0, amountPaidCents: 19_556)
        XCTAssertEqual(headline.title, "Paid in full")
        XCTAssertEqual(headline.amount, .paid(cents: 19_556))
    }

    func testOverpaidShowsEverythingReceived() {
        // total 195.56, paid 210.00: the credit is shown separately.
        let headline = InvoiceBalanceHeadline.make(status: .paid, balanceCents: -1_444, amountPaidCents: 21_000)
        XCTAssertEqual(headline.amount, .paid(cents: 21_000))
    }

    func testOpenAndPartiallyPaidShowTheBalanceDue() {
        let open = InvoiceBalanceHeadline.make(status: .open, balanceCents: 40_204, amountPaidCents: 0)
        XCTAssertEqual(open, InvoiceBalanceHeadline(title: "Balance due", amount: .due(cents: 40_204)))
        let partial = InvoiceBalanceHeadline.make(status: .partiallyPaid, balanceCents: 9_556, amountPaidCents: 10_000)
        XCTAssertEqual(partial, InvoiceBalanceHeadline(title: "Balance due", amount: .due(cents: 9_556)))
    }

    func testDraftShowsTheBalanceAsNotIssued() {
        let draft = InvoiceBalanceHeadline.make(status: .draft, balanceCents: 15_000, amountPaidCents: 0)
        XCTAssertEqual(draft, InvoiceBalanceHeadline(title: "Balance (not issued yet)", amount: .due(cents: 15_000)))
    }

    func testVoidShowsNoAmount() {
        let void = InvoiceBalanceHeadline.make(status: .void, balanceCents: 15_000, amountPaidCents: 0)
        XCTAssertEqual(void, InvoiceBalanceHeadline(title: "Void", amount: .noAmount))
        XCTAssertEqual(InvoiceBalanceHeadline.voidNote, "Nothing is owed on this invoice.")
    }

    func testAmountsNeverGoBelowZero() {
        let open = InvoiceBalanceHeadline.make(status: .open, balanceCents: -500, amountPaidCents: 0)
        XCTAssertEqual(open.amount, .due(cents: 0))
    }
}
