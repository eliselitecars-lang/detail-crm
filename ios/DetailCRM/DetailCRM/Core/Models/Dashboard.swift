//
//  Dashboard.swift
//  DetailCRM
//
//  The Today tab's data: the `dashboard_summary` RPC result (0046), the
//  online booking requests waiting for a decision, the next job's location
//  and the signed-in member's open time entries.
//
//  All money is integer cents computed by the server; the app only formats
//  it. Technicians get `scope == "own"`: every money / booking / inbox
//  figure is null for them (SPEC §3).
//

import Foundation
import DetailCore

// MARK: - dashboard_summary

// rpc: dashboard_summary
struct DashboardSummary: Codable, Hashable, Sendable {
    var shopID: UUID
    var timezone: String
    var asOf: Date
    /// `shop` (owner/admin/manager) or `own` (technician).
    var scope: String
    /// Shop-local `yyyy-MM-dd` of today / the week start (Monday) / the month start.
    var today: String
    var weekStart: String
    var monthStart: String
    var jobsToday: DashboardSummaryJobsToday
    var nextJob: DashboardSummaryNextJob?
    var jobsThisWeek: Int
    var pendingBookingRequests: Int?
    var quotesAwaitingResponse: Int?
    var openInvoices: DashboardSummaryInvoiceTotals?
    var overdueInvoices: DashboardSummaryInvoiceTotals?
    var revenue: DashboardSummaryRevenue?
    var unreadInboundMessages: Int?
    var clockedIn: DashboardSummaryClockedIn

    enum CodingKeys: String, CodingKey {
        case shopID = "shop_id"
        case timezone
        case asOf = "as_of"
        case scope
        case today
        case weekStart = "week_start"
        case monthStart = "month_start"
        case jobsToday = "jobs_today"
        case nextJob = "next_job"
        case jobsThisWeek = "jobs_this_week"
        case pendingBookingRequests = "pending_booking_requests"
        case quotesAwaitingResponse = "quotes_awaiting_response"
        case openInvoices = "open_invoices"
        case overdueInvoices = "overdue_invoices"
        case revenue
        case unreadInboundMessages = "unread_inbound_messages"
        case clockedIn = "clocked_in"
    }

    /// Technician view: assigned jobs and own clock only.
    var isOwnScope: Bool { scope == "own" }
}

// rpc: dashboard_summary
struct DashboardSummaryJobsToday: Codable, Hashable, Sendable {
    /// Jobs overlapping today, excluding cancelled / no-show.
    var total: Int
    /// Count per `job_status` raw value (every status is present).
    var byStatus: [String: Int]

    enum CodingKeys: String, CodingKey {
        case total
        case byStatus = "by_status"
    }

    func count(_ status: JobStatus) -> Int {
        byStatus[status.rawValue] ?? 0
    }
}

// rpc: dashboard_summary
struct DashboardSummaryNextJob: Codable, Hashable, Sendable {
    var id: UUID
    var number: Int
    var status: JobStatus
    var scheduledStart: Date
    var scheduledEnd: Date
    /// `shop` | `mobile`
    var locationType: String
    var customerID: UUID
    var customerName: String?
    var vehicleID: UUID?
    var vehicleLabel: String?
    var assignedMemberIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case status
        case scheduledStart = "scheduled_start"
        case scheduledEnd = "scheduled_end"
        case locationType = "location_type"
        case customerID = "customer_id"
        case customerName = "customer_name"
        case vehicleID = "vehicle_id"
        case vehicleLabel = "vehicle_label"
        case assignedMemberIDs = "assigned_member_ids"
    }

    var isMobile: Bool { locationType == "mobile" }
}

// rpc: dashboard_summary
struct DashboardSummaryInvoiceTotals: Codable, Hashable, Sendable {
    var count: Int
    var balanceCents: Int

    enum CodingKeys: String, CodingKey {
        case count
        case balanceCents = "balance_cents"
    }
}

// rpc: dashboard_summary
struct DashboardSummaryRevenue: Codable, Hashable, Sendable {
    var today: DashboardSummaryRevenuePeriod
    var week: DashboardSummaryRevenuePeriod
    var month: DashboardSummaryRevenuePeriod

    enum CodingKeys: String, CodingKey {
        case today
        case week
        case month
    }
}

// rpc: dashboard_summary
struct DashboardSummaryRevenuePeriod: Codable, Hashable, Sendable {
    /// Received payments net of refunds, excluding tips.
    var netCents: Int
    var tipsCents: Int
    var paymentsCount: Int

    enum CodingKeys: String, CodingKey {
        case netCents = "net_cents"
        case tipsCents = "tips_cents"
        case paymentsCount = "payments_count"
    }
}

// rpc: dashboard_summary
struct DashboardSummaryClockedIn: Codable, Hashable, Sendable {
    var count: Int
    var members: [DashboardSummaryClockedMember]

    enum CodingKeys: String, CodingKey {
        case count
        case members
    }
}

