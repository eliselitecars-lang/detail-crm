//
//  CalendarEvent.swift
//  DetailCRM
//
//  Rows of the `calendar_events(shop, from, to, include_cancelled)` staff
//  feed (0007) plus the team colors used to tint job blocks.
//
//  Two event types come back:
//    * `job`          — a scheduled job. Technicians receive other people's
//                       jobs as anonymous busy blocks (`is_busy_block`,
//                       no number/customer/vehicle/address/title).
//    * `blocked_time` — shop-wide (member_id null) or per-member blocked
//                       time; the reason is hidden from technicians unless
//                       the block is shop-wide or their own.
//
//  v2 (0052, P-17) adds `event_kind` (`job`, or the blocked time's kind:
//  closed / time_off / meeting / consultation / reminder / other), the
//  job's `series_id`, the event `color`, and the job's service coordinates
//  (full view only). Repeating events come back once per occurrence with
//  the block's id, so `key` includes the start time. Customer-linked
//  events name the customer for managers only.
//

import Foundation
import DetailCore

// rpc: calendar_events
struct CalendarEvent: Codable, Hashable, Sendable, Identifiable {
    /// `job` | `blocked_time`
    var eventType: String
    var id: UUID
    var jobNumber: Int?
    var status: JobStatus?
    var startsAt: Date
    var endsAt: Date
    var isBusyBlock: Bool
    var customerID: UUID?
    var customerName: String?
    var vehicleID: UUID?
    var vehicleLabel: String?
    /// `shop` | `mobile`
    var locationType: String?
    var serviceAddress: String?
    var resourceID: UUID?
    var assignedMemberIDs: [UUID]
    /// Blocked times only: the member the block applies to (nil = whole shop).
    var memberID: UUID?
    /// Jobs: "Customer — Service, Service"; blocked times: the event
    /// title, else the reason.
    var title: String?
    /// `job` or the `calendar_event_kind` of a blocked time.
    var eventKind: String?
    /// Jobs of a recurring series.
    var seriesID: UUID?
    /// Event colour (`#RRGGBB`), when set.
    var color: String?
    var serviceLat: Double?
    var serviceLng: Double?

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case id
        case jobNumber = "job_number"
        case status
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case isBusyBlock = "is_busy_block"
        case customerID = "customer_id"
        case customerName = "customer_name"
        case vehicleID = "vehicle_id"
        case vehicleLabel = "vehicle_label"
        case locationType = "location_type"
        case serviceAddress = "service_address"
        case resourceID = "resource_id"
        case assignedMemberIDs = "assigned_member_ids"
        case memberID = "member_id"
        case title
        case eventKind = "event_kind"
        case seriesID = "series_id"
        case color
        case serviceLat = "service_lat"
        case serviceLng = "service_lng"
    }

    init(
        eventType: String,
        id: UUID,
        jobNumber: Int? = nil,
        status: JobStatus? = nil,
        startsAt: Date,
        endsAt: Date,
        isBusyBlock: Bool = false,
        customerID: UUID? = nil,
        customerName: String? = nil,
        vehicleID: UUID? = nil,
        vehicleLabel: String? = nil,
        locationType: String? = nil,
        serviceAddress: String? = nil,
        resourceID: UUID? = nil,
        assignedMemberIDs: [UUID] = [],
        memberID: UUID? = nil,
        title: String? = nil,
        eventKind: String? = nil,
        seriesID: UUID? = nil,
        color: String? = nil,
        serviceLat: Double? = nil,
        serviceLng: Double? = nil
    ) {
        self.eventType = eventType
        self.id = id
        self.jobNumber = jobNumber
        self.status = status
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isBusyBlock = isBusyBlock
        self.customerID = customerID
        self.customerName = customerName
        self.vehicleID = vehicleID
        self.vehicleLabel = vehicleLabel
        self.locationType = locationType
        self.serviceAddress = serviceAddress
        self.resourceID = resourceID
        self.assignedMemberIDs = assignedMemberIDs
        self.memberID = memberID
        self.title = title
        self.eventKind = eventKind
        self.seriesID = seriesID
        self.color = color
        self.serviceLat = serviceLat
        self.serviceLng = serviceLng
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventType = try c.decode(String.self, forKey: .eventType)
        id = try c.decode(UUID.self, forKey: .id)
        jobNumber = try c.decodeIfPresent(Int.self, forKey: .jobNumber)
        // An unknown future status must not break the whole calendar.
        if let raw = try c.decodeIfPresent(String.self, forKey: .status) {
            status = JobStatus(rawValue: raw)
        } else {
            status = nil
        }
        startsAt = try c.decode(Date.self, forKey: .startsAt)
        endsAt = try c.decode(Date.self, forKey: .endsAt)
        isBusyBlock = try c.decodeIfPresent(Bool.self, forKey: .isBusyBlock) ?? false
        customerID = try c.decodeIfPresent(UUID.self, forKey: .customerID)
        customerName = try c.decodeIfPresent(String.self, forKey: .customerName)
        vehicleID = try c.decodeIfPresent(UUID.self, forKey: .vehicleID)
        vehicleLabel = try c.decodeIfPresent(String.self, forKey: .vehicleLabel)
        locationType = try c.decodeIfPresent(String.self, forKey: .locationType)
        serviceAddress = try c.decodeIfPresent(String.self, forKey: .serviceAddress)
        resourceID = try c.decodeIfPresent(UUID.self, forKey: .resourceID)
        assignedMemberIDs = try c.decodeIfPresent([UUID].self, forKey: .assignedMemberIDs) ?? []
        memberID = try c.decodeIfPresent(UUID.self, forKey: .memberID)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        eventKind = try c.decodeIfPresent(String.self, forKey: .eventKind)
        seriesID = try c.decodeIfPresent(UUID.self, forKey: .seriesID)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        serviceLat = try c.decodeIfPresent(Double.self, forKey: .serviceLat)
        serviceLng = try c.decodeIfPresent(Double.self, forKey: .serviceLng)
    }

    // MARK: - Derived

    var isJob: Bool { eventType == "job" }
    var isBlockedTime: Bool { eventType == "blocked_time" }

    /// A job the viewer may open (not an anonymous busy block).
    var isOpenableJob: Bool { isJob && !isBusyBlock }

    var isMobile: Bool { locationType == "mobile" }

    /// Stable key across both event types (ids come from different tables;
    /// a repeating event has one row per occurrence with the same id).
    var key: String {
        if isBlockedTime {
            return "\(eventType):\(id.uuidString):\(Int(startsAt.timeIntervalSince1970))"
        }
        return "\(eventType):\(id.uuidString)"
    }

    /// The blocked time's kind (`closed` for rows from before kinds).
    var blockKind: JobsCalendarEvent.Kind? {
        guard isBlockedTime else { return nil }
        return JobsCalendarEvent.Kind(rawValue: eventKind ?? "closed") ?? .other
    }

    /// Closed hours and time off are drawn as shading behind the jobs;
    /// meetings, consultations, reminders and other events as blocks.
    var isBackgroundBlock: Bool {
        guard let kind = blockKind else { return false }
        return kind == .closed || kind == .timeOff
    }

    /// A calendar event (blocked-time row) drawn and opened like a block.
    var isForegroundEvent: Bool { isBlockedTime && !isBackgroundBlock }

    /// An occurrence of a recurring job series.
    var isSeriesJob: Bool { isJob && seriesID != nil }

    /// The service part of a job title ("Ana Ruiz — Full Detail, Wax" ->
    /// "Full Detail, Wax"), or nil.
    var servicesSummary: String? {
        guard isJob, let title else { return nil }
        guard let range = title.range(of: " — ") else { return nil }
        return String(title[range.upperBound...]).trimmedNonEmpty
    }

    /// The customer part of a job title ("Acme — Full Detail" -> "Acme").
    /// The feed's `customer_name` is built from first/last name only, so
    /// company-only customers have it nil while the title still starts
    /// with the company.
    var titleCustomerPart: String? {
        guard isJob, let title else { return nil }
        guard let range = title.range(of: " — ") else { return title.trimmedNonEmpty }
        return String(title[..<range.lowerBound]).trimmedNonEmpty
    }

    /// Main line for a block or row (never repeats the services, which
    /// rows show separately via `servicesSummary`).
    var displayTitle: String {
        if isBlockedTime {
            return title?.trimmedNonEmpty ?? blockKind?.displayName ?? "Blocked"
        }
        if isBusyBlock { return "Busy" }
        return customerName?.trimmedNonEmpty ?? titleCustomerPart ?? "Job"
    }

    /// Whether this event overlaps `[start, end)`.
    func overlaps(start: Date, end: Date) -> Bool {
        startsAt < end && endsAt > start
    }
}

// rpc: shop_team
struct CalendarTeamMember: Codable, Hashable, Sendable, Identifiable {
    var memberID: UUID
    var displayName: String
    var calendarColor: String?
    var active: Bool

    enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case displayName = "display_name"
        case calendarColor = "calendar_color"
        case active
    }

    var id: UUID { memberID }
}
