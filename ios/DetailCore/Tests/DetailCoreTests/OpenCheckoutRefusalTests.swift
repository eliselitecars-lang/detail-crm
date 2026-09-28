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
}
