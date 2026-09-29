import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import DetailCore

final class SignedImageLoadTests: XCTestCase {

    private let listURL = URL(string: "https://example.test/sign/a.jpg?token=old")!
    private let freshURL = URL(string: "https://example.test/sign/a.jpg?token=new")!

    /// A photo whose link couldn't be signed when the list loaded (url nil)
    /// signs its own link instead of staying in "loading" forever.
    func testNilLinkIsSignedByTheLoader() {
        var load = SignedImageLoad(initialURL: nil)
        XCTAssertEqual(load.work, SignedImageLoad.Work(attempt: 0, url: nil))
        load.signed(freshURL, attempt: 0)
        XCTAssertEqual(load.work, SignedImageLoad.Work(attempt: 0, url: freshURL))
        load.imageLoaded(attempt: 0)
        XCTAssertEqual(load.state, .loaded)
        XCTAssertNil(load.work)
    }

    /// Signing fails (offline, file gone): a visible failure, not a spinner;
    /// Retry signs again.
    func testSigningFailureIsShownAndRetried() {
        var load = SignedImageLoad(initialURL: nil)
        load.signingFailed(attempt: 0)
        XCTAssertEqual(load.state, .failed(.noLink))
        XCTAssertTrue(load.isFailed)
        XCTAssertNil(load.work)

        load.retry()
        XCTAssertEqual(load.work, SignedImageLoad.Work(attempt: 1, url: nil))
        load.signed(freshURL, attempt: 1)
        load.imageLoaded(attempt: 1)
        XCTAssertEqual(load.state, .loaded)
    }

    /// The hour-long link from the list expired on a job page left open:
    /// the first failure gets one fresh link automatically.
    func testExpiredListLinkIsReSignedOnce() {
        var load = SignedImageLoad(initialURL: listURL)
        XCTAssertEqual(load.work, SignedImageLoad.Work(attempt: 0, url: listURL))
        load.imageFailed(attempt: 0)
        XCTAssertEqual(load.work, SignedImageLoad.Work(attempt: 1, url: nil))
        load.signed(freshURL, attempt: 1)
        load.imageLoaded(attempt: 1)
        XCTAssertEqual(load.state, .loaded)
    }

    /// A link the loader signed itself that still fails: shown as a
    /// failure with Retry (no endless re-signing).
    func testFreshLinkFailureIsShown() {
        var load = SignedImageLoad(initialURL: listURL)
        load.imageFailed(attempt: 0)
        load.signed(freshURL, attempt: 1)
        load.imageFailed(attempt: 1)
        XCTAssertEqual(load.state, .failed(.imageUnavailable))
        XCTAssertNil(load.work)
    }

    /// Answers from an older try are ignored.
    func testStaleResultsAreIgnored() {
        var load = SignedImageLoad(initialURL: nil)
        load.retry() // attempt 1
        load.signed(listURL, attempt: 0)
        XCTAssertEqual(load.work, SignedImageLoad.Work(attempt: 1, url: nil))
        load.signingFailed(attempt: 0)
        XCTAssertFalse(load.isFailed)
        load.signed(freshURL, attempt: 1)
        load.imageFailed(attempt: 0)
        XCTAssertEqual(load.work, SignedImageLoad.Work(attempt: 1, url: freshURL))
    }

    /// Pull to refresh hands in new links: a failed or pending image takes
    /// the new one, an image already on screen stays.
    func testAdoptingANewLink() {
        var failed = SignedImageLoad(initialURL: nil)
        failed.signingFailed(attempt: 0)
        failed.adopt(freshURL)
        XCTAssertEqual(failed.work, SignedImageLoad.Work(attempt: 1, url: freshURL))

        var shown = SignedImageLoad(initialURL: listURL)
        shown.imageLoaded(attempt: 0)
        shown.adopt(freshURL)
        XCTAssertEqual(shown.state, .loaded)

        var same = SignedImageLoad(initialURL: listURL)
        same.adopt(listURL)
        XCTAssertEqual(same.attempt, 0)
        same.adopt(nil)
        XCTAssertEqual(same.attempt, 0)
    }

    func testMessages() {
        XCTAssertEqual(
            SignedImageLoad.message(for: .noLink, noun: "photo"),
            "This photo couldn't be opened. Check your connection and try again."
        )
        XCTAssertEqual(
            SignedImageLoad.message(for: .imageUnavailable, noun: "signature"),
            "This signature couldn't be loaded. Try again, or pull to refresh the job."
        )
    }

    // MARK: ZoomGeometry

    func testFittedSizeKeepsTheAspectRatio() {
        let wide = ZoomGeometry.fittedSize(image: CGSize(width: 2048, height: 1536), in: CGSize(width: 390, height: 700))
        XCTAssertEqual(wide.width, 390, accuracy: 0.001)
        XCTAssertEqual(wide.height, 292.5, accuracy: 0.001)
        let tall = ZoomGeometry.fittedSize(image: CGSize(width: 1000, height: 4000), in: CGSize(width: 390, height: 700))
        XCTAssertEqual(tall.height, 700, accuracy: 0.001)
        XCTAssertEqual(tall.width, 175, accuracy: 0.001)
        XCTAssertEqual(ZoomGeometry.fittedSize(image: .zero, in: CGSize(width: 10, height: 10)), .zero)
    }

    func testCenteringInsets() {
        let insets = ZoomGeometry.centeringInsets(content: CGSize(width: 390, height: 292.5), in: CGSize(width: 390, height: 700))
        XCTAssertEqual(insets.horizontal, 0, accuracy: 0.001)
        XCTAssertEqual(insets.vertical, 203.75, accuracy: 0.001)
        let zoomed = ZoomGeometry.centeringInsets(content: CGSize(width: 975, height: 731.25), in: CGSize(width: 390, height: 700))
        XCTAssertEqual(zoomed.horizontal, 0)
        XCTAssertEqual(zoomed.vertical, 0)
    }

    /// Double-tapping near a panel edge zooms there (not the centre), and
    /// the zoom rectangle stays inside the photo.
    func testZoomRectCentresOnTheTapAndStaysInside() {
        let content = CGSize(width: 390, height: 292.5)
        let view = CGSize(width: 390, height: 700)
        let rect = ZoomGeometry.zoomRect(around: CGPoint(x: 300, y: 100), scale: 2.5, viewSize: view, content: content)
        XCTAssertEqual(rect.width, 156, accuracy: 0.001)
        XCTAssertEqual(rect.midX, 300, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxY, content.height + 0.001)

        let corner = ZoomGeometry.zoomRect(around: CGPoint(x: 389, y: 291), scale: 2.5, viewSize: view, content: content)
        XCTAssertEqual(corner.maxX, content.width, accuracy: 0.001)
        XCTAssertLessThanOrEqual(corner.maxY, content.height + 0.001)
        XCTAssertGreaterThanOrEqual(corner.minX, 0)
    }
}
