//
//  Job.swift
//  DetailCRM
//
//  The work order (SPEC §4.4) and everything the job screens read next to
//  it: line items, assignments, the customer/vehicle on the job, the team
//  directory, resources, the job's money picture and catalog pricing.
//
//  Totals (`subtotal_cents` … `total_cents`) are maintained by the server
//  from the line items; the app only displays them. Types that another
//  feature group owns (Customer, Vehicle, CatalogItem, …) are NOT reused:
//  the job screens decode the columns they need into `Job*` structs.
//

import Foundation
import Supabase
import DetailCore

// MARK: - Enums

/// `location_type`: at the shop or at the customer (mobile).
enum JobLocationType: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case shop
    case mobile

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shop: return "At the shop"
        case .mobile: return "Mobile"
        }
    }

    var systemImage: String {
        switch self {
        case .shop: return "building.2"
        case .mobile: return "car.side"
        }
    }
}

/// `discount_kind` for a whole job: none, percent (basis points), fixed (cents).
enum JobDiscountKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case none
    case percent
    case fixed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .percent: return "Percent"
        case .fixed: return "Amount"
        }
    }
}

/// `service_kind`.
enum JobServiceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case service
    case package
    case addon
    case product

    var displayName: String {
        switch self {
        case .service: return "Service"
        case .package: return "Package"
        case .addon: return "Add-on"
        case .product: return "Product"
        }
    }
}

/// Template keys staff send from the job screen (technicians may send only
/// these three, on jobs assigned to them).
enum JobMessageTemplateKey: String, CaseIterable, Identifiable, Hashable, Sendable {
    case onTheWay = "on_the_way"
    case jobStarted = "job_started"
    case jobCompleted = "job_completed"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onTheWay: return "On my way"
        case .jobStarted: return "Job started"
        case .jobCompleted: return "Job complete"
        }
    }

    var systemImage: String {
        switch self {
        case .onTheWay: return "car.side"
        case .jobStarted: return "play.circle"
        case .jobCompleted: return "checkmark.seal"
        }
    }
}

/// `message_channel`.
enum JobMessageChannel: String, CaseIterable, Identifiable, Hashable, Sendable {
    case sms
    case email

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sms: return "Text"
        case .email: return "Email"
        }
    }
}

// MARK: - Job

