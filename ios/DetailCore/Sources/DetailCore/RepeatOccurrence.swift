import Foundation

/// Which occurrences of a repeating calendar event a change or delete
/// applies to (P-17, 0115). The same three choices as the web's event
/// dialog.
public enum OccurrenceScope: String, CaseIterable, Hashable, Sendable {
    /// Only the opened occurrence: the series skips its date
    /// (`recurrence.except_dates`); a change becomes a one-off event.
    case this
    /// The opened occurrence and every later one: the series ends the day
    /// before; a change becomes a new series from here.
    case following
    /// The whole series.
    case all
}

/// The opened occurrence of a repeating calendar event
/// (`blocked_times.recurrence`), by shop-local `YYYY-MM-DD` dates, and the
/// rule edits each scope makes. Mirrors the web's EventDialog:
///
/// * "Only this one" adds the occurrence's date to `except_dates` (a
///   skipped occurrence still counts towards `count`, RFC 5545 EXDATE). A
///   rule that runs once is deleted instead.
/// * "This and later ones" ends the rule the day before (a `count` becomes
///   an `until_date`), keeping only the skipped dates before it. A change
///   that way is offered only after the first occurrence and not for
///   `count` rules (the new series could not know how many are left).
/// * "Every occurrence" moves the series by as many days as the opened
///   occurrence moved; the server keeps the skipped dates (shifted with the
///   start) when the key is omitted, and `[]` brings them all back.
public struct RepeatOccurrence: Hashable, Sendable {
    /// The series row's own start date (its first occurrence).
    public let seriesDate: String
    /// The start date of the occurrence that was opened.
    public let occurrenceDate: String
    /// The rule's `count`, when it ends after a number of times.
    public let count: Int?
    /// The rule's `except_dates`.
    public let skipped: [String]

    public init(seriesDate: String, occurrenceDate: String, count: Int? = nil, skipped: [String] = []) {
        self.seriesDate = seriesDate
        self.occurrenceDate = occurrenceDate
        self.count = count
        self.skipped = skipped
    }

    /// The opened occurrence is the series' first (or before it).
    public var isFirst: Bool { occurrenceDate <= seriesDate }

    /// "This and later ones" can carry a change.
    public var canChangeFollowing: Bool { !isFirst && count == nil }

    /// Why "This and later ones" is not offered for a change, when it isn't
    /// because of a `count` (the first occurrence needs no explanation:
    /// "Every occurrence" is the same thing).
    public var followingChangeLimit: String? {
        guard !isFirst, count != nil else { return nil }
        return "“This and later ones” isn't available for repeats that end after a number of times."
    }

    /// The change scopes to offer, in order.
    public var changeScopes: [OccurrenceScope] {
        canChangeFollowing ? [.this, .all, .following] : [.this, .all]
    }

    /// The delete scopes to offer, in order ("Only this one" first).
    public var deleteScopes: [OccurrenceScope] {
        isFirst ? [.this, .all] : [.this, .following, .all]
    }

    /// Deleting only this occurrence of a rule that runs once removes the
    /// event (there is nothing left to skip it in).
    public var onlyThisDeletesEvent: Bool { count == 1 }

    /// `except_dates` with the opened occurrence skipped: distinct, sorted.
    public var skippingThis: [String] {
        Array(Set(skipped + [occurrenceDate])).sorted()
    }

    /// The `until_date` that ends the series the day before the opened
    /// occurrence.
    public var dayBefore: String? { LocalDate.adding(-1, to: occurrenceDate) }

    /// The skipped dates the ended series still covers.
    public var skippedBefore: [String] {
        skipped.filter { $0 < occurrenceDate }.sorted()
    }

    /// The skipped dates from the opened occurrence on, moved by `days` —
    /// for the new series a "This and later ones" change starts.
    public func skippedFromThis(movedBy days: Int) -> [String] {
        Array(Set(skipped.filter { $0 >= occurrenceDate }.compactMap { LocalDate.adding(days, to: $0) })).sorted()
    }

    /// Days from the opened occurrence back to the series' start (zero or
    /// negative): applied to the edited times, it moves the series by as
    /// many days as the occurrence moved.
    public var daysToSeriesStart: Int {
        LocalDate.days(from: occurrenceDate, to: seriesDate) ?? 0
    }

    /// " · 2 dates skipped" for a rule summary, or "" when none are.
    public static func skippedSuffix(_ count: Int) -> String {
        guard count > 0 else { return "" }
        return count == 1 ? " · 1 date skipped" : " · \(count) dates skipped"
    }
}

/// Arithmetic on `YYYY-MM-DD` calendar dates (no time zone: whole days).
public enum LocalDate {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private static func parse(_ text: String) -> Date? {
        let parts = text.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day,
              calendar.component(.month, from: date) == month else { return nil }
        return date
    }

    private static func format(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `text` moved by `days` calendar days, or nil for an invalid date.
    public static func adding(_ days: Int, to text: String) -> String? {
        guard let date = parse(text), let moved = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return format(moved)
    }

    /// Whole days from `start` to `end` (negative when `end` is earlier).
    public static func days(from start: String, to end: String) -> Int? {
        guard let a = parse(start), let b = parse(end) else { return nil }
        return calendar.dateComponents([.day], from: a, to: b).day
    }
}
