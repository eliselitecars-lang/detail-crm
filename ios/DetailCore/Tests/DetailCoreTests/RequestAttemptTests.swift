import XCTest
@testable import DetailCore

final class RequestAttemptTests: XCTestCase {

    func testANewNonceIsUrlSafeAndWithinTheServerLimits() {
        let nonce = RequestAttempt.newNonce()
        XCTAssertEqual(nonce.count, 32)
        XCTAssertTrue(nonce.allSatisfy { $0.isHexDigit && !$0.isUppercase }, nonce)
        XCTAssertNotEqual(nonce, RequestAttempt.newNonce())
    }

    func testEachAttemptStartsWithItsOwnNonce() {
        XCTAssertNotEqual(RequestAttempt().nonce, RequestAttempt().nonce)
        XCTAssertEqual(RequestAttempt(nonce: "fixed-nonce-01").nonce, "fixed-nonce-01")
    }

    /// Two refunds of the same amount in a row are two attempts: the second
    /// must not reuse the first's nonce, or the server treats it as a retry
    /// (and without any nonce refuses it as a possible duplicate).
    func testASecondRequestAfterASuccessIsANewAttempt() {
        var attempt = RequestAttempt()
        let first = attempt.nonce
        attempt.succeeded()
        XCTAssertNotEqual(attempt.nonce, first)
    }

    func testAnUnansweredOrServerFailedRequestIsRetriedWithTheSameNonce() {
        for status in [0, 500, 502, 503, 504] {
            var attempt = RequestAttempt()
            let first = attempt.nonce
            attempt.failed(status: status)
            XCTAssertEqual(attempt.nonce, first, "status \(status)")
        }
    }

    func testADefinitiveRefusalStartsANewAttempt() {
        for status in [400, 401, 402, 403, 404, 409, 422, 429] {
            var attempt = RequestAttempt()
            let first = attempt.nonce
            attempt.failed(status: status)
            XCTAssertNotEqual(attempt.nonce, first, "status \(status)")
        }
    }

    func testOnlyClientErrorsAreDefinitive() {
        XCTAssertFalse(RequestAttempt.isDefinitiveFailure(status: 0))
        XCTAssertFalse(RequestAttempt.isDefinitiveFailure(status: 200))
        XCTAssertFalse(RequestAttempt.isDefinitiveFailure(status: 399))
        XCTAssertTrue(RequestAttempt.isDefinitiveFailure(status: 400))
        XCTAssertTrue(RequestAttempt.isDefinitiveFailure(status: 499))
        XCTAssertFalse(RequestAttempt.isDefinitiveFailure(status: 500))
    }
}
