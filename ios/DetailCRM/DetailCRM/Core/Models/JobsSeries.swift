//
//  JobsSeries.swift
//  DetailCRM
//
//  Recurring appointments (P-1, `public.job_series`, sched 0050/0051). A
//  series is a rule (every N weeks on chosen weekdays, or every N months on
//  a day / an nth weekday) plus the defaults of every visit; each visit is
//  an ordinary job with `series_id` / `series_seq`. The server generates
//  and prices the visits (at least 90 days ahead, topped up daily) — the
//  app never computes dates itself: previews come from `job_series_preview`.
//
//  Editing: "this job only" is a plain job update (the server marks the
//  visit detached); "this and following" is `update_job_series`, which
//  replaces the later visits that are still plain scheduled, unpaid,
//  uninvoiced and not moved by hand (the others are kept and counted).
//  Managers and up only; technicians see the visits as jobs.
//

import Foundation
import Supabase

/// `job_series` row (managers+ may read it).
// table: job_series
struct JobsSeries: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var customerID: UUID
    var freq: String
    var interval: Int
    var byWeekday: [Int]
    var monthMode: String?
    var monthDay: Int?
    var monthNth: Int?
    var monthWeekday: Int?
    var startDate: String
    var localStart: String
    var durationMinutes: Int
    var untilDate: String?
    var maxOccurrences: Int?
    var active: Bool
    var generatedThrough: String?
    var endedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case customerID = "customer_id"
        case freq
        case interval
        case byWeekday = "by_weekday"
        case monthMode = "month_mode"
        case monthDay = "month_day"
        case monthNth = "month_nth"
        case monthWeekday = "month_weekday"
        case startDate = "start_date"
        case localStart = "local_start"
        case durationMinutes = "duration_minutes"
        case untilDate = "until_date"
        case maxOccurrences = "max_occurrences"
        case active
        case generatedThrough = "generated_through"
        case endedAt = "ended_at"
    }

    static let selectColumns = [
        "id", "shop_id", "customer_id", "freq", "interval", "by_weekday", "month_mode", "month_day",
        "month_nth", "month_weekday", "start_date", "local_start", "duration_minutes", "until_date",
        "max_occurrences", "active", "generated_through", "ended_at",
    ].joined(separator: ",")

    var rule: JobsSeriesDraft.Rule {
        JobsSeriesDraft.Rule(
            frequency: freq == "month" ? .month : .week,
            interval: interval,
            weekdays: Set(byWeekday),
            monthMode: monthMode == "nth_weekday" ? .nthWeekday : .dayOfMonth,
            monthDay: monthDay ?? 1,
            monthNth: monthNth ?? 1,
            monthWeekday: monthWeekday ?? 0
        )
    }

    /// "Every 2 weeks on Tue, Thu", "Monthly on day 15", "Every month on the last Friday".
    var summary: String { rule.summary }

    /// "until Mar 3, 2027", "12 visits", or nil when open-ended.
    var endSummary: String? {
        if let untilDate, let day = JobsSeriesDraft.dayFormatter.date(from: untilDate) {
            return "until " + day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: JobsSeriesDraft.utc))
        }
        if let maxOccurrences {
            return maxOccurrences == 1 ? "1 visit" : "\(maxOccurrences) visits"
        }
        return nil
    }
}

/// One upcoming visit from `job_series_preview`.
// rpc: job_series_preview
struct JobsSeriesOccurrence: Codable, Hashable, Sendable, Identifiable {
    var seq: Int
    var startsAt: Date
    var endsAt: Date

    enum CodingKeys: String, CodingKey {
        case seq
        case startsAt = "starts_at"
        case endsAt = "ends_at"
    }

    var id: Int { seq }
}

/// The `p_series` JSON for `create_job_series` / `job_series_preview`, and
/// the rule part of an `update_job_series` patch.
struct JobsSeriesDraft: Hashable, Sendable {

    enum Frequency: String, CaseIterable, Hashable, Sendable {
        case week
        case month

        var unitName: String { self == .week ? "week" : "month" }
    }

    enum MonthMode: String, CaseIterable, Hashable, Sendable {
        case dayOfMonth = "day_of_month"
        case nthWeekday = "nth_weekday"
    }

    enum End: Hashable, Sendable {
        case never
        /// Last possible visit day (shop-local).
        case onDate(Date)
        case afterCount(Int)
    }

    /// The repeat rule.
    struct Rule: Hashable, Sendable {
        var frequency: Frequency = .week
        /// Every N weeks / months (1…12).
        var interval: Int = 1
        /// 0 = Sunday … 6 = Saturday (weekly rules).
        var weekdays: Set<Int> = []
        var monthMode: MonthMode = .dayOfMonth
        /// 1…31; days past the month's end fall on its last day.
        var monthDay: Int = 1
        /// 1…5, or -1 for the last one.
        var monthNth: Int = 1
        var monthWeekday: Int = 0

        static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        static let weekdayLongNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

        static func ordinal(_ n: Int) -> String {
            switch n {
            case -1: return "last"
            case 1: return "first"
            case 2: return "second"
            case 3: return "third"
            case 4: return "fourth"
            case 5: return "fifth"
            default: return "\(n)th"
            }
        }