// table: jobs
struct Job: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var number: Int
    var customerID: UUID
    var vehicleID: UUID?
    var status: JobStatus
    var scheduledStart: Date?
    var scheduledEnd: Date?
    var locationType: JobLocationType
    var serviceAddressLine1: String?
    var serviceAddressLine2: String?
    var serviceCity: String?
    var serviceRegion: String?
    var servicePostalCode: String?
    var serviceLat: Double?
    var serviceLng: Double?
    var resourceID: UUID?
    var notes: String?
    var internalNotes: String?
    var source: String
    var quoteID: UUID?
    /// When set, the discount comes from this coupon and can't be edited by hand.
    var couponID: UUID?
    var discountKind: JobDiscountKind
    var discountValue: Int
    var subtotalCents: Int
    var discountCents: Int
    var taxRateBps: Int
    var taxCents: Int
    var totalCents: Int
    var depositRequiredCents: Int
    var createdBy: UUID?
    var confirmedAt: Date?
    var enRouteAt: Date?
    var startedAt: Date?
    var completedAt: Date?
    var cancelledAt: Date?
    var cancelReason: String?
    var createdAt: Date
    var updatedAt: Date
    /// Recurring series this job belongs to (P-1; set only by the series
    /// RPCs) and its occurrence number.
    var seriesID: UUID?
    var seriesSeq: Int?
    /// True once this occurrence was moved on its own ("this job only"):
    /// "this and following" series edits leave it alone.
    var seriesDetached: Bool?
    /// Answers to the shop's job fields / booking questions {key: value}.
    var customData: [String: AnyJSON]?
    /// Manual stop order within its shop-local day (0 = first).
    var routePosition: Int?
    /// Staff paused the automatic deposit reminders of this job.
    var depositFollowupsPaused: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case number
        case customerID = "customer_id"
        case vehicleID = "vehicle_id"
        case status
        case scheduledStart = "scheduled_start"
        case scheduledEnd = "scheduled_end"
        case locationType = "location_type"
        case serviceAddressLine1 = "service_address_line1"
        case serviceAddressLine2 = "service_address_line2"
        case serviceCity = "service_city"
        case serviceRegion = "service_region"
        case servicePostalCode = "service_postal_code"
        case serviceLat = "service_lat"
        case serviceLng = "service_lng"
        case resourceID = "resource_id"
        case notes
        case internalNotes = "internal_notes"
        case source
        case quoteID = "quote_id"
        case couponID = "coupon_id"
        case discountKind = "discount_kind"
        case discountValue = "discount_value"
        case subtotalCents = "subtotal_cents"
        case discountCents = "discount_cents"
        case taxRateBps = "tax_rate_bps"
        case taxCents = "tax_cents"
        case totalCents = "total_cents"
        case depositRequiredCents = "deposit_required_cents"
        case createdBy = "created_by"
        case confirmedAt = "confirmed_at"
        case enRouteAt = "en_route_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case cancelledAt = "cancelled_at"
        case cancelReason = "cancel_reason"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case seriesID = "series_id"
        case seriesSeq = "series_seq"
        case seriesDetached = "series_detached"
        case customData = "custom_data"
        case routePosition = "route_position"
        case depositFollowupsPaused = "deposit_followups_paused"
    }

    static let selectColumns = [
        "id", "shop_id", "number", "customer_id", "vehicle_id", "status",
        "scheduled_start", "scheduled_end", "location_type",
        "service_address_line1", "service_address_line2", "service_city", "service_region",
        "service_postal_code", "service_lat", "service_lng", "resource_id",
        "notes", "internal_notes", "source", "quote_id", "coupon_id",
        "discount_kind", "discount_value", "subtotal_cents", "discount_cents",
        "tax_rate_bps", "tax_cents", "total_cents", "deposit_required_cents",
        "created_by", "confirmed_at", "en_route_at", "started_at", "completed_at",
        "cancelled_at", "cancel_reason", "created_at", "updated_at",
        "series_id", "series_seq", "series_detached", "custom_data", "route_position",
        "deposit_followups_paused",
    ].joined(separator: ",")

    /// "Job #1042".
    var title: String { "Job #\(number)" }

    /// Single-line service address (mobile jobs), if any part is set.
    var serviceAddressSummary: String? {
        JobAddressFormatting.summary(
            line1: serviceAddressLine1,
            line2: serviceAddressLine2,
            city: serviceCity,
            region: serviceRegion,
            postalCode: servicePostalCode
        )
    }

    /// An occurrence of a recurring series.
    var isSeriesOccurrence: Bool { seriesID != nil }

    /// Scheduled length in minutes, when scheduled.
    var scheduledMinutes: Int? {
        guard let start = scheduledStart, let end = scheduledEnd else { return nil }
        return max(0, Int(end.timeIntervalSince(start) / 60))
    }
}

/// Address joining shared by jobs and customers.
enum JobAddressFormatting {
    static func summary(
        line1: String?,
        line2: String?,
        city: String?,
        region: String?,
        postalCode: String?
    ) -> String? {
        let cityParts: [String] = [city, region, postalCode].compactMap { $0?.trimmedNonEmpty }
        let cityLine = cityParts.joined(separator: ", ")
        let parts: [String] = [line1?.trimmedNonEmpty, line2?.trimmedNonEmpty, cityLine.trimmedNonEmpty]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: - Customer & vehicle on a job

/// The job's customer (only the columns the job screens need). Technicians
/// can read it only while they're assigned to one of the customer's jobs.
// table: customers
struct JobCustomer: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var firstName: String?
    var lastName: String?
    var company: String?
    var email: String?
    var phone: String?
    var addressLine1: String?
    var addressLine2: String?
    var city: String?
    var region: String?
    var postalCode: String?
    var smsOptedOutAt: Date?
    var emailOptedOutAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case company
        case email
        case phone
        case addressLine1 = "address_line1"
        case addressLine2 = "address_line2"
        case city
        case region
        case postalCode = "postal_code"
        case smsOptedOutAt = "sms_opted_out_at"
        case emailOptedOutAt = "email_opted_out_at"
    }

    static let selectColumns = [
        "id", "first_name", "last_name", "company", "email", "phone",
        "address_line1", "address_line2", "city", "region", "postal_code",
        "sms_opted_out_at", "email_opted_out_at",
    ].joined(separator: ",")

    /// "Ana Ruiz", else the company, else "Customer".
    var displayName: String {
        let person = [firstName?.trimmedNonEmpty, lastName?.trimmedNonEmpty]
            .compactMap { $0 }
            .joined(separator: " ")
        if let name = person.trimmedNonEmpty { return name }
        return company?.trimmedNonEmpty ?? "Customer"
    }