// rpc: dashboard_summary
struct DashboardSummaryClockedMember: Codable, Hashable, Sendable, Identifiable {
    var memberID: UUID
    var displayName: String
    var since: Date
    /// The job they are clocked in to, if any.
    var jobID: UUID?

    enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case displayName = "display_name"
        case since
        case jobID = "job_id"
    }

    var id: UUID { memberID }
}

// MARK: - Booking requests (jobs still `requested` from online booking)

// table: jobs
struct DashboardSummaryRequestJob: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var number: Int
    var status: JobStatus
    var customerID: UUID
    var vehicleID: UUID?
    var scheduledStart: Date?
    var scheduledEnd: Date?
    var locationType: String
    var totalCents: Int
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case status
        case customerID = "customer_id"
        case vehicleID = "vehicle_id"
        case scheduledStart = "scheduled_start"
        case scheduledEnd = "scheduled_end"
        case locationType = "location_type"
        case totalCents = "total_cents"
        case createdAt = "created_at"
    }

    static let selectColumns = [
        "id", "number", "status", "customer_id", "vehicle_id", "scheduled_start",
        "scheduled_end", "location_type", "total_cents", "created_at",
    ].joined(separator: ",")
}

// table: customers
struct DashboardSummaryCustomerName: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var firstName: String?
    var lastName: String?
    var company: String?

    enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case company
    }

    static let selectColumns = "id,first_name,last_name,company"

    /// "Ana Ruiz", else the company, else "Customer".
    var fullName: String {
        let parts = [firstName, lastName]
            .compactMap { $0?.trimmedNonEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return company?.trimmedNonEmpty ?? "Customer"
    }

    /// First name only (technician hero card), else the full label.
    var greetingName: String {
        firstName?.trimmedNonEmpty ?? fullName
    }
}

// table: vehicles
struct DashboardSummaryVehicleName: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var year: Int?
    var make: String?
    var model: String?
    var color: String?

    enum CodingKeys: String, CodingKey {
        case id
        case year
        case make
        case model
        case color
    }

    static let selectColumns = "id,year,make,model,color"

    /// "2021 Toyota Tacoma", or nil when nothing is known.
    var label: String? {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if let make = make?.trimmedNonEmpty { parts.append(make) }
        if let model = model?.trimmedNonEmpty { parts.append(model) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// table: job_line_items
struct DashboardSummaryLineName: Codable, Hashable, Sendable {
    var jobID: UUID
    var name: String
    var sort: Int

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case name
        case sort
    }

    static let selectColumns = "job_id,name,sort"
}

/// One online booking request with the names needed to decide on it.
struct DashboardSummaryBookingRequest: Hashable, Sendable, Identifiable {
    var job: DashboardSummaryRequestJob
    var customerName: String
    var vehicleLabel: String?
    /// Service names in line order.
    var serviceNames: [String]

    var id: UUID { job.id }
}

// MARK: - Next job location / customer

// table: jobs
struct DashboardSummaryJobLocation: Codable, Hashable, Sendable {
    var id: UUID
    var customerID: UUID
    /// `shop` | `mobile`
    var locationType: String
    var serviceAddressLine1: String?
    var serviceAddressLine2: String?
    var serviceCity: String?
    var serviceRegion: String?
    var servicePostalCode: String?
    var serviceLat: Double?
    var serviceLng: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case customerID = "customer_id"
        case locationType = "location_type"
        case serviceAddressLine1 = "service_address_line1"
        case serviceAddressLine2 = "service_address_line2"
        case serviceCity = "service_city"
        case serviceRegion = "service_region"
        case servicePostalCode = "service_postal_code"
        case serviceLat = "service_lat"
        case serviceLng = "service_lng"
    }

    static let selectColumns = [
        "id", "customer_id", "location_type", "service_address_line1", "service_address_line2",
        "service_city", "service_region", "service_postal_code", "service_lat", "service_lng",
    ].joined(separator: ",")

    var isMobile: Bool { locationType == "mobile" }

    /// Single-line service address, if any part is set.
    var serviceAddress: String? {
        let cityLine = [serviceCity, serviceRegion, servicePostalCode]
            .compactMap { $0?.trimmedNonEmpty }
            .joined(separator: ", ")
        let parts = [serviceAddressLine1?.trimmedNonEmpty, serviceAddressLine2?.trimmedNonEmpty, cityLine.nonEmpty]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Where the next job happens and who it is for (hero card).
struct DashboardSummaryNextJobDetails: Hashable, Sendable {
    var location: DashboardSummaryJobLocation?
    var customer: DashboardSummaryCustomerName?
}

// MARK: - Own time entries (compact clock card)

// table: time_entries
struct DashboardSummaryTimeEntry: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var memberID: UUID
    var jobID: UUID?
    /// `shift` | `job`
    var kind: String
    var clockIn: Date
    var clockOut: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case memberID = "member_id"
        case jobID = "job_id"
        case kind
        case clockIn = "clock_in"
        case clockOut = "clock_out"
    }

    static let selectColumns = "id,member_id,job_id,kind,clock_in,clock_out"

    var isShift: Bool { kind == "shift" }
    var isOpen: Bool { clockOut == nil }
}
