import XCTest
@testable import DetailCore

final class SessionExpiryTests: XCTestCase {

    // MARK: - Which replies are the gateway refusing the session

    func testOnlyANonEnvelope401IsAGatewayRejection() {
        // `{"code":401,"message":"Invalid JWT"}` from the API gateway.
        XCTAssertTrue(SessionExpiry.isGatewayRejection(status: 401, isEnvelope: false))
        // Our function's own 401 (`{"error","code":"unauthorized"}`): a business answer.
        XCTAssertFalse(SessionExpiry.isGatewayRejection(status: 401, isEnvelope: true))
        for status in [0, 400, 403, 404, 409, 422, 429, 500, 503] {
            XCTAssertFalse(SessionExpiry.isGatewayRejection(status: status, isEnvelope: false), "\(status)")
        }
    }

    // MARK: - What a refresh outcome means

    func testARefreshThatWorkedOrNeverAnsweredKeepsTheSession() {
        XCTAssertFalse(SessionExpiry.sessionIsGone(after: .refreshed))
        XCTAssertFalse(SessionExpiry.sessionIsGone(after: .inconclusive))
    }

    func testAMissingSessionIsGone() {
        XCTAssertTrue(SessionExpiry.sessionIsGone(after: .sessionMissing))
    }

    func testSessionEndingAuthCodesEndTheSession() {
        for code in ["session_not_found", "session_expired", "refresh_token_not_found",
                     "refresh_token_already_used", "user_not_found", "user_banned"] {
            XCTAssertTrue(SessionExpiry.sessionIsGone(after: .refused(status: 400, code: code)), code)
            XCTAssertTrue(SessionExpiry.sessionIsGone(after: .refused(status: 403, code: code)), code)
        }
    }

    func testALegacyInvalidGrantEndsTheSession() {
        XCTAssertTrue(SessionExpiry.sessionIsGone(after: .refused(status: 400, code: nil)))
        XCTAssertTrue(SessionExpiry.sessionIsGone(after: .refused(status: 400, code: "unknown")))
        XCTAssertTrue(SessionExpiry.sessionIsGone(after: .refused(status: 400, code: "invalid_grant")))
        XCTAssertTrue(SessionExpiry.sessionIsGone(after: .refused(status: 401, code: nil)))
    }

    func testRateLimitsServerTroubleAndOtherCodesKeepTheSession() {
        XCTAssertFalse(SessionExpiry.sessionIsGone(after: .refused(status: 429, code: "over_request_rate_limit")))
        XCTAssertFalse(SessionExpiry.sessionIsGone(after: .refused(status: 429, code: nil)))
        XCTAssertFalse(SessionExpiry.sessionIsGone(after: .refused(status: 500, code: nil)))
        XCTAssertFalse(SessionExpiry.sessionIsGone(after: .refused(status: 503, code: "unexpected_failure")))
        XCTAssertFalse(SessionExpiry.sessionIsGone(after: .refused(status: 504, code: "request_timeout")))
        // An undecodable body (a proxy's page) is not Auth speaking.
        XCTAssertFalse(SessionExpiry.sessionIsGone(after: .refused(status: 400, code: "unexpected_failure")))
        XCTAssertFalse(SessionExpiry.sessionIsGone(after: .refused(status: 403, code: nil)))
    }

    func testTheNoticeIsAShortSentence() {
        XCTAssertEqual(SessionExpiry.notice, "Your session has expired. Sign in again to continue.")
    }

    // MARK: - Gate: one sign-out per lost session

