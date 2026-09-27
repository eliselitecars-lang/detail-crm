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
    /// Jobs: "Customer — Service, Service"; blocked times: the reason.
    var title: String?

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
        title: String? = nil
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
    }

    // MARK: - Derived

    var isJob: Bool { eventType == "job" }
    var isBlockedTime: Bool { eventType == "blocked_time" }

    /// A job the viewer may open (not an anonymous busy block).
    var isOpenableJob: Bool { isJob && !isBusyBlock }

    var isMobile: Bool { locationType == "mobile" }

    /// Stable key across both event types (ids come from different tables).
    var key: String { "\(eventType):\(id.uuidString)" }

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
            return title?.trimmedNonEmpty ?? "Blocked"
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
