import XCTest
@testable import DetailCore

/// The job page's Time section (web TimeCard parity): totals, who is on
/// the clock, and the clock action the signed-in member gets.
final class JobTimeTests: XCTestCase {

    private let job = UUID()
    private let otherJob = UUID()
    private let ana = UUID()
    private let ben = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ member: UUID, startedMinutesAgo: Int, lengthMinutes: Int?) -> JobTime.Entry {
        let clockIn = now.addingTimeInterval(TimeInterval(-startedMinutesAgo * 60))
        return JobTime.Entry(
            id: UUID(),
            memberID: member,
            clockIn: clockIn,
            clockOut: lengthMinutes.map { clockIn.addingTimeInterval(TimeInterval($0 * 60)) }
        )
    }

    func testTotalsCountClosedEntriesAndOpenOnesUntilNow() {
        let entries = [
            entry(ana, startedMinutesAgo: 300, lengthMinutes: 90),   // closed, 1h30
            entry(ben, startedMinutesAgo: 200, lengthMinutes: 45),   // closed, 45m
            entry(ana, startedMinutesAgo: 30, lengthMinutes: nil),   // open, 30m so far
        ]
        let summary = JobTime.summary(of: entries, now: now)
        XCTAssertEqual(summary.totalSeconds, (90 + 45 + 30) * 60)
        XCTAssertEqual(summary.closedSeconds, (90 + 45) * 60)
        XCTAssertEqual(summary.entryCount, 3)
        XCTAssertEqual(summary.openMemberIDs, [ana])
        XCTAssertTrue(summary.hasOpenEntries)
        XCTAssertFalse(summary.isEmpty)
    }

    func testOpenMembersAreListedOnceInClockInOrder() {
        let entries = [
            entry(ana, startedMinutesAgo: 10, lengthMinutes: nil),
            entry(ben, startedMinutesAgo: 50, lengthMinutes: nil),
            entry(ana, startedMinutesAgo: 20, lengthMinutes: nil),   // a repeat from a second read
        ]
        XCTAssertEqual(JobTime.summary(of: entries, now: now).openMemberIDs, [ben, ana])
    }

    func testNoEntriesIsEmptyWithNobodyOnTheClock() {
        let summary = JobTime.summary(of: [], now: now)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertFalse(summary.hasOpenEntries)
        XCTAssertEqual(summary.totalSeconds, 0)
    }

    func testAnEntryStampedAfterNowNeverCountsNegative() {
        // Device clock behind the server's: the open entry starts "in the future".
        let ahead = JobTime.Entry(id: UUID(), memberID: ana, clockIn: now.addingTimeInterval(120), clockOut: nil)
        XCTAssertEqual(ahead.seconds(now: now), 0)
        XCTAssertEqual(JobTime.summary(of: [ahead], now: now).totalSeconds, 0)
    }

    func testOrderedIsNewestFirst() {
        let old = entry(ana, startedMinutesAgo: 300, lengthMinutes: 10)
        let recent = entry(ben, startedMinutesAgo: 5, lengthMinutes: nil)
        XCTAssertEqual(JobTime.ordered([old, recent]).map(\.id), [recent.id, old.id])
    }

    func testActionForAnAssignedMember() {
        XCTAssertEqual(JobTime.action(jobID: job, jobStatus: .inProgress, isAssigned: true, openJobTimerJobID: nil), .clockIn)
        XCTAssertEqual(JobTime.action(jobID: job, jobStatus: .scheduled, isAssigned: true, openJobTimerJobID: job), .clockOut)
        XCTAssertEqual(
            JobTime.action(jobID: job, jobStatus: .inProgress, isAssigned: true, openJobTimerJobID: otherJob),
            .clockedInElsewhere
        )
    }

    func testClosedJobsOfferNoClockInButStillLetATimerStop() {
        for status in [JobStatus.completed, .cancelled, .noShow] {
            XCTAssertEqual(JobTime.action(jobID: job, jobStatus: status, isAssigned: true, openJobTimerJobID: nil), .none)
            XCTAssertEqual(JobTime.action(jobID: job, jobStatus: status, isAssigned: true, openJobTimerJobID: job), .clockOut)
        }
    }

    func testUnassignedMembersGetNoAction() {
        XCTAssertEqual(JobTime.action(jobID: job, jobStatus: .inProgress, isAssigned: false, openJobTimerJobID: nil), .none)
        XCTAssertEqual(JobTime.action(jobID: job, jobStatus: .inProgress, isAssigned: false, openJobTimerJobID: job), .none)
    }

    func testSectionIsHiddenOnClosedJobsWithoutTime() {
        XCTAssertTrue(JobTime.showsSection(jobStatus: .confirmed, entryCount: 0))
        XCTAssertTrue(JobTime.showsSection(jobStatus: .completed, entryCount: 2))
        XCTAssertFalse(JobTime.showsSection(jobStatus: .completed, entryCount: 0))
        XCTAssertFalse(JobTime.showsSection(jobStatus: .cancelled, entryCount: 0))
        XCTAssertFalse(JobTime.showsSection(jobStatus: .noShow, entryCount: 0))
    }
}