        var summary: String {
            let every = interval == 1 ? "Every \(frequency.unitName)" : "Every \(interval) \(frequency.unitName)s"
            switch frequency {
            case .week:
                let days = weekdays.sorted().map { Self.weekdayNames[max(0, min(6, $0))] }
                return days.isEmpty ? every : every + " on " + days.joined(separator: ", ")
            case .month:
                if monthMode == .nthWeekday {
                    return every + " on the \(Self.ordinal(monthNth)) \(Self.weekdayLongNames[max(0, min(6, monthWeekday))])"
                }
                return every + " on day \(monthDay)"
            }
        }

        /// Rule fields of the series JSON.
        var json: [String: AnyJSON] {
            var out: [String: AnyJSON] = [
                "freq": .string(frequency.rawValue),
                "interval": .integer(max(1, min(12, interval))),
            ]
            switch frequency {
            case .week:
                out["by_weekday"] = .array(weekdays.sorted().map { AnyJSON.integer($0) })
                out["month_mode"] = .null
                out["month_day"] = .null
                out["month_nth"] = .null
                out["month_weekday"] = .null
            case .month:
                out["by_weekday"] = .array([])
                out["month_mode"] = .string(monthMode.rawValue)
                if monthMode == .dayOfMonth {
                    out["month_day"] = .integer(max(1, min(31, monthDay)))
                    out["month_nth"] = .null
                    out["month_weekday"] = .null
                } else {
                    out["month_day"] = .null
                    out["month_nth"] = .integer(monthNth)
                    out["month_weekday"] = .integer(max(0, min(6, monthWeekday)))
                }
            }
            return out
        }

        /// Defaults for a rule starting on `day` (its weekday / day of month).
        static func defaults(for day: Date, calendar: Calendar) -> Rule {
            var rule = Rule()
            let weekday = calendar.component(.weekday, from: day) - 1
            rule.weekdays = [weekday]
            rule.monthDay = calendar.component(.day, from: day)
            rule.monthWeekday = weekday
            let dayOfMonth = rule.monthDay
            rule.monthNth = min(5, (dayOfMonth - 1) / 7 + 1)
            return rule
        }

        /// The rule after the first visit moved from `oldDay` to `newDay`,
        /// so the chosen start stays the first occurrence: the old start's
        /// weekday is swapped for the new one (other chosen weekdays stay),
        /// and month fields that still follow the old start follow the new
        /// one. Same shop-local day: unchanged.
        func movingStart(from oldDay: Date, to newDay: Date, calendar: Calendar) -> Rule {
            guard !calendar.isDate(oldDay, inSameDayAs: newDay) else { return self }
            let old = Rule.defaults(for: oldDay, calendar: calendar)
            let new = Rule.defaults(for: newDay, calendar: calendar)
            var rule = self
            let oldWeekday = old.weekdays.first ?? 0
            let newWeekday = new.weekdays.first ?? 0
            if rule.weekdays.isEmpty || rule.weekdays.contains(oldWeekday) {
                rule.weekdays.remove(oldWeekday)
                rule.weekdays.insert(newWeekday)
            }
            if rule.monthDay == old.monthDay {
                rule.monthDay = new.monthDay
            }
            if rule.monthNth == old.monthNth && rule.monthWeekday == old.monthWeekday {
                rule.monthNth = new.monthNth
                rule.monthWeekday = new.monthWeekday
            }
            return rule
        }

        var isValid: Bool {
            frequency == .month || !weekdays.isEmpty
        }
    }

    var rule = Rule()
    var end: End = .never

    static let utc = TimeZone(identifier: "UTC") ?? .current

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// `YYYY-MM-DD` of `date` in `calendar`'s time zone (the shop's).
    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year: Int = parts.year ?? 1970
        let month: Int = parts.month ?? 1
        let day: Int = parts.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// `HH:MM` of `date` in `calendar`'s time zone.
    static func timeString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// Why an edit of one visit can't be carried to the following visits,
    /// or nil when it can. `update_job_series` re-creates each eligible
    /// visit (the edited one too) on its own date and has no deposit, so a
    /// new date or deposit would be dropped: such an edit is saved on this
    /// visit only.
    static func followingScopeLimit(
        originalStart: Date?,
        newStart: Date?,
        originalDepositCents: Int,
        newDepositCents: Int,
        calendar: Calendar
    ) -> String? {
        var dayChanged = false
        if let originalStart, let newStart {
            dayChanged = !calendar.isDate(originalStart, inSameDayAs: newStart)
        }
        let depositChanged = originalDepositCents != newDepositCents
        switch (dayChanged, depositChanged) {
        case (true, true):
            return "A new date and a new deposit can only be saved on this visit. Following visits keep their own days and deposits; to move them to another day, change the repeat rule on the web app."
        case (true, false):
            return "A new date can only be saved on this visit. Following visits keep their own days; to move them to another day, change the repeat rule on the web app."
        case (false, true):
            return "A new deposit can only be saved on this visit. Following visits keep their own deposits."
        case (false, false):
            return nil
        }
    }

    /// End fields of the series JSON.
    func endJSON(calendar: Calendar) -> [String: AnyJSON] {
        switch end {
        case .never:
            return ["until_date": .null, "max_occurrences": .null]
        case .onDate(let day):
            return ["until_date": .string(Self.dayString(day, calendar: calendar)), "max_occurrences": .null]
        case .afterCount(let count):
            return ["until_date": .null, "max_occurrences": .integer(max(1, min(500, count)))]
        }
    }
}
