import Foundation

/// Hours math for time-clock totals, matching the web timesheet
/// (`summarize` / `splitByShopDay`) and the server's `report_team`: an
/// entry counts only for the part of it that falls inside the range
/// (`greatest(clock_in, from)` .. `least(coalesce(clock_out, now), to)`),
/// and an open entry runs until `now`.
public enum TimeTotals {

    /// Seconds of the entry `[clockIn, clockOut ?? now)` that fall inside
    /// the half-open `range`. An entry that started before the range (a
    /// shift across the week edge, or one left open) counts only from the
    /// range start; one that runs past the range end stops there.
    public static func secondsWithin(
        clockIn: Date,
        clockOut: Date?,
        range: DateInterval,
        now: Date
    ) -> Int {
        let end = clockOut ?? max(now, clockIn)
        let from = max(clockIn, range.start)
        let to = min(end, range.end)
        guard to > from else { return 0 }
        return Int(to.timeIntervalSince(from))
    }

    /// Whether the entry overlaps `range` at all (the rows a week's
    /// timesheet lists): it starts before the range ends, and it is still
    /// open or ends after the range starts.
    public static func overlaps(clockIn: Date, clockOut: Date?, range: DateInterval) -> Bool {
        guard clockIn < range.end else { return false }
        guard let clockOut else { return true }
        return clockOut > range.start
    }
}