    /// Company shown under a person's name.
    var secondaryLine: String? {
        let person = [firstName?.trimmedNonEmpty, lastName?.trimmedNonEmpty].compactMap { $0 }
        guard !person.isEmpty else { return nil }
        return company?.trimmedNonEmpty
    }

    var addressSummary: String? {
        JobAddressFormatting.summary(
            line1: addressLine1,
            line2: addressLine2,
            city: city,
            region: region,
            postalCode: postalCode
        )
    }

    /// Phone formatted for people ("(205) 555-0100").
    var phoneDisplay: String? {
        guard let phone = phone?.trimmedNonEmpty else { return nil }
        return PhoneNumber.format(phone)
    }
}

// table: vehicles
struct JobVehicle: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var customerID: UUID
    var year: Int?
    var make: String?
    var model: String?
    var trim: String?
    var color: String?
    var vin: String?
    var licensePlate: String?
    var categoryID: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case customerID = "customer_id"
        case year
        case make
        case model
        case trim
        case color
        case vin
        case licensePlate = "license_plate"
        case categoryID = "category_id"
    }

    static let selectColumns = [
        "id", "customer_id", "year", "make", "model", "trim", "color", "vin",
        "license_plate", "category_id",
    ].joined(separator: ",")

    /// "2021 Toyota RAV4 XLE", else "Vehicle".
    var label: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        for part in [make, model, trim] {
            if let text = part?.trimmedNonEmpty { parts.append(text) }
        }
        return parts.isEmpty ? "Vehicle" : parts.joined(separator: " ")
    }

    /// "Blue · ABC1234".
    var detailLine: String? {
        let parts: [String] = [color?.trimmedNonEmpty, licensePlate?.trimmedNonEmpty].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// table: vehicle_categories
struct JobVehicleCategory: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var sort: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sort
    }
}

// MARK: - Line items

// table: job_line_items
struct JobLineItem: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var jobID: UUID
    var serviceID: UUID?
    var vehicleID: UUID?
    var name: String
    var description: String?
    var quantity: Decimal
    var unitPriceCents: Int
    var discountCents: Int
    var taxable: Bool
    var durationMinutes: Int
    var sort: Int
    /// Server-generated `line_total_cents(quantity, unit_price, discount)`.
    var totalCents: Int?
    var createdAt: Date
    /// A preset fee line (P-21).
    var feeID: UUID?
    /// Whether the job discount / coupon applies to this line (server-set).
    var discountEligible: Bool?
    /// Included in this membership (free visit).
    var membershipID: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case jobID = "job_id"
        case serviceID = "service_id"
        case vehicleID = "vehicle_id"
        case name
        case description
        case quantity
        case unitPriceCents = "unit_price_cents"
        case discountCents = "discount_cents"
        case taxable
        case durationMinutes = "duration_minutes"
        case sort
        case totalCents = "total_cents"
        case createdAt = "created_at"
        case feeID = "fee_id"
        case discountEligible = "discount_eligible"
        case membershipID = "membership_id"
    }

    static let selectColumns = [
        "id", "shop_id", "job_id", "service_id", "vehicle_id", "name", "description",
        "quantity", "unit_price_cents", "discount_cents", "taxable", "duration_minutes",
        "sort", "total_cents", "created_at", "fee_id", "discount_eligible", "membership_id",
    ].joined(separator: ",")
}

/// A line to insert or the editable fields of an existing line. Prices
/// for catalog lines come from `price_services`; the server recomputes the
/// job's totals after every write.
// table: job_line_items
struct JobLineDraft: Encodable, Hashable, Sendable {
    var serviceID: UUID?
    var vehicleID: UUID?
    var name: String
    var description: String?
    var quantity: Decimal
    var unitPriceCents: Int
    var discountCents: Int
    var taxable: Bool
    var durationMinutes: Int
    var sort: Int

    enum CodingKeys: String, CodingKey {
        case serviceID = "service_id"
        case vehicleID = "vehicle_id"
        case name
        case description
        case quantity
        case unitPriceCents = "unit_price_cents"
        case discountCents = "discount_cents"
        case taxable
        case durationMinutes = "duration_minutes"
        case sort
    }

