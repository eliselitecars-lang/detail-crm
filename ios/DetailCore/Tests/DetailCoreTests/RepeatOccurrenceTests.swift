import XCTest
@testable import DetailCore

final class RepeatOccurrenceTests: XCTestCase {

    func testLocalDateArithmetic() {
        XCTAssertEqual(LocalDate.adding(-1, to: "2026-03-01"), "2026-02-28")
        XCTAssertEqual(LocalDate.adding(1, to: "2028-02-28"), "2028-02-29")
        XCTAssertEqual(LocalDate.adding(7, to: "2026-12-28"), "2027-01-04")
        XCTAssertNil(LocalDate.adding(1, to: "2026-02-30"))
        XCTAssertNil(LocalDate.adding(1, to: "26-1-1"))
        XCTAssertEqual(LocalDate.days(from: "2026-10-05", to: "2026-09-07"), -28)
        XCTAssertEqual(LocalDate.days(from: "2026-03-07", to: "2026-03-09"), 2)
        XCTAssertNil(LocalDate.days(from: "x", to: "2026-03-09"))
    }

    /// A weekly Monday time off, opened on a later Monday.
    func testLaterOccurrenceOffersEveryScope() {
        let occ = RepeatOccurrence(seriesDate: "2026-09-07", occurrenceDate: "2026-10-05", skipped: ["2026-09-21"])
        XCTAssertFalse(occ.isFirst)
        XCTAssertTrue(occ.canChangeFollowing)
        XCTAssertNil(occ.followingChangeLimit)
        XCTAssertEqual(occ.changeScopes, [.this, .all, .following])
        XCTAssertEqual(occ.deleteScopes, [.this, .following, .all])
        XCTAssertFalse(occ.onlyThisDeletesEvent)
        // only this one: its date is added to the skipped dates, sorted
        XCTAssertEqual(occ.skippingThis, ["2026-09-21", "2026-10-05"])
        // this and later: the series ends the day before, keeping earlier skips
        XCTAssertEqual(occ.dayBefore, "2026-10-04")
        XCTAssertEqual(occ.skippedBefore, ["2026-09-21"])
        // every occurrence: the edited times move back to the series' start
        XCTAssertEqual(occ.daysToSeriesStart, -28)
    }

    func testSkippingIsIdempotent() {
        let occ = RepeatOccurrence(seriesDate: "2026-09-07", occurrenceDate: "2026-09-14", skipped: ["2026-09-14"])
        XCTAssertEqual(occ.skippingThis, ["2026-09-14"])
    }

    func testFirstOccurrenceHasNoFollowingScope() {
        let occ = RepeatOccurrence(seriesDate: "2026-09-07", occurrenceDate: "2026-09-07")
        XCTAssertTrue(occ.isFirst)
        XCTAssertFalse(occ.canChangeFollowing)
        XCTAssertNil(occ.followingChangeLimit)
        XCTAssertEqual(occ.changeScopes, [.this, .all])
        XCTAssertEqual(occ.deleteScopes, [.this, .all])
        XCTAssertEqual(occ.daysToSeriesStart, 0)
    }

    func testCountRulesCannotSplitAChange() {
        let occ = RepeatOccurrence(seriesDate: "2026-09-07", occurrenceDate: "2026-09-21", count: 10)
        XCTAssertFalse(occ.canChangeFollowing)
        XCTAssertNotNil(occ.followingChangeLimit)
        XCTAssertEqual(occ.changeScopes, [.this, .all])
        // deleting from here on is still allowed (the count becomes a date)
        XCTAssertEqual(occ.deleteScopes, [.this, .following, .all])
    }

    func testARuleThatRunsOnceIsDeletedWhole() {
        let occ = RepeatOccurrence(seriesDate: "2026-09-07", occurrenceDate: "2026-09-07", count: 1)
        XCTAssertTrue(occ.onlyThisDeletesEvent)
    }

    func testFollowingSeriesKeepsLaterSkipsMovedWithIt() {
        let occ = RepeatOccurrence(
            seriesDate: "2026-09-07", occurrenceDate: "2026-10-05",
            skipped: ["2026-09-21", "2026-10-05", "2026-10-19"]
        )
        // the new series starts a day later (Tuesday): its skips move too
        XCTAssertEqual(occ.skippedFromThis(movedBy: 1), ["2026-10-06", "2026-10-20"])
        XCTAssertEqual(occ.skippedFromThis(movedBy: 0), ["2026-10-05", "2026-10-19"])
    }

    func testSkippedSuffix() {
        XCTAssertEqual(RepeatOccurrence.skippedSuffix(0), "")
        XCTAssertEqual(RepeatOccurrence.skippedSuffix(1), " · 1 date skipped")
        XCTAssertEqual(RepeatOccurrence.skippedSuffix(3), " · 3 dates skipped")
    }
}
