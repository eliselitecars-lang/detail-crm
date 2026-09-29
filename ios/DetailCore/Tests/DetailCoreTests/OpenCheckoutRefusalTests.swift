import XCTest
@testable import DetailCore

final class OpenCheckoutRefusalTests: XCTestCase {

    private struct Refused: Error, Equatable { let n: Int }
    private struct Other: Error {}

    func testOnlyTheCheckoutOpenRefusalMatches() {
        XCTAssertTrue(OpenCheckoutRefusal.matches(code: "55000", hint: "checkout_open"))
        XCTAssertFalse(OpenCheckoutRefusal.matches(code: "55000", hint: "payment_in_progress"))
        XCTAssertFalse(OpenCheckoutRefusal.matches(code: "55000", hint: nil))
        XCTAssertFalse(OpenCheckoutRefusal.matches(code: "22023", hint: "checkout_open"))
        XCTAssertFalse(OpenCheckoutRefusal.matches(code: nil, hint: nil))
    }

    func testAWriteThatSucceedsNeverReleases() async throws {
        var releases = 0
        let value = try await OpenCheckoutRefusal.retryingAfterRelease(
            isRefusal: { $0 is Refused },
            release: { releases += 1 },
            write: { 7 }
        )
        XCTAssertEqual(value, 7)
        XCTAssertEqual(releases, 0)
    }

    /// Cash recorded while a pay link is open: the pages are released and
    /// the payment is recorded on the second try.
    func testARefusedWriteReleasesThePagesAndTriesOnceMore() async throws {
        var writes = 0
        var releases = 0
        let value = try await OpenCheckoutRefusal.retryingAfterRelease(
            isRefusal: { $0 is Refused },
            release: { releases += 1 },
            write: { () async throws -> Int in
                writes += 1
                if writes == 1 { throw Refused(n: 1) }
                return 42
            }
        )
        XCTAssertEqual(value, 42)
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(releases, 1)
    }

    /// A page that is still processing stays open: the second refusal is
    /// shown (the server's message names when it closes); no loop.
    func testASecondRefusalIsThrownWithoutAnotherRelease() async {
        var writes = 0
        var releases = 0
        do {
            _ = try await OpenCheckoutRefusal.retryingAfterRelease(
                isRefusal: { $0 is Refused },
                release: { releases += 1 },
                write: { () async throws -> Int in
                    writes += 1
                    throw Refused(n: writes)
                }
            )
            XCTFail("expected the refusal")
        } catch {
            XCTAssertEqual(error as? Refused, Refused(n: 2))
        }
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(releases, 1)
    }

    /// Someone who may not release the pages sees the refusal, not the
    /// release's permission error.
    func testAFailedReleaseRethrowsTheOriginalRefusal() async {
        var writes = 0
        do {
            _ = try await OpenCheckoutRefusal.retryingAfterRelease(
                isRefusal: { $0 is Refused },
                release: { throw Other() },
                write: { () async throws -> Int in
                    writes += 1
                    throw Refused(n: writes)
                }
            )
            XCTFail("expected the refusal")
        } catch {
            XCTAssertEqual(error as? Refused, Refused(n: 1))
        }
        XCTAssertEqual(writes, 1)
    }

    func testOtherErrorsAreNotRetried() async {
        var writes = 0
        var releases = 0
        do {
            _ = try await OpenCheckoutRefusal.retryingAfterRelease(
                isRefusal: { $0 is Refused },
                release: { releases += 1 },
                write: { () async throws -> Int in
                    writes += 1
                    throw Other()
                }
            )
            XCTFail("expected the error")
        } catch {
            XCTAssertTrue(error is Other)
        }
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(releases, 0)
    }

    // MARK: - 0118 price / deposit cuts: release only after asking

    /// Nothing was paid while the pages closed: the cut is saved.
    func testACutIsSavedAgainWhenNoPaymentLanded() async throws {
        var writes = 0
        let outcome = try await OpenCheckoutRefusal.releaseThenSaveAgain(
            release: { OpenPaymentsRelease(cancelled: 1, sessionsExpired: 1) },
            write: { () async throws -> Int in
                writes += 1
                return 9
            }
        )
        guard case .saved(let value) = outcome else { return XCTFail("expected saved, got \(outcome)") }
        XCTAssertEqual(value, 9)
        XCTAssertEqual(writes, 1)
    }

