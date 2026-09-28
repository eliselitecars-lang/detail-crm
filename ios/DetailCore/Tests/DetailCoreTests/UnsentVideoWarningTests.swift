import XCTest
@testable import DetailCore

final class UnsentVideoWarningTests: XCTestCase {

    func testNoUnsentVideosKeepsThePlainSignOut() {
        let prompt = UnsentVideoWarning.signOut(videoCount: 0, jobCount: 0)
        XCTAssertEqual(prompt, UnsentVideoWarning.plainSignOut)
        XCTAssertEqual(prompt.title, "Sign out?")
        XCTAssertEqual(prompt.confirmTitle, "Sign out")
        XCTAssertFalse(prompt.message.contains("video"))
    }

    func testOneUnsentVideoSaysItIsDeleted() {
        let prompt = UnsentVideoWarning.signOut(videoCount: 1, jobCount: 1)
        XCTAssertEqual(prompt.title, "Delete 1 unsent video?")
        XCTAssertEqual(prompt.confirmTitle, "Sign out and delete video")
        XCTAssertTrue(prompt.message.hasPrefix("1 job video hasn't finished uploading. "))
        XCTAssertTrue(prompt.message.contains("signing out deletes it for good"))
        XCTAssertTrue(prompt.message.contains("doesn't save to Photos"))
        XCTAssertTrue(prompt.message.contains("open that job"))
        XCTAssertTrue(prompt.message.contains("\"Save or share video\""))
    }

    func testSeveralVideosOnOneJob() {
        let prompt = UnsentVideoWarning.signOut(videoCount: 3, jobCount: 1)
        XCTAssertEqual(prompt.title, "Delete 3 unsent videos?")
        XCTAssertEqual(prompt.confirmTitle, "Sign out and delete videos")
        XCTAssertTrue(prompt.message.hasPrefix("3 job videos haven't finished uploading. "))
        XCTAssertTrue(prompt.message.contains("deletes them for good"))
        XCTAssertTrue(prompt.message.contains("open that job"))
    }

    func testSeveralVideosOnSeveralJobs() {
        let prompt = UnsentVideoWarning.signOut(videoCount: 3, jobCount: 2)
        XCTAssertTrue(prompt.message.hasPrefix("3 job videos haven't finished uploading on 2 jobs. "))
        XCTAssertTrue(prompt.message.contains("open each job"))
    }

    func testJobCountIsClampedToTheVideos() {
        // A stale or zero job count never reads as "on 0 jobs" or more jobs than videos.
        XCTAssertTrue(UnsentVideoWarning.signOut(videoCount: 2, jobCount: 0).message
            .hasPrefix("2 job videos haven't finished uploading. "))
        XCTAssertTrue(UnsentVideoWarning.signOut(videoCount: 2, jobCount: 5).message
            .hasPrefix("2 job videos haven't finished uploading on 2 jobs. "))
    }

    func testDiscardAsksAndSaysItIsPermanent() {
        let prompt = UnsentVideoWarning.discard
        XCTAssertEqual(prompt.title, "Discard this video?")
        XCTAssertEqual(prompt.confirmTitle, "Discard video")
        XCTAssertTrue(prompt.message.contains("deletes it for good"))
        XCTAssertTrue(prompt.message.contains("doesn't save"))
    }

    func testAccountDeletionNote() {
        XCTAssertNil(UnsentVideoWarning.accountDeletionNote(videoCount: 0))
        XCTAssertEqual(UnsentVideoWarning.accountDeletionNote(videoCount: 1),
                       "1 job video that hasn't finished uploading is deleted from this iPhone too.")
        XCTAssertEqual(UnsentVideoWarning.accountDeletionNote(videoCount: 2),
                       "2 job videos that haven't finished uploading are deleted from this iPhone too.")
    }
}
