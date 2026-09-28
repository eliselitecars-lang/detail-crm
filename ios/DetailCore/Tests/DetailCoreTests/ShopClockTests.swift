import XCTest
@testable import DetailCore

final class ShopClockTests: XCTestCase {

    let chicago = ShopClock(timeZoneIdentifier: "America/Chicago", locale: Locale(identifier: "en_US_POSIX"))

    /// Builds an instant from a UTC ISO-8601 string.
    private func utc(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else {
            XCTFail("bad fixture \(iso)")
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    func testStartOfDayUsesShopZoneNotDevice() {
        // 2026-07-10 03:30 UTC is still July 9 in Chicago (CDT, UTC−5).
        let instant = utc("2026-07-10T03:30:00Z")
        XCTAssertEqual(chicago.startOfDay(instant), utc("2026-07-09T05:00:00Z"))
        XCTAssertEqual(chicago.dateString(instant), "2026-07-09")
    }

    func testSpringForwardDayIs23Hours() {
        // DST starts Sunday 2026-03-08 at 02:00 CST.
        let day = chicago.dayInterval(containing: utc("2026-03-08T18:00:00Z"))
        XCTAssertEqual(day.start, utc("2026-03-08T06:00:00Z"))   // midnight CST
        XCTAssertEqual(day.end, utc("2026-03-09T05:00:00Z"))     // midnight CDT
        XCTAssertEqual(day.duration, 23 * 3600)
    }

    func testFallBackDayIs25Hours() {
        // DST ends Sunday 2026-11-01 at 02:00 CDT.
        let day = chicago.dayInterval(containing: utc("2026-11-01T18:00:00Z"))
        XCTAssertEqual(day.start, utc("2026-11-01T05:00:00Z"))
        XCTAssertEqual(day.end, utc("2026-11-02T06:00:00Z"))
        XCTAssertEqual(day.duration, 25 * 3600)
    }

    func testAddingDaysKeepsWallClockAcrossDST() {
        // 9:00 CST Saturday -> 9:00 CDT Sunday (23h later, not 24h).
        let saturday9 = utc("2026-03-07T15:00:00Z")
        let sunday9 = chicago.addingDays(1, to: saturday9)
        XCTAssertEqual(sunday9, utc("2026-03-08T14:00:00Z"))
        // ICU may use a narrow no-break space before AM/PM.
        let text = chicago.timeText(sunday9).replacingOccurrences(of: "\u{202F}", with: " ")
        XCTAssertEqual(text, "9:00 AM")
    }

    func testBusinessHoursTimeOnDSTDays() {
        let spring = chicago.date(fromDateString: "2026-03-08")!
        XCTAssertEqual(chicago.date(on: spring, timeString: "09:00"), utc("2026-03-08T14:00:00Z"))
        XCTAssertEqual(chicago.date(on: spring, timeString: "17:30:00"), utc("2026-03-08T22:30:00Z"))
        XCTAssertEqual(chicago.date(on: spring, timeString: "24:00"), utc("2026-03-09T05:00:00Z"))
        // 02:30 does not exist that day; it is read as standard time (08:30Z).
        XCTAssertEqual(chicago.date(on: spring, timeString: "02:30"), utc("2026-03-08T08:30:00Z"))

        let fall = chicago.date(fromDateString: "2026-11-01")!
        XCTAssertEqual(chicago.date(on: fall, timeString: "09:00"), utc("2026-11-01T15:00:00Z"))
        // 01:30 happens twice; Postgres reads it as standard time (07:30Z).
        XCTAssertEqual(chicago.date(on: fall, timeString: "01:30"), utc("2026-11-01T07:30:00Z"))
        XCTAssertEqual(chicago.date(on: fall, timeString: "00:59"), utc("2026-11-01T05:59:00Z"))
        XCTAssertEqual(chicago.date(on: fall, timeString: "02:00"), utc("2026-11-01T08:00:00Z"))
        XCTAssertNil(chicago.date(on: fall, timeString: "25:00"))
        XCTAssertNil(chicago.date(on: fall, timeString: "9"))
        XCTAssertNil(chicago.date(on: fall, timeString: "09:60"))
    }

    func testDaysAcrossDSTBoundary() {
        let start = chicago.date(fromDateString: "2026-03-07")!
        let end = chicago.date(fromDateString: "2026-03-10")!
        let days = chicago.days(from: start, to: end)
        XCTAssertEqual(days.map { chicago.dateString($0) }, ["2026-03-07", "2026-03-08", "2026-03-09"])
    }

    func testWeekIntervalSundayStart() {
        // Wednesday 2026-03-11 -> week Sun 03-08 .. Sun 03-15 (contains DST start).
        let week = chicago.weekInterval(containing: utc("2026-03-11T17:00:00Z"))
        XCTAssertEqual(chicago.dateString(week.start), "2026-03-08")
        XCTAssertEqual(week.start, utc("2026-03-08T06:00:00Z"))
        XCTAssertEqual(week.end, utc("2026-03-15T05:00:00Z"))
        XCTAssertEqual(week.duration, 7 * 86_400 - 3_600)
    }

    func testWeekIntervalMondayStart() {
        let mondayClock = ShopClock(timeZoneIdentifier: "America/Chicago", locale: Locale(identifier: "en_US_POSIX"), firstWeekday: 2)
        let week = mondayClock.weekInterval(containing: utc("2026-03-08T17:00:00Z"))  // Sunday
        XCTAssertEqual(mondayClock.dateString(week.start), "2026-03-02")
        XCTAssertEqual(mondayClock.dateString(week.end), "2026-03-09")
    }

    func testTotalsWeekStartsMondayLikePostgresDateTruncWeek() {
        // Sunday 2026-09-27 (Chicago): Postgres `date_trunc('week', date
        // '2026-09-27')` is Monday 2026-09-21, so "This week" is 09-21..09-27
        // even though the default display week starts on Sunday.
        let sundayNoon = utc("2026-09-27T17:00:00Z")
        let totals = chicago.totalsWeekInterval(containing: sundayNoon)
        XCTAssertEqual(chicago.dateString(totals.start), "2026-09-21")
        XCTAssertEqual(chicago.dateString(chicago.addingDays(-1, to: totals.end)), "2026-09-27")
        XCTAssertEqual(totals.start, utc("2026-09-21T05:00:00Z"))
        XCTAssertEqual(chicago.dateString(chicago.weekInterval(containing: sundayNoon).start), "2026-09-27")

        // Monday itself starts its own week; late Sunday night shop time
        // (already Monday in UTC) still belongs to the previous week.
        XCTAssertEqual(chicago.dateString(chicago.totalsWeekInterval(containing: utc("2026-09-28T05:00:00Z")).start), "2026-09-28")
        XCTAssertEqual(chicago.dateString(chicago.totalsWeekInterval(containing: utc("2026-09-28T04:59:00Z")).start), "2026-09-21")
    }

    func testTotalsWeekIgnoresDisplayFirstWeekdayAndHandlesDST() {
        let saturdayClock = ShopClock(timeZoneIdentifier: "America/Chicago", locale: Locale(identifier: "en_US_POSIX"), firstWeekday: 7)
        // Week containing the fall-back Sunday 2026-11-01: Mon 10-26 .. Mon 11-02 (one 25 h day).
        let week = saturdayClock.totalsWeekInterval(containing: utc("2026-10-29T17:00:00Z"))
        XCTAssertEqual(saturdayClock.dateString(week.start), "2026-10-26")
        XCTAssertEqual(saturdayClock.dateString(week.end), "2026-11-02")
        XCTAssertEqual(week.duration, 7 * 86_400 + 3_600)
        XCTAssertEqual(ShopClock.totalsFirstWeekday, 2)
    }

    func testMonthInterval() {
        let month = chicago.monthInterval(containing: utc("2026-11-15T12:00:00Z"))
        XCTAssertEqual(month.start, utc("2026-11-01T05:00:00Z"))
        XCTAssertEqual(month.end, utc("2026-12-01T06:00:00Z"))
    }

    func testDateStringParsing() {
        XCTAssertEqual(chicago.date(fromDateString: "2026-01-15"), utc("2026-01-15T06:00:00Z"))
        XCTAssertNil(chicago.date(fromDateString: "2026-02-30"))
        XCTAssertNil(chicago.date(fromDateString: "2026-13-01"))
        XCTAssertNil(chicago.date(fromDateString: "20260115"))
    }

    func testWeekdayIndexMatchesBusinessHours() {
        // 2026-03-08 is a Sunday -> 0; 2026-03-14 Saturday -> 6.
        XCTAssertEqual(chicago.weekdayIndex(utc("2026-03-08T18:00:00Z")), 0)
        XCTAssertEqual(chicago.weekdayIndex(utc("2026-03-14T18:00:00Z")), 6)
    }

    func testMinutesSinceMidnight() {
        XCTAssertEqual(chicago.minutesSinceMidnight(utc("2026-07-09T14:30:00Z")), 9 * 60 + 30)
    }

    func testRelativeDayText() {
        let now = utc("2026-07-09T17:00:00Z")
        XCTAssertEqual(chicago.relativeDayText(utc("2026-07-09T23:00:00Z"), now: now), "Today")
        XCTAssertEqual(chicago.relativeDayText(utc("2026-07-10T15:00:00Z"), now: now), "Tomorrow")
        XCTAssertEqual(chicago.relativeDayText(utc("2026-07-08T15:00:00Z"), now: now), "Yesterday")
    }

    func testDurationText() {
        XCTAssertEqual(ShopClock.durationText(minutes: 45), "45m")
        XCTAssertEqual(ShopClock.durationText(minutes: 120), "2h")
        XCTAssertEqual(ShopClock.durationText(minutes: 90), "1h 30m")
        XCTAssertEqual(ShopClock.durationText(minutes: -5), "0m")
    }
}