    /// Nulls are sent explicitly so a batch insert has the same keys on
    /// every row and an update can clear a value.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serviceID, forKey: .serviceID)
        try container.encode(vehicleID, forKey: .vehicleID)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(quantity, forKey: .quantity)
        try container.encode(unitPriceCents, forKey: .unitPriceCents)
        try container.encode(discountCents, forKey: .discountCents)
        try container.encode(taxable, forKey: .taxable)
        try container.encode(durationMinutes, forKey: .durationMinutes)
        try container.encode(sort, forKey: .sort)
    }

    init(
        serviceID: UUID? = nil,
        vehicleID: UUID? = nil,
        name: String,
        description: String? = nil,
        quantity: Decimal = 1,
        unitPriceCents: Int,
        discountCents: Int = 0,
        taxable: Bool = true,
        durationMinutes: Int = 0,
        sort: Int = 0
    ) {
        self.serviceID = serviceID
        self.vehicleID = vehicleID
        self.name = name
        self.description = description
        self.quantity = quantity
        self.unitPriceCents = unitPriceCents
        self.discountCents = discountCents
        self.taxable = taxable
        self.durationMinutes = durationMinutes
        self.sort = sort
    }

    init(line: JobLineItem) {
        self.init(
            serviceID: line.serviceID,
            vehicleID: line.vehicleID,
            name: line.name,
            description: line.description,
            quantity: line.quantity,
            unitPriceCents: line.unitPriceCents,
            discountCents: line.discountCents,
            taxable: line.taxable,
            durationMinutes: line.durationMinutes,
            sort: line.sort
        )
    }
}

// MARK: - Assignments & team

// table: job_assignments
struct JobAssignment: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var jobID: UUID
    var memberID: UUID
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case jobID = "job_id"
        case memberID = "member_id"
        case createdAt = "created_at"
    }
}

/// One row of the team directory. Technicians get names/colors only;
/// phone and email are returned to managers and above.
// rpc: shop_team
struct JobTeamMember: Codable, Identifiable, Hashable, Sendable {
    var memberID: UUID
    var userID: UUID
    var role: ShopRole
    var displayName: String
    var calendarColor: String?
    var active: Bool
    var phone: String?
    var email: String?

    var id: UUID { memberID }

    enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case userID = "user_id"
        case role
        case displayName = "display_name"
        case calendarColor = "calendar_color"
        case active
        case phone
        case email
    }
}

/// Bays / vans a job can be booked on.
// table: resources
struct JobResource: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var kind: String
    var active: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case active
    }
}

// MARK: - Money picture

/// `job_payment_summary(job)` — collectors only (managers+, or assigned
/// technicians when the shop lets technicians collect).
// rpc: job_payment_summary
struct JobPaymentSummary: Codable, Hashable, Sendable {
    var jobID: UUID
    var invoiceID: UUID?
    var invoiceNumber: Int?
    var invoiceStatus: InvoiceStatus?
    var totalCents: Int
    var depositRequiredCents: Int
    var depositPaidCents: Int
    var depositDueCents: Int
    var paidCents: Int
    var tipCents: Int
    var refundedCents: Int
    var pendingCents: Int
    var balanceCents: Int
    /// Jobs on the live invoice: 1 single, 2+ grouped (fleet) invoice (P-7).
    var invoiceJobCount: Int?

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case invoiceID = "invoice_id"
        case invoiceNumber = "invoice_number"
        case invoiceStatus = "invoice_status"
        case totalCents = "total_cents"
        case depositRequiredCents = "deposit_required_cents"
        case depositPaidCents = "deposit_paid_cents"
        case depositDueCents = "deposit_due_cents"
        case paidCents = "paid_cents"
        case tipCents = "tip_cents"
        case refundedCents = "refunded_cents"
        case pendingCents = "pending_cents"
        case balanceCents = "balance_cents"
        case invoiceJobCount = "invoice_job_count"
    }

    /// Billed together with other jobs on one invoice.
    var isOnGroupedInvoice: Bool { (invoiceJobCount ?? 0) > 1 }
}

/// The invoice issued by `create_invoice_from_job` (only what the job
/// screen needs to navigate to it).
/// The job's issued (non-void) invoice, for the "services changed after
/// invoicing" notes. Values come straight from `job_payment_summary`.
// rpc: job_payment_summary
struct JobIssuedInvoiceInfo: Hashable, Sendable {
    var invoiceID: UUID
    var number: Int?
    /// The invoice's total (server value).
    var totalCents: Int

    /// "Invoice #12", or "The invoice" when it has no number.
    var title: String {
        number.map { "Invoice #\($0)" } ?? "The invoice"
    }
}

// rpc: create_invoice_from_job
struct JobCreatedInvoice: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var number: Int
    var status: InvoiceStatus

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case status
    }
}

