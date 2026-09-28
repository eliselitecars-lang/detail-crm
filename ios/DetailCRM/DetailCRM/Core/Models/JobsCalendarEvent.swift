//
//  JobsCalendarEvent.swift
//  DetailCRM
//
//  Calendar events (P-17): rows of `public.blocked_times` with a kind —
//  shop closed, a member's time off, meetings, customer consultations,
//  reminders and other events — optionally repeating (`recurrence`,
//  expanded by the server in shop-local wall time). Managers and up create
//  and edit them; technicians see them through `calendar_events` only
//  (customer-linked rows are hidden from them by RLS).
//
//  Capacity: "closed" always blocks online booking; other shop-wide events
//  count as one busy slot when `affects_capacity`; a member's time off (or
//  a meeting that takes the member) removes that member from the count
//  when the shop counts technicians' availability.
//

import Foundation
import Supabase

// table: blocked_times
struct JobsCalendarEvent: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var memberID: UUID?
    var startsAt: Date
    var endsAt: Date
    var reason: String?
    var kind: Kind
    var title: String?
    var customerID: UUID?
    var affectsCapacity: Bool
    var color: String?
    var recurrence: JobsBlockedTimeRecurrence?

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case memberID = "member_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case reason
        case kind
        case title
        case customerID = "customer_id"
        case affectsCapacity = "affects_capacity"
        case color
        case recurrence
    }

    static let selectColumns = [
        "id", "shop_id", "member_id", "starts_at", "ends_at", "reason", "kind", "title",
        "customer_id", "affects_capacity", "color", "recurrence",
    ].joined(separator: ",")

    /// `calendar_event_kind`.
    enum Kind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
        case closed
        case timeOff = "time_off"
        case meeting
        case consultation
        case reminder
        case other

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .closed: return "Shop closed"
            case .timeOff: return "Time off"
            case .meeting: return "Meeting"
            case .consultation: return "Consultation"
            case .reminder: return "Reminder"
            case .other: return "Event"
            }
        }

        var systemImage: String {
            switch self {
            case .closed: return "nosign"
            case .timeOff: return "airplane"
            case .meeting: return "person.3"
            case .consultation: return "person.crop.circle.badge.questionmark"
            case .reminder: return "bell"
            case .other: return "calendar"
            }
        }

        /// Only consultations and reminders may name a customer.
        var allowsCustomer: Bool { self == .consultation || self == .reminder }
        /// Closed is shop-wide; time off belongs to one member.
        var requiresMember: Bool { self == .timeOff }
        var forbidsMember: Bool { self == .closed }
        /// The server's default for `affects_capacity`.
        var defaultAffectsCapacity: Bool { self == .closed || self == .timeOff }
    }

    var isRepeating: Bool { recurrence != nil }
}

/// A repeat rule on a calendar event: every N days / weeks (on chosen
/// weekdays) / months, until a date or for a number of times. Stored as
/// JSON in `blocked_times.recurrence`; keys absent when unused.
struct JobsBlockedTimeRecurrence: Codable, Hashable, Sendable {
    enum Frequency: String, CaseIterable, Hashable, Sendable {
        case day
        case week
        case month

        var unitName: String { rawValue }
    }

    var frequency: Frequency
    /// 1…12.
    var interval: Int
    /// 0 = Sunday … 6 = Saturday (weekly only; empty = the event's weekday).
    var weekdays: [Int]
    /// Last day (`YYYY-MM-DD`), or nil.
    var untilDate: String?
    /// Number of occurrences (1…500), or nil. Never together with a date.
    var count: Int?

    init(frequency: Frequency, interval: Int = 1, weekdays: [Int] = [], untilDate: String? = nil, count: Int? = nil) {
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.untilDate = untilDate
        self.count = count
    }

    /// JSON keys of the stored object (not a table: no CodingKeys).
    private enum Field: String, CodingKey {
        case freq
        case interval
        case byWeekday = "by_weekday"
        case untilDate = "until_date"
        case count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        let raw = try c.decode(String.self, forKey: .freq)
        frequency = Frequency(rawValue: raw) ?? .week
        interval = try c.decodeIfPresent(Int.self, forKey: .interval) ?? 1
        weekdays = try c.decodeIfPresent([Int].self, forKey: .byWeekday) ?? []
        untilDate = try c.decodeIfPresent(String.self, forKey: .untilDate)
        count = try c.decodeIfPresent(Int.self, forKey: .count)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(frequency.rawValue, forKey: .freq)
        try c.encode(max(1, min(12, interval)), forKey: .interval)
        if frequency == .week && !weekdays.isEmpty {
            try c.encode(Array(Set(weekdays)).sorted(), forKey: .byWeekday)
        }
        if let untilDate {
            try c.encode(untilDate, forKey: .untilDate)
        } else if let count {
            try c.encode(max(1, min(500, count)), forKey: .count)
        }
    }

    /// The JSON for a row write.
    var json: AnyJSON {
        var object: [String: AnyJSON] = [
            "freq": .string(frequency.rawValue),
            "interval": .integer(max(1, min(12, interval))),
        ]
        if frequency == .week && !weekdays.isEmpty {
            object["by_weekday"] = .array(Array(Set(weekdays)).sorted().map { AnyJSON.integer($0) })
        }
        if let untilDate {
            object["until_date"] = .string(untilDate)
        } else if let count {
            object["count"] = .integer(max(1, min(500, count)))
        }
        return .object(object)
    }

    /// "Every week on Mon, Wed until Jun 30, 2026", "Every 2 days, 10 times".
    var summary: String {
        let unit = frequency.unitName
        var text = interval == 1 ? "Every \(unit)" : "Every \(interval) \(unit)s"
        if frequency == .week && !weekdays.isEmpty {
            let names = Array(Set(weekdays)).sorted().map { JobsSeriesDraft.Rule.weekdayNames[max(0, min(6, $0))] }
            text += " on " + names.joined(separator: ", ")
        }
        if let untilDate, let day = JobsSeriesDraft.dayFormatter.date(from: untilDate) {
            text += " until " + day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: JobsSeriesDraft.utc))
        } else if let count {
            text += count == 1 ? ", once" : ", \(count) times"
        }
        return text
    }
}
