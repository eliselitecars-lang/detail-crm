//
//  JobsCustomField.swift
//  DetailCRM
//
//  Shop-defined fields (P-9, `public.custom_fields`, comms 0081/0088) and
//  their values in `jobs.custom_data` / `customers.custom_data`
//  ({key: value}). Every member may read the definitions (technicians see a
//  job's answers); owners/admins define them on the web. The server
//  validates every value (types, options, archived fields, required booking
//  questions) — the app only offers matching inputs.
//
//  Shared model: the jobs agent owns it; the customer screens (ops) use it
//  read-only.
//

import Foundation
import Supabase

/// `custom_field_type`.
enum JobsCustomFieldType: String, Codable, CaseIterable, Hashable, Sendable {
    case text
    case textarea
    case number
    case select
    case multiselect
    case checkbox
    case date

    var displayName: String {
        switch self {
        case .text: return "Text"
        case .textarea: return "Long text"
        case .number: return "Number"
        case .select: return "Choice"
        case .multiselect: return "Choices"
        case .checkbox: return "Yes / no"
        case .date: return "Date"
        }
    }

    /// Longest text the server accepts for text fields.
    var maxLength: Int? {
        switch self {
        case .text: return 2_000
        case .textarea: return 10_000
        default: return nil
        }
    }
}

/// One stored answer. The JSON shape follows the field type: text, long
/// text, choice and date are strings (dates `YYYY-MM-DD`), numbers are JSON
/// numbers, yes/no is a boolean and choices is an array of strings.
enum JobsCustomValue: Hashable, Sendable {
    case text(String)
    case number(Double)
    case bool(Bool)
    /// A calendar date as `YYYY-MM-DD` (no time zone).
    case date(String)
    case list([String])

    /// Reads a stored value for a field of `type`; nil for a value of the
    /// wrong shape (it is shown as missing rather than crashing the list).
    init?(json: AnyJSON, type: JobsCustomFieldType) {
        switch (type, json) {
        case (.text, .string(let text)), (.textarea, .string(let text)), (.select, .string(let text)):
            self = .text(text)
        case (.date, .string(let text)):
            self = .date(text)
        case (.number, _):
            guard let number = json.asDouble else { return nil }
            self = .number(number)
        case (.checkbox, .bool(let flag)):
            self = .bool(flag)
        case (.multiselect, .array(let items)):
            self = .list(items.compactMap(\.asString))
        default:
            return nil
        }
    }

    /// The JSON written to `custom_data`.
    var json: AnyJSON {
        switch self {
        case .text(let text), .date(let text):
            return .string(text)
        case .number(let number):
            if let whole = Int(exactly: number) { return .integer(whole) }
            return .double(number)
        case .bool(let flag):
            return .bool(flag)
        case .list(let items):
            return .array(items.map { AnyJSON.string($0) })
        }
    }

    /// Empty answers are dropped by the server, so they are never sent.
    var isEmpty: Bool {
        switch self {
        case .text(let text), .date(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .list(let items):
            return items.isEmpty
        case .number, .bool:
            return false
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// `YYYY-MM-DD` for a picked day (the day as shown, time zone free).
    static func dayString(from date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// The picked day for a `YYYY-MM-DD` value, at noon in `calendar`'s zone
    /// (safe for a DatePicker in that zone).
    static func date(fromDay text: String, calendar: Calendar) -> Date? {
        guard let utc = dayFormatter.date(from: text) else { return nil }
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC") ?? .current, from: utc)
        var local = DateComponents()
        local.year = parts.year
        local.month = parts.month
        local.day = parts.day
        local.hour = 12
        return calendar.date(from: local)
    }

    /// Human text for lists ("Yes", "3.5", "Mar 4, 2026", "A, B").
    var displayText: String {
        switch self {
        case .text(let text):
            return text
        case .number(let number):
            if let whole = Int(exactly: number) { return String(whole) }
            return number.formatted(.number.precision(.fractionLength(0...4)))
        case .bool(let flag):
            return flag ? "Yes" : "No"
        case .date(let text):
            guard let day = Self.dayFormatter.date(from: text) else { return text }
            return day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC") ?? .current))
        case .list(let items):
            return items.joined(separator: ", ")
        }
    }
}

// table: custom_fields
struct JobsCustomField: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    /// `custom_field_entity`: customer | job.
    var entity: String
    var key: String
    var label: String
    var type: JobsCustomFieldType
    var options: [String]
    var helpText: String?
    var required: Bool
    var showInBooking: Bool
    var showInLeadForm: Bool
    /// Booking question only for this location type (`shop` / `mobile`).
    var locationScope: String?
    var sort: Int
    var archivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case entity
        case key
        case label
        case type
        case options
        case helpText = "help_text"
        case required
        case showInBooking = "show_in_booking"
        case showInLeadForm = "show_in_lead_form"
        case locationScope = "location_scope"
        case sort
        case archivedAt = "archived_at"
    }

    static let selectColumns = [
        "id", "shop_id", "entity", "key", "label", "type", "options", "help_text", "required",
        "show_in_booking", "show_in_lead_form", "location_scope", "sort", "archived_at",
    ].joined(separator: ",")

    /// The two record kinds fields attach to.
    enum Entity: String, Sendable {
        case customer
        case job
    }

    var isArchived: Bool { archivedAt != nil }

    /// Whether staff can fill this field in on a job at `location`: a live
    /// field, and a location-scoped booking question only on jobs of that
    /// location type. (`required` binds online bookings only — the server
    /// never requires an answer on staff edits.)
    func isEditable(onJobAt location: JobLocationType?) -> Bool {
        guard !isArchived else { return false }
        guard let locationScope else { return true }
        return locationScope == location?.rawValue
    }

    /// Hint for a required booking question in the staff editor.
    var requiredOnlineHint: String? {
        required && showInBooking ? "Customers must answer this when they book online." : nil
    }

    /// This field's answer in a record's `custom_data`, when valid.
    func value(in data: [String: AnyJSON]?) -> JobsCustomValue? {
        guard let raw = data?[key], raw != .null else { return nil }
        return JobsCustomValue(json: raw, type: type)
    }
}