/// What a template would send (`preview_template_message`).
// rpc: preview_template_message
struct JobMessagePreview: Codable, Hashable, Sendable {
    var enabled: Bool?
    var toAddress: String?
    var subject: String?
    var body: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case toAddress = "to_address"
        case subject
        case body
    }
}

/// Result of the messaging function's `send` action.
struct JobMessageSendResult: Hashable, Sendable {
    var messageID: UUID?
    /// sent, failed, queued (retry scheduled), sending, cancelled.
    var status: String
    var error: String?

    var didFail: Bool { status == "failed" || status == "cancelled" }
}

// MARK: - Catalog & pricing

/// An active catalog item (service, package, add-on or product).
// table: services
struct JobCatalogEntry: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var categoryID: UUID?
    var name: String
    var description: String?
    var kind: JobServiceKind
    var durationMinutes: Int
    var taxable: Bool
    var sort: Int

    enum CodingKeys: String, CodingKey {
        case id
        case categoryID = "category_id"
        case name
        case description
        case kind
        case durationMinutes = "duration_minutes"
        case taxable
        case sort
    }

    static let selectColumns = [
        "id", "category_id", "name", "description", "kind", "duration_minutes", "taxable", "sort",
    ].joined(separator: ",")
}

// table: service_categories
struct JobServiceCategory: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var sort: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sort
    }
}

/// Add-ons offered with a service (a service with no rows offers every add-on).
// table: service_addons
struct JobServiceAddonLink: Codable, Hashable, Sendable {
    var serviceID: UUID
    var addonID: UUID

    enum CodingKeys: String, CodingKey {
        case serviceID = "service_id"
        case addonID = "addon_id"
    }
}

/// The shop's active catalog, grouped for pickers.
struct JobCatalog: Hashable, Sendable {
    var entries: [JobCatalogEntry]
    var categories: [JobServiceCategory]
    var addonLinks: [JobServiceAddonLink]

    /// Everything that is not an add-on (services, packages, products).
    var primaryEntries: [JobCatalogEntry] {
        entries.filter { $0.kind != .addon }
    }

    var addons: [JobCatalogEntry] {
        entries.filter { $0.kind == .addon }
    }

    /// Add-ons offered with `serviceIDs`: a service with no add-on rows
    /// offers every add-on; otherwise only its linked ones.
    func addonsOffered(with serviceIDs: Set<UUID>) -> [JobCatalogEntry] {
        guard !serviceIDs.isEmpty else { return [] }
        var allowed = Set<UUID>()
        for serviceID in serviceIDs {
            let links = addonLinks.filter { $0.serviceID == serviceID }
            if links.isEmpty { return addons }
            for link in links { allowed.insert(link.addonID) }
        }
        return addons.filter { allowed.contains($0.id) }
    }

    /// Category name for grouping ("Other" when uncategorized).
    func categoryName(for entry: JobCatalogEntry) -> String {
        guard let id = entry.categoryID,
              let category = categories.first(where: { $0.id == id }) else { return "Other" }
        return category.name
    }

    /// Primary entries grouped by category in catalog order.
    var groupedPrimaryEntries: [JobCatalogGroup] {
        var order: [String] = []
        var groups: [String: [JobCatalogEntry]] = [:]
        let sortedCategories = categories.sorted { ($0.sort, $0.name) < ($1.sort, $1.name) }
        for category in sortedCategories where !order.contains(category.name) {
            order.append(category.name)
        }
        for entry in primaryEntries {
            let name = categoryName(for: entry)
            if !order.contains(name) { order.append(name) }
            groups[name, default: []].append(entry)
        }
        return order.compactMap { name in
            guard let entries = groups[name], !entries.isEmpty else { return nil }
            return JobCatalogGroup(name: name, entries: entries)
        }
    }
}

/// One category of the catalog picker.
struct JobCatalogGroup: Identifiable, Hashable, Sendable {
    var name: String
    var entries: [JobCatalogEntry]

    var id: String { name }
}

/// One priced line of `price_services` (category price, membership-included
/// lines at 0). `unit_price_cents` is null when the service has no
/// applicable price.
// rpc: price_services
struct PricedService: Codable, Identifiable, Hashable, Sendable {
    var serviceID: UUID
    var name: String
    var kind: JobServiceKind
    var taxable: Bool
    var durationMinutes: Int?
    var catalogPriceCents: Int?
    var unitPriceCents: Int?
    var membershipIncluded: Bool
    var note: String?

    var id: UUID { serviceID }

