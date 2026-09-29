import Foundation

/// Calendar math in the *shop's* time zone (SPEC: all dates display and
/// bucket in the shop timezone, not the phone's). Handles DST correctly by
/// always going through `Calendar` instead of adding fixed 86 400-second
/// days.
public struct ShopClock: Sendable {
    public let timeZone: TimeZone
    public let locale: Locale
    /// 1 = Sunday … 7 = Saturday (Gregorian `Calendar.firstWeekday`).
    public let firstWeekday: Int

    public init(timeZone: TimeZone, locale: Locale = .current, firstWeekday: Int = 1) {
        self.timeZone = timeZone
        self.locale = locale
        self.firstWeekday = min(max(firstWeekday, 1), 7)
    }

    /// Builds a clock from an IANA identifier; falls back to the device zone
    /// if the identifier is unknown.
    public init(timeZoneIdentifier: String, locale: Locale = .current, firstWeekday: Int = 1) {
        self.init(
            timeZone: TimeZone(identifier: timeZoneIdentifier) ?? .current,
            locale: locale,
            firstWeekday: firstWeekday
        )
    }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    // MARK: - Days

    /// Midnight (shop time) starting the day that contains `date`.
    public func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    /// The whole shop-local day containing `date` (23 or 25 hours on DST
    /// change days).
    public func dayInterval(containing date: Date) -> DateInterval {
        let start = startOfDay(date)
        let end = addingDays(1, to: start)
        return DateInterval(start: start, end: end)
    }

    /// Adds calendar days in shop time, keeping wall-clock time where it
    /// exists.
    public func addingDays(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    /// Shop-local midnights for each day in `[start, end)` (by day).
    public func days(from start: Date, to end: Date) -> [Date] {
        var result: [Date] = []
        var cursor = startOfDay(start)
        while cursor < end {
            result.append(cursor)
            cursor = addingDays(1, to: cursor)
        }
        return result
    }

    public func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        startOfDay(lhs) == startOfDay(rhs)
    }

    /// 0 = Sunday … 6 = Saturday, matching `business_hours.weekday`.
    public func weekdayIndex(_ date: Date) -> Int {
        calendar.component(.weekday, from: date) - 1
    }

    // MARK: - Weeks & months

    /// `Calendar.firstWeekday` value for Monday: the start of a totals week.
    public static let totalsFirstWeekday = 2

    /// Weekday numbers as `business_hours.weekday` stores them (0 = Sunday
    /// … 6 = Saturday), in display order starting at `firstWeekday`
    /// (`Calendar` numbering: 1 = Sunday, 2 = Monday; out-of-range values
    /// are clamped).
    public static func orderedWeekdayNumbers(firstWeekday: Int) -> [Int] {
        let start = max(0, min(6, firstWeekday - 1))
        return (0..<7).map { ($0 + start) % 7 }
    }

    /// The business-hours editor's order: Monday first, like the web's
    /// BusinessHoursEditor ("Show Monday first"), whatever week the
    /// calendar grid starts on.
    public static let businessHoursWeekdays = orderedWeekdayNumbers(firstWeekday: totalsFirstWeekday)

    /// The shop-local week containing `date`, starting on `firstWeekday`.
    /// This is a *display* week (the calendar's week grid). For money and
    /// hours totals use `totalsWeekInterval(containing:)`.
    public func weekInterval(containing date: Date) -> DateInterval {
        weekInterval(containing: date, startingOn: firstWeekday)
    }

    /// The Monday-to-Sunday shop-local week containing `date`: the week every
    /// "This week" total uses, whatever `firstWeekday` is. It matches the
    /// server's `date_trunc('week', …)` (ISO weeks start on Monday) in
    /// `dashboard_summary` and the weekly `report_*` buckets, and the web
    /// app's report presets and timesheets, so the same preset shows the
    /// same figures everywhere.
    public func totalsWeekInterval(containing date: Date) -> DateInterval {
        weekInterval(containing: date, startingOn: Self.totalsFirstWeekday)
    }

    private func weekInterval(containing date: Date, startingOn first: Int) -> DateInterval {
        let dayStart = startOfDay(date)
        let weekday = calendar.component(.weekday, from: dayStart)
        let offset = (weekday - first + 7) % 7
        let start = addingDays(-offset, to: dayStart)
        let end = addingDays(7, to: start)
        return DateInterval(start: start, end: end)
    }

