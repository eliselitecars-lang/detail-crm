import XCTest
@testable import DetailCore

/// Week totals cut each entry at the week edges, like the web timesheet
/// (`summarize`) and `report_team` (`greatest(clock_in, from)` ..
/// `least(coalesce(clock_out, now), to)`).
final class TimeTotalsTests: XCTestCase {

    let chicago = ShopClock(timeZoneIdentifier: "America/Chicago", locale: Locale(identifier: "en_US_POSIX"))

    private func utc(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else {
            XCTFail("bad fixture \(iso)")
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    /// Now = Wed 2026-09-23 10:00 Chicago (CDT, UTC−5).
    private var now: Date { utc("2026-09-23T15:00:00Z") }
    private var thisWeek: DateInterval { chicago.totalsWeekInterval(containing: now) }
    private var lastWeek: DateInterval {
        chicago.totalsWeekInterval(containing: chicago.addingDays(-7, to: thisWeek.start))
    }

    func testWeeksUnderTest() {
        XCTAssertEqual(chicago.dateString(thisWeek.start), "2026-09-21")
        XCTAssertEqual(chicago.dateString(lastWeek.start), "2026-09-14")
        XCTAssertEqual(lastWeek.end, thisWeek.start)
    }

    func testShiftAcrossSundayMondayIsSplitBetweenWeeks() {
        // Sun 09-20 20:00 -> Mon 09-21 04:00 local.
        let clockIn = utc("2026-09-21T01:00:00Z")
        let clockOut = utc("2026-09-21T09:00:00Z")
        XCTAssertEqual(TimeTotals.secondsWithin(clockIn: clockIn, clockOut: clockOut, range: thisWeek, now: now), 4 * 3600)
        XCTAssertEqual(TimeTotals.secondsWithin(clockIn: clockIn, clockOut: clockOut, range: lastWeek, now: now), 4 * 3600)
        XCTAssertTrue(TimeTotals.overlaps(clockIn: clockIn, clockOut: clockOut, range: thisWeek))
        XCTAssertTrue(TimeTotals.overlaps(clockIn: clockIn, clockOut: clockOut, range: lastWeek))
    }

    func testOpenShiftFromEarlierWeekCountsOnlyThisWeeksPart() {
        // Opened Fri 09-18 08:00 local, never closed; now is Wed 10:00.
        let clockIn = utc("2026-09-18T13:00:00Z")
        XCTAssertEqual(TimeTotals.secondsWithin(clockIn: clockIn, clockOut: nil, range: thisWeek, now: now), 58 * 3600)
        // Last week stops at its own end instead of growing with this week's time.
        XCTAssertEqual(TimeTotals.secondsWithin(clockIn: clockIn, clockOut: nil, range: lastWeek, now: now), 64 * 3600)
        XCTAssertTrue(TimeTotals.overlaps(clockIn: clockIn, clockOut: nil, range: thisWeek))
        XCTAssertTrue(TimeTotals.overlaps(clockIn: clockIn, clockOut: nil, range: lastWeek))
    }

    func testEntriesOutsideTheRangeCountZero() {
        let nextWeek = chicago.totalsWeekInterval(containing: thisWeek.end)
        // Ends exactly at the week start: touches, does not overlap.
        let clockIn = utc("2026-09-21T01:00:00Z")
        let atStart = thisWeek.start
        XCTAssertEqual(TimeTotals.secondsWithin(clockIn: clockIn, clockOut: atStart, range: thisWeek, now: now), 0)
        XCTAssertFalse(TimeTotals.overlaps(clockIn: clockIn, clockOut: atStart, range: thisWeek))
        // Starts at the range end: belongs to the next week only.
        XCTAssertFalse(TimeTotals.overlaps(clockIn: thisWeek.end, clockOut: nil, range: thisWeek))
        // An open entry in a future week is not counted before it starts.
        XCTAssertEqual(TimeTotals.secondsWithin(clockIn: now, clockOut: nil, range: nextWeek, now: now), 0)
    }

    func testEntryInsideTheWeekCountsInFullAndOpenRunsToNow() {
        let clockIn = utc("2026-09-22T13:00:00Z")
        let clockOut = utc("2026-09-22T21:30:00Z")
        XCTAssertEqual(TimeTotals.secondsWithin(clockIn: clockIn, clockOut: clockOut, range: thisWeek, now: now), 8 * 3600 + 1800)
        XCTAssertEqual(TimeTotals.secondsWithin(clockIn: utc("2026-09-23T13:00:00Z"), clockOut: nil, range: thisWeek, now: now), 2 * 3600)
        // A clock skew (entry "starts" after now) never goes negative.
        XCTAssertEqual(TimeTotals.secondsWithin(clockIn: utc("2026-09-23T16:00:00Z"), clockOut: nil, range: thisWeek, now: now), 0)
    }
}