    enum CodingKeys: String, CodingKey {
        case serviceID = "service_id"
        case name
        case kind
        case taxable
        case durationMinutes = "duration_minutes"
        case catalogPriceCents = "catalog_price_cents"
        case unitPriceCents = "unit_price_cents"
        case membershipIncluded = "membership_included"
        case note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serviceID = try container.decode(UUID.self, forKey: .serviceID)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(JobServiceKind.self, forKey: .kind)
        taxable = try container.decodeIfPresent(Bool.self, forKey: .taxable) ?? true
        durationMinutes = try container.decodeIfPresent(Int.self, forKey: .durationMinutes)
        catalogPriceCents = try container.decodeIfPresent(Int.self, forKey: .catalogPriceCents)
        unitPriceCents = try container.decodeIfPresent(Int.self, forKey: .unitPriceCents)
        membershipIncluded = try container.decodeIfPresent(Bool.self, forKey: .membershipIncluded) ?? false
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    /// Whether the line can be added (it has a price or is included).
    var isPriced: Bool { unitPriceCents != nil }
}

/// An active membership that affected pricing.
// rpc: price_services
struct JobPricingMembership: Codable, Hashable, Sendable {
    var membershipID: UUID
    var planName: String
    var discountBps: Int
    var vehicleID: UUID?

    enum CodingKeys: String, CodingKey {
        case membershipID = "membership_id"
        case planName = "plan_name"
        case discountBps = "discount_bps"
        case vehicleID = "vehicle_id"
    }
}

/// Preview totals from `price_services` (clearly a preview; the job's
/// totals are recomputed by the server once lines are saved).
// rpc: price_services
struct JobPricingTotals: Codable, Hashable, Sendable {
    var subtotalCents: Int
    var discountCents: Int
    var taxCents: Int
    var totalCents: Int

    enum CodingKeys: String, CodingKey {
        case subtotalCents = "subtotal_cents"
        case discountCents = "discount_cents"
        case taxCents = "tax_cents"
        case totalCents = "total_cents"
    }
}

/// `price_services(shop, customer, category, service_ids, vehicle)`.
// rpc: price_services
struct JobPricing: Codable, Hashable, Sendable {
    var vehicleCategoryID: UUID?
    var taxRateBps: Int?
    var durationMinutes: Int?
    var priced: Bool
    var lines: [PricedService]
    var memberships: [JobPricingMembership]
    var suggestedDiscountKind: JobDiscountKind
    var suggestedDiscountValue: Int
    var totals: JobPricingTotals?

    enum CodingKeys: String, CodingKey {
        case vehicleCategoryID = "vehicle_category_id"
        case taxRateBps = "tax_rate_bps"
        case durationMinutes = "duration_minutes"
        case priced
        case lines
        case memberships
        case suggestedDiscountKind = "suggested_discount_kind"
        case suggestedDiscountValue = "suggested_discount_value"
        case totals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vehicleCategoryID = try container.decodeIfPresent(UUID.self, forKey: .vehicleCategoryID)
        taxRateBps = try container.decodeIfPresent(Int.self, forKey: .taxRateBps)
        durationMinutes = try container.decodeIfPresent(Int.self, forKey: .durationMinutes)
        priced = try container.decodeIfPresent(Bool.self, forKey: .priced) ?? false
        lines = try container.decodeIfPresent([PricedService].self, forKey: .lines) ?? []
        memberships = try container.decodeIfPresent([JobPricingMembership].self, forKey: .memberships) ?? []
        suggestedDiscountKind = try container.decodeIfPresent(JobDiscountKind.self, forKey: .suggestedDiscountKind) ?? .none
        suggestedDiscountValue = try container.decodeIfPresent(Int.self, forKey: .suggestedDiscountValue) ?? 0
        totals = try container.decodeIfPresent(JobPricingTotals.self, forKey: .totals)
    }

    /// Lines that have no price for this vehicle category.
    var unpricedLines: [PricedService] { lines.filter { !$0.isPriced } }
}

/// Every catalog entry priced for one customer + vehicle (category price,
/// membership inclusions at 0) — what pickers show next to each service.
struct JobPricedCatalog: Hashable, Sendable {
    /// serviceID -> priced line (unit price nil when no price applies).
    var prices: [UUID: PricedService]
    var memberships: [JobPricingMembership]
    /// Member discount the server suggests for the whole job (basis points).
    var suggestedDiscountBps: Int
    var taxRateBps: Int?

    static let empty = JobPricedCatalog(prices: [:], memberships: [], suggestedDiscountBps: 0, taxRateBps: nil)