    /// The shop-local calendar month containing `date`.
    public func monthInterval(containing date: Date) -> DateInterval {
        let components = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: components) ?? startOfDay(date)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? addingDays(31, to: start)
        return DateInterval(start: start, end: end)
    }

    // MARK: - Postgres `date` / `time` values

    /// `yyyy-MM-dd` for the shop-local day containing `date` (for `date`
    /// RPC parameters such as `from_date`).
    public func dateString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Shop-local midnight for a `yyyy-MM-dd` string.
    public func date(fromDateString string: String) -> Date? {
        let parts = string.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        // Reject overflowed dates such as 2026-02-30.
        guard calendar.component(.day, from: date) == day else { return nil }
        return startOfDay(date)
    }

    /// Combines a shop-local day with a Postgres `time` string (`HH:mm` or
    /// `HH:mm:ss`). A wall time inside a spring-forward gap (02:30 on the
    /// March change day in the US) is read as standard time and so lands one
    /// hour later on the wall clock (03:30 CDT) — the same instant Postgres
    /// produces for `timestamp AT TIME ZONE zone`. A wall time that occurs
    /// twice (01:30 on the November change day) resolves to the later,
    /// standard-time instant, also matching Postgres.
    public func date(on day: Date, timeString: String) -> Date? {
        let parts = timeString.split(separator: ":")
        guard parts.count >= 2, parts.count <= 3,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...24).contains(hour), (0...59).contains(minute) else { return nil }
        let second = parts.count == 3 ? Int(Double(parts[2]) ?? -1) : 0
        guard (0...59).contains(second) else { return nil }
        let midnight = startOfDay(day)
        if hour == 24 {
            guard minute == 0, second == 0 else { return nil }
            return addingDays(1, to: midnight)
        }
        var components = calendar.dateComponents([.year, .month, .day], from: midnight)
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let candidate = calendar.date(from: components) else { return nil }
        // A wall time that occurs twice (fall-back hour) resolves to the
        // later, standard-time instant — what Postgres does.
        let dstOffset = timeZone.daylightSavingTimeOffset(for: candidate)
        if dstOffset > 0 {
            let later = candidate.addingTimeInterval(dstOffset)
            let wanted: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
            if calendar.dateComponents(wanted, from: later) == calendar.dateComponents(wanted, from: candidate) {
                return later
            }
        }
        return candidate
    }

    /// Minutes since shop-local midnight (wall clock), e.g. 9:30 -> 570.
    public func minutesSinceMidnight(_ date: Date) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    // MARK: - Display formatting

    /// "9:30 AM" (locale-aware, shop zone).
    public func timeText(_ date: Date) -> String {
        formatter(template: "jmm").string(from: date)
    }

    /// "Tue, Mar 10" style (locale-aware, shop zone).
    public func shortDayText(_ date: Date) -> String {
        formatter(template: "EEEMMMd").string(from: date)
    }

    /// "Tuesday, March 10, 2026" style.
    public func longDayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// "Mar 10, 9:30 AM" style.
    public func dateTimeText(_ date: Date) -> String {
        formatter(template: "MMMdjmm").string(from: date)
    }

    /// "9:30 – 11:00 AM" style range (same day) or full endpoints.
    public func rangeText(from start: Date, to end: Date) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        if isSameDay(start, end) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        }
        return formatter.string(from: start, to: end)
    }

    /// "Today", "Tomorrow", "Yesterday", else the short day text.
    public func relativeDayText(_ date: Date, now: Date = Date()) -> String {
        let today = startOfDay(now)
        let day = startOfDay(date)
        if day == today { return "Today" }
        if day == addingDays(1, to: today) { return "Tomorrow" }
        if day == addingDays(-1, to: today) { return "Yesterday" }
        return shortDayText(date)
    }

    /// "1h 30m" / "45m" from a number of minutes.
    public static func durationText(minutes: Int) -> String {
        let clamped = max(0, minutes)
        let hours = clamped / 60
        let mins = clamped % 60
        if hours == 0 { return "\(mins)m" }
        if mins == 0 { return "\(hours)h" }
        return "\(hours)h \(mins)m"
    }

    private func formatter(template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
