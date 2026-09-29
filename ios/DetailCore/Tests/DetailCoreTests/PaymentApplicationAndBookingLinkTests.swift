import XCTest
@testable import DetailCore

/// Payments ledger classification (web paymentFormat.ts parity), the
/// booking-page link builder (web `bookingPageUrl`), the business-hours
/// weekday order and the lapsed-shop notice rule.
final class PaymentApplicationAndBookingLinkTests: XCTestCase {

    private let invoice = UUID()
    private let job = UUID()
    private let membership = UUID()

    // MARK: - Unapplied payments

    func testTargetPrefersInvoiceThenJobThenMembership() {
        XCTAssertEqual(PaymentApplication.target(invoiceID: invoice, jobID: job, membershipID: nil), .invoice(invoice))
        XCTAssertEqual(PaymentApplication.target(invoiceID: nil, jobID: job, membershipID: nil), .job(job))
        XCTAssertEqual(PaymentApplication.target(invoiceID: nil, jobID: nil, membershipID: membership), .membership(membership))
        XCTAssertEqual(PaymentApplication.target(invoiceID: nil, jobID: nil, membershipID: nil), .unapplied)
    }

    func testUnappliedMeansNoInvoiceJobOrMembership() {
        XCTAssertTrue(PaymentApplication.isUnapplied(invoiceID: nil, jobID: nil, membershipID: nil))
        XCTAssertFalse(PaymentApplication.isUnapplied(invoiceID: invoice, jobID: nil, membershipID: nil))
        XCTAssertFalse(PaymentApplication.isUnapplied(invoiceID: nil, jobID: job, membershipID: nil))
        XCTAssertFalse(PaymentApplication.isUnapplied(invoiceID: nil, jobID: nil, membershipID: membership))
    }

    func testOnlyReceivedUnappliedMoneyWithSomethingLeftCanBeApplied() {
        func can(_ status: PaymentStatus, amount: Int = 5_000, refunded: Int = 0,
                 invoiceID: UUID? = nil, jobID: UUID? = nil, membershipID: UUID? = nil) -> Bool {
            PaymentApplication.canApplyToInvoice(
                invoiceID: invoiceID, jobID: jobID, membershipID: membershipID,
                status: status, amountCents: amount, refundedCents: refunded
            )
        }
        XCTAssertTrue(can(.succeeded))
        XCTAssertTrue(can(.partiallyRefunded, refunded: 1_000))
        XCTAssertFalse(can(.partiallyRefunded, refunded: 5_000))
        XCTAssertFalse(can(.refunded, refunded: 5_000))
        XCTAssertFalse(can(.pending))
        XCTAssertFalse(can(.processing))
        XCTAssertFalse(can(.failed))
        XCTAssertFalse(can(.succeeded, invoiceID: invoice))
        XCTAssertFalse(can(.succeeded, jobID: job))
        XCTAssertFalse(can(.succeeded, membershipID: membership))
    }

    func testApplicableCentsLeavesTheTipAndRefundsOut() {
        XCTAssertEqual(PaymentApplication.applicableCents(amountCents: 5_000, refundedCents: 0), 5_000)
        XCTAssertEqual(PaymentApplication.applicableCents(amountCents: 5_000, refundedCents: 1_200), 3_800)
        // Refunds beyond the amount came off the tip: nothing left to apply.
        XCTAssertEqual(PaymentApplication.applicableCents(amountCents: 5_000, refundedCents: 5_600), 0)
    }

    func testRefundableIsAmountPlusTipLessRefundsForReceivedMoney() {
        XCTAssertEqual(PaymentApplication.refundableCents(status: .succeeded, amountCents: 5_000, tipCents: 700, refundedCents: 0), 5_700)
        XCTAssertEqual(PaymentApplication.refundableCents(status: .partiallyRefunded, amountCents: 5_000, tipCents: 700, refundedCents: 5_200), 500)
        XCTAssertEqual(PaymentApplication.refundableCents(status: .refunded, amountCents: 5_000, tipCents: 0, refundedCents: 5_000), 0)
        XCTAssertEqual(PaymentApplication.refundableCents(status: .processing, amountCents: 5_000, tipCents: 0, refundedCents: 0), 0)
    }

    // MARK: - Booking link

    func testBookingLinkIsTheWebBookingPage() throws {
        let base = try XCTUnwrap(URL(string: "https://app.example.com"))
        let token = "0f8fad5b-d9cb-469f-a165-70867728950e"
        XCTAssertEqual(
            BookingLink.url(token: token, webAppBase: base)?.absoluteString,
            "https://app.example.com/booking/0f8fad5b-d9cb-469f-a165-70867728950e"
        )
        let slash = try XCTUnwrap(URL(string: "https://app.example.com/"))
        XCTAssertEqual(
            BookingLink.url(token: " \(token)\n", webAppBase: slash)?.absoluteString,
            "https://app.example.com/booking/0f8fad5b-d9cb-469f-a165-70867728950e"
        )
        let nested = try XCTUnwrap(URL(string: "https://example.com/crm"))
        XCTAssertEqual(BookingLink.url(token: token, webAppBase: nested)?.absoluteString, "https://example.com/crm/booking/\(token)")
    }

    func testBookingLinkNeedsABaseAndAToken() throws {
        let base = try XCTUnwrap(URL(string: "https://app.example.com"))
        XCTAssertNil(BookingLink.url(token: "abc", webAppBase: nil))
        XCTAssertNil(BookingLink.url(token: "  ", webAppBase: base))
        XCTAssertNil(BookingLink.url(token: "../admin", webAppBase: base))
    }

    func testBookingLinkChannelsFollowTheContactDetails() {
        XCTAssertEqual(BookingLink.channels(hasPhone: true, hasEmail: true), [.sms, .email])
        XCTAssertEqual(BookingLink.channels(hasPhone: false, hasEmail: true), [.email])
        XCTAssertEqual(BookingLink.channels(hasPhone: true, hasEmail: false), [.sms])
        XCTAssertEqual(BookingLink.channels(hasPhone: false, hasEmail: false), [])
        XCTAssertEqual(BookingLink.Channel.sms.rawValue, "sms")
        XCTAssertEqual(BookingLink.Channel.email.rawValue, "email")
    }

    // MARK: - Business hours order

    func testBusinessHoursListMondayFirst() {
        XCTAssertEqual(ShopClock.businessHoursWeekdays, [1, 2, 3, 4, 5, 6, 0])
        XCTAssertEqual(ShopClock.orderedWeekdayNumbers(firstWeekday: 1), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(ShopClock.orderedWeekdayNumbers(firstWeekday: 7), [6, 0, 1, 2, 3, 4, 5])
        // Out of range is clamped rather than trapping.
        XCTAssertEqual(ShopClock.orderedWeekdayNumbers(firstWeekday: 0), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(ShopClock.orderedWeekdayNumbers(firstWeekday: 9), [6, 0, 1, 2, 3, 4, 5])
    }

    // MARK: - Lapsed shops

    func testOnlyLapsedNoticesPauseNewRecords() {
        XCTAssertTrue(ShopEntitlement.Notice.paused.pausesNewRecords)
        XCTAssertTrue(ShopEntitlement.Notice.trialEnded.pausesNewRecords)
        XCTAssertTrue(ShopEntitlement.Notice.noSubscription.pausesNewRecords)
        XCTAssertFalse(ShopEntitlement.Notice.paymentProblem.pausesNewRecords)
        XCTAssertFalse(ShopEntitlement.Notice.trialEnds(Date(timeIntervalSince1970: 0)).pausesNewRecords)
    }
}