    func price(for serviceID: UUID) -> PricedService? {
        prices[serviceID]
    }

    /// Lines for `serviceIDs` in the given order; throws when a service has
    /// no price for this vehicle (the user adds it as a custom line).
    func lineDrafts(
        for serviceIDs: [UUID],
        vehicleID: UUID?,
        firstSort: Int
    ) throws -> [JobLineDraft] {
        var drafts: [JobLineDraft] = []
        var missing: [String] = []
        for (offset, serviceID) in serviceIDs.enumerated() {
            guard let priced = prices[serviceID] else {
                missing.append("a service")
                continue
            }
            guard let unit = priced.unitPriceCents else {
                missing.append(priced.name)
                continue
            }
            drafts.append(
                JobLineDraft(
                    serviceID: serviceID,
                    vehicleID: vehicleID,
                    name: priced.name,
                    description: priced.note,
                    quantity: 1,
                    unitPriceCents: unit,
                    discountCents: 0,
                    taxable: priced.taxable,
                    durationMinutes: priced.durationMinutes ?? 0,
                    sort: firstSort + offset
                )
            )
        }
        if !missing.isEmpty {
            throw AppError.invalidInput(
                "No price is set for \(missing.joined(separator: ", ")) on this vehicle. Add it as a custom line instead."
            )
        }
        return drafts
    }
}

// MARK: - Detail snapshot

/// Everything the job screen loads in its first pass.
struct JobDetailSnapshot: Hashable, Sendable {
    var job: Job
    /// nil when the caller can't read the customer.
    var customer: JobCustomer?
    var vehicle: JobVehicle?
    var lineItems: [JobLineItem]
    var assignments: [JobAssignment]
    /// Active and inactive members (names for assignments).
    var team: [JobTeamMember]

    func member(_ id: UUID) -> JobTeamMember? {
        team.first { $0.memberID == id }
    }

    /// Whether `memberID` (the signed-in member) is assigned to the job.
    func isAssigned(memberID: UUID?) -> Bool {
        guard let memberID else { return false }
        return assignments.contains { $0.memberID == memberID }
    }

    /// Sum of line durations (0 when none have durations).
    var lineDurationMinutes: Int {
        lineItems.reduce(0) { $0 + $1.durationMinutes }
    }
}

// MARK: - Availability (New Job schedule step)

/// One busy item from the staff calendar feed — a job or a blocked time —
/// decoded with just what the New Job availability check needs.
// rpc: calendar_events
struct JobBusyItem: Decodable, Identifiable, Hashable, Sendable {
    var eventType: String
    var id: UUID
    var jobNumber: Int?
    var startsAt: Date
    var endsAt: Date
    var isBusyBlock: Bool
    var customerName: String?
    var resourceID: UUID?
    var assignedMemberIDs: [UUID]
    /// Blocked times: the member blocked (nil = the whole shop).
    var memberID: UUID?
    /// Jobs: "Customer — services"; blocked times: the reason.
    var title: String?

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case id
        case jobNumber = "job_number"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case isBusyBlock = "is_busy_block"
        case customerName = "customer_name"
        case resourceID = "resource_id"
        case assignedMemberIDs = "assigned_member_ids"
        case memberID = "member_id"
        case title
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventType = try c.decode(String.self, forKey: .eventType)
        id = try c.decode(UUID.self, forKey: .id)
        jobNumber = try c.decodeIfPresent(Int.self, forKey: .jobNumber)
        startsAt = try c.decode(Date.self, forKey: .startsAt)
        endsAt = try c.decode(Date.self, forKey: .endsAt)
        isBusyBlock = try c.decodeIfPresent(Bool.self, forKey: .isBusyBlock) ?? false
        customerName = try c.decodeIfPresent(String.self, forKey: .customerName)
        resourceID = try c.decodeIfPresent(UUID.self, forKey: .resourceID)
        assignedMemberIDs = try c.decodeIfPresent([UUID].self, forKey: .assignedMemberIDs) ?? []
        memberID = try c.decodeIfPresent(UUID.self, forKey: .memberID)
        title = try c.decodeIfPresent(String.self, forKey: .title)
    }

    var isBlockedTime: Bool { eventType == "blocked_time" }

    func overlaps(start: Date, end: Date) -> Bool {
        startsAt < end && endsAt > start
    }