    /// The customer's deposit went through while the page was being
    /// closed: the price cut is NOT saved (the job would end up overpaid)
    /// and the release is handed back for the notice.
    func testACutStopsWhenTheDepositWentThroughDuringTheRelease() async throws {
        var writes = 0
        let outcome = try await OpenCheckoutRefusal.releaseThenSaveAgain(
            release: { OpenPaymentsRelease(succeeded: 1, sessionsExpired: 1) },
            write: { () async throws -> Int in
                writes += 1
                return 9
            }
        )
        guard case .notSaved(let release) = outcome else { return XCTFail("expected notSaved, got \(outcome)") }
        XCTAssertEqual(release.succeeded, 1)
        XCTAssertEqual(writes, 0)
    }

    /// A payment still processing may yet land: the cut waits too.
    func testACutStopsWhileAPaymentIsStillProcessing() async throws {
        var writes = 0
        let outcome = try await OpenCheckoutRefusal.releaseThenSaveAgain(
            release: { OpenPaymentsRelease(inProgress: 1) },
            write: { () async throws -> Int in
                writes += 1
                return 9
            }
        )
        guard case .notSaved = outcome else { return XCTFail("expected notSaved, got \(outcome)") }
        XCTAssertEqual(writes, 0)
    }

    /// A failed release (no permission, network) never saves the cut.
    func testAFailedReleaseNeverSavesTheCut() async {
        var writes = 0
        do {
            _ = try await OpenCheckoutRefusal.releaseThenSaveAgain(
                release: { () async throws -> OpenPaymentsRelease in throw Other() },
                write: { () async throws -> Int in
                    writes += 1
                    return 9
                }
            )
            XCTFail("expected the release error")
        } catch {
            XCTAssertTrue(error is Other)
        }
        XCTAssertEqual(writes, 0)
    }

    /// A page opened again in the meantime: the second refusal is shown,
    /// with no second release.
    func testASecondRefusalAfterTheReleaseIsThrown() async {
        var releases = 0
        do {
            _ = try await OpenCheckoutRefusal.releaseThenSaveAgain(
                release: { () async throws -> OpenPaymentsRelease in
                    releases += 1
                    return OpenPaymentsRelease(cancelled: 1)
                },
                write: { () async throws -> Int in throw Refused(n: 2) }
            )
            XCTFail("expected the refusal")
        } catch {
            XCTAssertEqual(error as? Refused, Refused(n: 2))
        }
        XCTAssertEqual(releases, 1)
    }

    func testPaymentLandedCountsSucceededAndInProgressOnly() {
        XCTAssertFalse(OpenPaymentsRelease().paymentLanded)
        XCTAssertFalse(OpenPaymentsRelease(cancelled: 2, sessionsExpired: 3).paymentLanded)
        XCTAssertTrue(OpenPaymentsRelease(succeeded: 1).paymentLanded)
        XCTAssertTrue(OpenPaymentsRelease(inProgress: 1).paymentLanded)
    }

    func testTheSummarySaysWhatLandedAndThatTheChangeWasNotSaved() {
        let one = OpenCheckoutRefusal.releaseSummary(OpenPaymentsRelease(succeeded: 1, sessionsExpired: 1))
        XCTAssertEqual(one.title, "A payment came in")
        XCTAssertTrue(one.message.hasPrefix("1 payment had already gone through and was recorded. 1 open pay link was expired."))
        XCTAssertTrue(one.message.contains("Your change was not saved."))

        let two = OpenCheckoutRefusal.releaseSummary(OpenPaymentsRelease(succeeded: 2, inProgress: 2))
        XCTAssertEqual(two.title, "Payments came in")
        XCTAssertTrue(two.message.contains("2 payments had already gone through and were recorded."))
        XCTAssertTrue(two.message.contains("2 payments are still being processed by the bank"))

        let processing = OpenCheckoutRefusal.releaseSummary(OpenPaymentsRelease(inProgress: 1))
        XCTAssertEqual(processing.title, "A payment is still processing")
        XCTAssertTrue(processing.message.hasPrefix("1 payment is still being processed by the bank and can't be cancelled"))
        XCTAssertTrue(processing.message.hasSuffix("make the change again if it's still right."))
    }
}
