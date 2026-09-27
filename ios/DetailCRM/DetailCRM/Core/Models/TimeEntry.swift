//
//  TimeEntry.swift
//  DetailCRM
//
//  Time clock rows (`time_entries`, SPEC §4.6) plus the small values the
//  Time Clock screens need: the jobs a member can clock in to today (from
//  the `calendar_events` feed) and the manager's manual-entry payload.
//
//  Rules live on the server: one open entry per member and kind, no
//  overlaps (exclusion constraint), technicians only clock themselves in
//  and out and cannot edit closed entries, manual entries are managers+.
//

import Foundation
import DetailCore

/// `time_entry_kind`: `shift` = on the clock; `job` = working one job
/// (job time may run inside a shift).
enum TimeEntryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case shift
    case job

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shift: return "Shift"
        case .job: return "Job"
        }
    }
}

/// `time_entry_source`: how the entry was recorded.
enum TimeEntrySource: String, Codable, Sendable {
    case app
    case web
    case manual

    var displayName: String {
        switch self {
        case .app: return "App"
        case .web: return "Web"
        case .manual: return "Manual"
        }
    }
}

// table: time_entries
struct TimeEntry: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var memberID: UUID
    var jobID: UUID?
    var kind: TimeEntryKind
    var clockIn: Date
    var clockOut: Date?
    var source: TimeEntrySource
    var notes: String?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case memberID = "member_id"
        case jobID = "job_id"
        case kind
        case clockIn = "clock_in"
        case clockOut = "clock_out"
        case source
        case notes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    static let selectColumns = [
        "id", "shop_id", "member_id", "job_id", "kind", "clock_in", "clock_out",
        "source", "notes", "created_at", "updated_at",
    ].joined(separator: ",")

    var isOpen: Bool { clockOut == nil }

    /// Worked seconds; an open entry runs until `now`.
    func durationSeconds(now: Date = Date()) -> Int {
        let end = clockOut ?? max(now, clockIn)
        return max(0, Int(end.timeIntervalSince(clockIn)))
    }

    /// Sum of worked seconds of `entries` (open entries run until `now`).
    static func totalSeconds(_ entries: [TimeEntry], now: Date = Date()) -> Int {
        entries.reduce(0) { $0 + $1.durationSeconds(now: now) }
    }

    /// "7h 30m" style text for a number of seconds (rounded down to minutes).
    static func durationText(seconds: Int) -> String {
        ShopClock.durationText(minutes: max(0, seconds) / 60)
    }

    /// "1:05:09" running-timer text.
    static func timerText(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
}

/// A job the signed-in member may clock in to today: jobs from the
/// `calendar_events` feed that are assigned to them and still workable.
// rpc: calendar_events
struct TimeClockJobOption: Codable, Identifiable, Hashable, Sendable {
    var eventType: String
    var id: UUID
    var jobNumber: Int?
    var status: String?
    var startsAt: Date?
    var endsAt: Date?
    var isBusyBlock: Bool
    var customerName: String?
    var vehicleLabel: String?
    var assignedMemberIDs: [UUID]
    var title: String?

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case id
        case jobNumber = "job_number"
        case status
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case isBusyBlock = "is_busy_block"
        case customerName = "customer_name"
        case vehicleLabel = "vehicle_label"
        case assignedMemberIDs = "assigned_member_ids"
        case title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventType = try container.decode(String.self, forKey: .eventType)
        id = try container.decode(UUID.self, forKey: .id)
        jobNumber = try container.decodeIfPresent(Int.self, forKey: .jobNumber)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        startsAt = try container.decodeIfPresent(Date.self, forKey: .startsAt)
        endsAt = try container.decodeIfPresent(Date.self, forKey: .endsAt)
        isBusyBlock = try container.decodeIfPresent(Bool.self, forKey: .isBusyBlock) ?? true
        customerName = try container.decodeIfPresent(String.self, forKey: .customerName)
        vehicleLabel = try container.decodeIfPresent(String.self, forKey: .vehicleLabel)
        assignedMemberIDs = try container.decodeIfPresent([UUID].self, forKey: .assignedMemberIDs) ?? []
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }

    var jobStatus: JobStatus? { status.flatMap { JobStatus(rawValue: $0) } }

    /// Server rule (`clock_in`): cancelled and no-show jobs can't be clocked.
    var isClockable: Bool {
        guard eventType == "job", !isBusyBlock else { return false }
        if let jobStatus, jobStatus.isSideExit { return false }
        return true
    }

    /// "#1042 · Ana Ruiz" style label.
    var label: String {
        var parts: [String] = []
        if let jobNumber { parts.append("#\(jobNumber)") }
        if let customerName, !customerName.isEmpty { parts.append(customerName) }
        return parts.isEmpty ? "Job" : parts.joined(separator: " · ")
    }
}

/// Job number lookup for entries that reference a job.
// table: jobs
struct TimeClockJobRef: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var number: Int

    enum CodingKeys: String, CodingKey {
        case id
        case number
    }
}

/// Manager insert / edit payload. `source` is set to `manual` by the
/// server for direct inserts and kept unchanged on edits.
// table: time_entries
struct TimeEntryDraft: Encodable, Sendable {
    var shopID: UUID
    var memberID: UUID
    var kind: TimeEntryKind
    var jobID: UUID?
    var clockIn: Date
    var clockOut: Date?
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case shopID = "shop_id"
        case memberID = "member_id"
        case kind
        case jobID = "job_id"
        case clockIn = "clock_in"
        case clockOut = "clock_out"
        case notes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shopID, forKey: .shopID)
        try container.encode(memberID, forKey: .memberID)
        try container.encode(kind, forKey: .kind)
        // Explicit nulls so an edit can clear clock_out / notes.
        try container.encode(jobID, forKey: .jobID)
        try container.encode(Supa.iso(clockIn), forKey: .clockIn)
        try container.encode(clockOut.map { Supa.iso($0) }, forKey: .clockOut)
        try container.encode(notes, forKey: .notes)
    }
}

/// Manager edit of an existing entry (times + notes; kind/job/member stay).
// table: time_entries
struct TimeEntryEdit: Encodable, Sendable {
    var clockIn: Date
    var clockOut: Date?
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case clockIn = "clock_in"
        case clockOut = "clock_out"
        case notes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Supa.iso(clockIn), forKey: .clockIn)
        try container.encode(clockOut.map { Supa.iso($0) }, forKey: .clockOut)
        try container.encode(notes, forKey: .notes)
    }
}