    /// "Job #123 · Jane Doe — Full detail" / "Blocked · Lunch".
    var summary: String {
        if isBlockedTime {
            if let reason = title?.trimmedNonEmpty { return "Blocked · " + reason }
            return "Blocked time"
        }
        let number = jobNumber.map { "Job #\($0)" } ?? "Job"
        if let text = title?.trimmedNonEmpty ?? customerName?.trimmedNonEmpty {
            return number + " · " + text
        }
        return number
    }
}

/// Opening hours for one weekday interval (wall clock, shop time zone).
// table: business_hours
struct JobBusinessHours: Decodable, Hashable, Sendable {
    /// 0 = Sunday … 6 = Saturday (`ShopClock.weekdayIndex`).
    var weekday: Int
    /// "09:00:00"; `closesAt` may be "24:00:00".
    var opensAt: String
    var closesAt: String

    enum CodingKeys: String, CodingKey {
        case weekday
        case opensAt = "opens_at"
        case closesAt = "closes_at"
    }

    static let selectColumns = "weekday,opens_at,closes_at"
}

/// Checks a proposed job time against the shop's hours and what is
/// already booked. Advisory only: the server does not forbid overlaps,
/// so these are warnings the manager can book through.
enum JobAvailability {

    /// Items overlapping the shop-local day(s) the job touches, by start.
    static func dayItems(_ items: [JobBusyItem], start: Date, end: Date, clock: ShopClock) -> [JobBusyItem] {
        let dayStart = clock.startOfDay(start)
        let dayEnd = clock.addingDays(1, to: clock.startOfDay(max(start, end.addingTimeInterval(-1))))
        return items
            .filter { $0.overlaps(start: dayStart, end: dayEnd) }
            .sorted { lhs, rhs in
                if lhs.startsAt != rhs.startsAt { return lhs.startsAt < rhs.startsAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    /// Nil when the time sits inside the shop's hours (or no hours are set
    /// up at all); otherwise a sentence explaining the problem.
    static func hoursProblem(start: Date, end: Date, hours: [JobBusinessHours], clock: ShopClock) -> String? {
        guard !hours.isEmpty else { return nil }
        let weekday = clock.weekdayIndex(start)
        let intervals: [(open: Date, close: Date)] = hours
            .filter { $0.weekday == weekday }
            .compactMap { row in
                guard let open = clock.date(on: start, timeString: row.opensAt),
                      let close = clock.date(on: start, timeString: row.closesAt) else { return nil }
                return (open: open, close: close)
            }
            .sorted { $0.open < $1.open }
        guard !intervals.isEmpty else {
            return "The shop is closed on " + clock.longDayText(start) + "."
        }
        let sameDay = clock.isSameDay(start, end.addingTimeInterval(-1))
        let fits = intervals.contains { interval in
            sameDay
                ? (start >= interval.open && end <= interval.close)
                : (start >= interval.open && start < interval.close)
        }
        if fits { return nil }
        let open = intervals.map { clock.rangeText(from: $0.open, to: $0.close) }.joined(separator: ", ")
        return "Outside business hours (open " + open + ")."
    }

    /// Double bookings for the chosen bay / van and team, and blocked time.
    static func conflicts(
        start: Date,
        end: Date,
        items: [JobBusyItem],
        resourceID: UUID?,
        assigneeIDs: Set<UUID>,
        clock: ShopClock,
        resourceName: (UUID) -> String?,
        memberName: (UUID) -> String?
    ) -> [String] {
        var warnings: [String] = []
        for item in items where item.overlaps(start: start, end: end) {
            let when = clock.rangeText(from: item.startsAt, to: item.endsAt)
            if item.isBlockedTime {
                if let member = item.memberID {
                    if assigneeIDs.contains(member) {
                        let name: String = memberName(member) ?? "A team member"
                        warnings.append("\(name) is blocked \(when).")
                    }
                } else {
                    // Interpolation, not a long `+` chain (Xcode's type
                    // checker times out on those).
                    let title: String? = item.title?.trimmedNonEmpty
                    let reason: String = title.map { " (\($0))" } ?? ""
                    warnings.append("The shop is blocked \(when)\(reason).")
                }
                continue
            }
            let label: String = item.jobNumber.map { "job #\($0)" } ?? "another job"
            if let resourceID, item.resourceID == resourceID {
                let name: String = resourceName(resourceID) ?? "This bay / van"
                warnings.append("\(name) is already booked for \(label), \(when).")
            }
            let shared = item.assignedMemberIDs.filter { assigneeIDs.contains($0) }
            for member in shared {
                let name: String = memberName(member) ?? "A team member"
                warnings.append("\(name) is already on \(label), \(when).")
            }
        }
        return warnings
    }
}