    func testAGatewayRejectionIsCheckedOnceAndEndsTheSessionWhenTheRefreshIsRefused() {
        var gate = SessionExpiryGate()
        let ticket = gate.beginVerification(signedIn: true)
        XCTAssertNotNil(ticket)
        // Every other request failing meanwhile waits for the same check.
        XCTAssertNil(gate.beginVerification(signedIn: true))
        XCTAssertNil(gate.beginVerification(signedIn: true))
        XCTAssertTrue(gate.finishVerification(
            ticket: ticket ?? -1, outcome: .refused(status: 400, code: "refresh_token_not_found"), signedIn: true))
        XCTAssertEqual(gate.state, .signingOut)
        // Late reports while signing out, and a second sign-out, are ignored.
        XCTAssertNil(gate.beginVerification(signedIn: true))
        XCTAssertFalse(gate.beginSignOut())
        gate.finishSignOut()
        XCTAssertEqual(gate.state, .idle)
        // After the sign-out nobody is signed in: reports from screens still
        // finishing their requests do nothing (no loop).
        XCTAssertNil(gate.beginVerification(signedIn: false))
        XCTAssertEqual(gate.state, .idle)
    }

    func testARefreshThatWorksKeepsTheUserSignedIn() {
        var gate = SessionExpiryGate()
        let ticket = gate.beginVerification(signedIn: true) ?? -1
        XCTAssertFalse(gate.finishVerification(ticket: ticket, outcome: .refreshed, signedIn: true))
        XCTAssertEqual(gate.state, .idle)
        // A later rejection is checked again.
        XCTAssertNotNil(gate.beginVerification(signedIn: true))
    }

    func testOfflineDuringTheCheckKeepsTheUserSignedIn() {
        var gate = SessionExpiryGate()
        let ticket = gate.beginVerification(signedIn: true) ?? -1
        XCTAssertFalse(gate.finishVerification(ticket: ticket, outcome: .inconclusive, signedIn: true))
        XCTAssertEqual(gate.state, .idle)
    }

    func testNobodySignedInIsNeverChecked() {
        var gate = SessionExpiryGate()
        XCTAssertNil(gate.beginVerification(signedIn: false))
        XCTAssertEqual(gate.state, .idle)
    }

    func testACheckThatEndsAfterTheUserSignedOutDoesNothing() {
        var gate = SessionExpiryGate()
        let ticket = gate.beginVerification(signedIn: true) ?? -1
        // The user (or the Auth client) signs out while the refresh is running.
        XCTAssertTrue(gate.beginSignOut())
        XCTAssertFalse(gate.finishVerification(ticket: ticket, outcome: .sessionMissing, signedIn: false))
        XCTAssertEqual(gate.state, .signingOut)
        gate.finishSignOut()
        XCTAssertEqual(gate.state, .idle)
    }

    func testAStaleCheckCannotEndANewSession() {
        var gate = SessionExpiryGate()
        let old = gate.beginVerification(signedIn: true) ?? -1
        XCTAssertTrue(gate.beginSignOut())
        gate.finishSignOut()
        // Signed in again; a new rejection starts a new check.
        let fresh = gate.beginVerification(signedIn: true) ?? -1
        XCTAssertNotEqual(old, fresh)
        // The old check's answer (about the previous session) is ignored...
        XCTAssertFalse(gate.finishVerification(ticket: old, outcome: .sessionMissing, signedIn: true))
        XCTAssertEqual(gate.state, .verifying)
        // ...and the new one decides.
        XCTAssertFalse(gate.finishVerification(ticket: fresh, outcome: .refreshed, signedIn: true))
        XCTAssertEqual(gate.state, .idle)
    }

    func testTheSessionEndingWhileSignedOutAlreadyDoesNotSignOutAgain() {
        var gate = SessionExpiryGate()
        let ticket = gate.beginVerification(signedIn: true) ?? -1
        // The Auth client signed out on its own before the check answered.
        XCTAssertFalse(gate.finishVerification(ticket: ticket, outcome: .sessionMissing, signedIn: false))
        XCTAssertEqual(gate.state, .idle)
    }

    func testFinishSignOutWithoutASignOutIsHarmless() {
        var gate = SessionExpiryGate()
        gate.finishSignOut()
        XCTAssertEqual(gate.state, .idle)
        let ticket = gate.beginVerification(signedIn: true) ?? -1
        gate.finishSignOut()
        XCTAssertEqual(gate.state, .verifying, "only a sign-out is finished by finishSignOut")
        XCTAssertFalse(gate.finishVerification(ticket: ticket, outcome: .refreshed, signedIn: true))
    }
}
