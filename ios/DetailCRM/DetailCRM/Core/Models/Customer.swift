//
//  Customer.swift
//  DetailCRM
//
//  CRM models (SPEC §4.2): customers, their vehicles and the shop's vehicle
//  size classes, plus the read-only history rows the customer screen shows
//  (jobs, quotes, invoices, memberships). History rows are this feature's
//  own slim projections of tables other features own; money amounts are
//  server-maintained cents and are only displayed, never computed here.
//

import Foundation
import Supabase
import DetailCore

// MARK: - Customer

// table: customers
struct Customer: Codable, Identifiable, Hashable, Sendable {

    /// `customer_lifecycle` enum.
    enum Lifecycle: String, Codable, CaseIterable, Identifiable, Sendable {
        case lead
        case customer

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .lead: return "Lead"
            case .customer: return "Customer"
            }
        }

        var pluralName: String {
            switch self {
            case .lead: return "Leads"
            case .customer: return "Customers"
            }
        }
    }

    /// `customer_source` enum.
    enum Source: String, Codable, CaseIterable, Identifiable, Sendable {
        case staff
        case onlineBooking = "online_booking"
        case referral
        case google
        case facebook
        case instagram
        case walkIn = "walk_in"
        case other
        /// Created by a CSV import (P-5, comms 0087).
        case imported = "import"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .staff: return "Added by staff"
            case .onlineBooking: return "Online booking"
            case .referral: return "Referral"
            case .google: return "Google"
            case .facebook: return "Facebook"
            case .instagram: return "Instagram"
            case .walkIn: return "Walk-in"
            case .other: return "Other"
            case .imported: return "Imported"
            }
        }
    }

    var id: UUID
    var shopID: UUID
    var firstName: String?
    var lastName: String?
    var company: String?
    var email: String?
    /// E.164 (`+12055550123`).
    var phone: String?
    var addressLine1: String?
    var addressLine2: String?
    var city: String?
    var region: String?
    var postalCode: String?
    var country: String?
    var notes: String?
    var tags: [String]
    var lifecycle: Lifecycle
    var source: Source
    var smsOptIn: Bool
    var emailOptIn: Bool
    /// Set when the customer texted STOP (or staff recorded an opt-out).
    /// Blocks every SMS; only the customer can clear it (START).
    var smsOptedOutAt: Date?
    /// Set when the customer unsubscribed (or staff recorded it).
    var emailOptedOutAt: Date?
    var archivedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    /// Answers to the shop's customer fields (P-9): {key: value}, validated
    /// by the server against `custom_fields`.
    var customData: [String: AnyJSON]?
    /// The customer's referral code (P-29), server-set once a referral link
    /// was created for them.
    var referralCode: String?
    /// Set on a duplicate that was merged into another customer (server-set;
    /// the duplicate is archived and its records moved).
    var mergedIntoID: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
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
        case country
        case notes
        case tags
        case lifecycle
        case source
        case smsOptIn = "sms_opt_in"
        case emailOptIn = "email_opt_in"
        case smsOptedOutAt = "sms_opted_out_at"
        case emailOptedOutAt = "email_opted_out_at"
        case archivedAt = "archived_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case customData = "custom_data"
        case referralCode = "referral_code"
        case mergedIntoID = "merged_into_id"
    }

    /// Explicit column list for `.select(...)` (Stripe/portal link columns
    /// and the generated search column are never needed by the app).
    static let selectColumns = [
        "id", "shop_id", "first_name", "last_name", "company", "email", "phone",
        "address_line1", "address_line2", "city", "region", "postal_code", "country",
        "notes", "tags", "lifecycle", "source", "sms_opt_in", "email_opt_in",
        "sms_opted_out_at", "email_opted_out_at", "archived_at", "created_at", "updated_at",
        "custom_data", "referral_code", "merged_into_id",
    ].joined(separator: ",")

    /// "First Last", else the company, else "Unnamed customer" (the database
    /// requires at least one of the three, so the fallback is defensive).
    var displayName: String {
        let person = [firstName, lastName]
            .compactMap { $0?.trimmedNonEmpty }
            .joined(separator: " ")
        if !person.isEmpty { return person }
        return company?.trimmedNonEmpty ?? "Unnamed customer"
    }

    /// Company when it isn't already the display name.
    var secondaryCompany: String? {
        guard let company = company?.trimmedNonEmpty, company != displayName else { return nil }
        return company
    }

    /// Phone formatted for people, e.g. `(205) 555-0123`.
    var formattedPhone: String? {
        phone?.trimmedNonEmpty.map { PhoneNumber.format($0) }
    }

    /// One-line address for display and Maps, if any part is set.
    var addressSummary: String? {
        let cityLine = [city, region, postalCode]
            .compactMap { $0?.trimmedNonEmpty }
            .joined(separator: ", ")
        let parts = [addressLine1?.trimmedNonEmpty, addressLine2?.trimmedNonEmpty, cityLine.nonEmpty]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    var isArchived: Bool { archivedAt != nil }
    var hasSmsOptOut: Bool { smsOptedOutAt != nil }
    var hasEmailOptOut: Bool { emailOptedOutAt != nil }
}

/// Editable customer fields for the add / edit sheet. Encodes every
/// column explicitly (nil as JSON null) so clearing a field on edit really
/// clears it. Opt-out timestamps are only sent when staff record a new
/// opt-out (the server stamps the time and never lets staff clear one).
// table: customers
struct CustomerDraft: Encodable, Equatable, Sendable {
    var firstName: String = ""
    var lastName: String = ""
    var company: String = ""
    var email: String = ""
    var phone: String = ""
    var addressLine1: String = ""
    var addressLine2: String = ""
    var city: String = ""
    var region: String = ""
    var postalCode: String = ""
    var notes: String = ""
    var tags: [String] = []
    var lifecycle: Customer.Lifecycle = .customer
    var source: Customer.Source = .staff
    var smsOptIn: Bool = false
    var emailOptIn: Bool = false
    /// Staff recording a new SMS opt-out (never un-sets one).
    var recordSmsOptOut: Bool = false
    /// Staff recording a new email opt-out (never un-sets one).
    var recordEmailOptOut: Bool = false

    enum CodingKeys: String, CodingKey {
        case shopID = "shop_id"
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
        case notes
        case tags
        case lifecycle
        case source
        case smsOptIn = "sms_opt_in"
        case emailOptIn = "email_opt_in"
        case smsOptedOutAt = "sms_opted_out_at"
        case emailOptedOutAt = "email_opted_out_at"
    }

    init() {}

    init(customer: Customer) {
        firstName = customer.firstName ?? ""
        lastName = customer.lastName ?? ""
        company = customer.company ?? ""
        email = customer.email ?? ""
        phone = customer.phone.map { PhoneNumber.format($0) } ?? ""
        addressLine1 = customer.addressLine1 ?? ""
        addressLine2 = customer.addressLine2 ?? ""
        city = customer.city ?? ""
        region = customer.region ?? ""
        postalCode = customer.postalCode ?? ""
        notes = customer.notes ?? ""
        tags = customer.tags
        lifecycle = customer.lifecycle
        source = customer.source
        smsOptIn = customer.smsOptIn
        emailOptIn = customer.emailOptIn
    }

    // MARK: Validation (mirrors the table's CHECK constraints)

    var hasName: Bool {
        firstName.trimmedNonEmpty != nil || lastName.trimmedNonEmpty != nil || company.trimmedNonEmpty != nil
    }

    /// E.164 phone, nil when empty. Invalid input is reported by `phoneError`.
    var normalizedPhone: String? {
        guard let text = phone.trimmedNonEmpty else { return nil }
        return PhoneNumber.normalize(text)
    }

    var phoneError: String? {
        guard phone.trimmedNonEmpty != nil else { return nil }
        return normalizedPhone == nil ? "Enter a valid phone number, e.g. (205) 555-0123." : nil
    }

    var normalizedEmail: String? {
        guard let text = email.trimmedNonEmpty else { return nil }
        return Validation.normalizedEmail(text)
    }

    var emailError: String? {
        guard let text = email.trimmedNonEmpty else { return nil }
        return Validation.isValidEmail(text) ? nil : "Enter a valid email address."
    }

    var nameError: String? {
        hasName ? nil : "Enter a first name, last name or company."
    }

    /// First problem that blocks saving, if any.
    var validationError: String? {
        if let nameError { return nameError }
        if let phoneError { return phoneError }
        if let emailError { return emailError }
        if [firstName, lastName].contains(where: { $0.count > 100 }) { return "Names are limited to 100 characters." }
        if company.count > 200 { return "Company is limited to 200 characters." }
        if addressLine1.count > 200 || addressLine2.count > 200 { return "Address lines are limited to 200 characters." }
        if city.count > 100 || region.count > 100 { return "City and state are limited to 100 characters." }
        if postalCode.count > 20 { return "Postal code is limited to 20 characters." }
        if tags.count > 50 { return "A customer can have at most 50 tags." }
        return nil
    }

    // MARK: Encoding

    /// Set by the service for inserts only (never sent on update).
    var shopID: UUID?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let shopID {
            try container.encode(shopID, forKey: .shopID)
        }
        try container.encode(firstName.trimmedNonEmpty, forKey: .firstName)
        try container.encode(lastName.trimmedNonEmpty, forKey: .lastName)
        try container.encode(company.trimmedNonEmpty, forKey: .company)
        try container.encode(normalizedEmail, forKey: .email)
        try container.encode(normalizedPhone, forKey: .phone)
        try container.encode(addressLine1.trimmedNonEmpty, forKey: .addressLine1)
        try container.encode(addressLine2.trimmedNonEmpty, forKey: .addressLine2)
        try container.encode(city.trimmedNonEmpty, forKey: .city)
        try container.encode(region.trimmedNonEmpty, forKey: .region)
        try container.encode(postalCode.trimmedNonEmpty, forKey: .postalCode)
        try container.encode(notes.trimmedNonEmpty, forKey: .notes)
        try container.encode(CustomerDraft.cleanTags(tags), forKey: .tags)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encode(source, forKey: .source)
        try container.encode(smsOptIn, forKey: .smsOptIn)
        try container.encode(emailOptIn, forKey: .emailOptIn)
        // Any non-null value records an opt-out; the server stamps now().
        if recordSmsOptOut {
            try container.encode(Supa.iso(Date()), forKey: .smsOptedOutAt)
        }
        if recordEmailOptOut {
            try container.encode(Supa.iso(Date()), forKey: .emailOptedOutAt)
        }
    }

    /// Trimmed, de-duplicated (case-insensitively), non-empty tags in their
    /// original order.
    static func cleanTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            guard let trimmed = tag.trimmedNonEmpty else { continue }
            if seen.insert(trimmed.lowercased()).inserted {
                result.append(trimmed)
            }
        }
        return result
    }
}

// MARK: - Vehicles

// table: vehicles
struct Vehicle: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var customerID: UUID
    var year: Int?
    var make: String?
    var model: String?
    var trim: String?
    var color: String?
    /// Upper case, no spaces (normalized by the database).
    var vin: String?
    var licensePlate: String?
    var categoryID: UUID?
    var notes: String?
    var archivedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case customerID = "customer_id"
        case year
        case make
        case model
        case trim
        case color
        case vin
        case licensePlate = "license_plate"
        case categoryID = "category_id"
        case notes
        case archivedAt = "archived_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    static let selectColumns = [
        "id", "shop_id", "customer_id", "year", "make", "model", "trim", "color", "vin",
        "license_plate", "category_id", "notes", "archived_at", "created_at", "updated_at",
    ].joined(separator: ",")

    /// "2021 Honda Civic Sport", or "Vehicle" when nothing is known.
    var displayName: String {
        let parts: [String] = [
            year.map { String($0) },
            make?.trimmedNonEmpty,
            model?.trimmedNonEmpty,
            trim?.trimmedNonEmpty,
        ].compactMap { $0 }
        return parts.isEmpty ? "Vehicle" : parts.joined(separator: " ")
    }

    /// "Black · ABC123" style details line.
    var detailLine: String? {
        let parts = [color?.trimmedNonEmpty, licensePlate?.trimmedNonEmpty].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Editable vehicle fields. Encodes every column (nil as null) so edits
/// can clear values.
// table: vehicles
struct VehicleDraft: Encodable, Equatable, Sendable {
    var year: String = ""
    var make: String = ""
    var model: String = ""
    var trim: String = ""
    var color: String = ""
    var vin: String = ""
    var licensePlate: String = ""
    var categoryID: UUID?
    var notes: String = ""

    /// Set by the service for inserts only.
    var shopID: UUID?
    var customerID: UUID?

    enum CodingKeys: String, CodingKey {
        case shopID = "shop_id"
        case customerID = "customer_id"
        case year
        case make
        case model
        case trim
        case color
        case vin
        case licensePlate = "license_plate"
        case categoryID = "category_id"
        case notes
    }

    init() {}

    init(vehicle: Vehicle) {
        year = vehicle.year.map { String($0) } ?? ""
        make = vehicle.make ?? ""
        model = vehicle.model ?? ""
        trim = vehicle.trim ?? ""
        color = vehicle.color ?? ""
        vin = vehicle.vin ?? ""
        licensePlate = vehicle.licensePlate ?? ""
        categoryID = vehicle.categoryID
        notes = vehicle.notes ?? ""
    }

    var parsedYear: Int? {
        guard let text = year.trimmedNonEmpty else { return nil }
        return Int(text)
    }

    var normalizedVIN: String? {
        let value = VIN.normalize(vin)
        return value.isEmpty ? nil : value
    }

    var normalizedPlate: String? {
        let value = licensePlate.uppercased().filter { !$0.isWhitespace }
        return value.isEmpty ? nil : value
    }

    var yearError: String? {
        guard year.trimmedNonEmpty != nil else { return nil }
        guard let value = parsedYear, (1886...2100).contains(value) else {
            return "Enter a 4-digit year."
        }
        return nil
    }

    /// The database accepts 5–17 letters/digits (partial VINs for older or
    /// imported vehicles); a full 17-character VIN is checked further by
    /// `VIN.validate` before decoding.
    var vinError: String? {
        guard let value = normalizedVIN else { return nil }
        guard (5...17).contains(value.count), value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return "A VIN uses 5–17 letters and numbers."
        }
        return nil
    }

    var validationError: String? {
        if let yearError { return yearError }
        if let vinError { return vinError }
        if make.count > 60 || model.count > 60 || trim.count > 60 { return "Make, model and trim are limited to 60 characters." }
        if color.count > 40 { return "Color is limited to 40 characters." }
        if (normalizedPlate?.count ?? 0) > 15 { return "License plate is limited to 15 characters." }
        let hasSomething = parsedYear != nil || make.trimmedNonEmpty != nil || model.trimmedNonEmpty != nil
            || normalizedVIN != nil || normalizedPlate != nil
        return hasSomething ? nil : "Enter at least a make, model, VIN or plate."
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let shopID { try container.encode(shopID, forKey: .shopID) }
        if let customerID { try container.encode(customerID, forKey: .customerID) }
        try container.encode(parsedYear, forKey: .year)
        try container.encode(make.trimmedNonEmpty, forKey: .make)
        try container.encode(model.trimmedNonEmpty, forKey: .model)
        try container.encode(trim.trimmedNonEmpty, forKey: .trim)
        try container.encode(color.trimmedNonEmpty, forKey: .color)
        try container.encode(normalizedVIN, forKey: .vin)
        try container.encode(normalizedPlate, forKey: .licensePlate)
        try container.encode(categoryID, forKey: .categoryID)
        try container.encode(notes.trimmedNonEmpty, forKey: .notes)
    }
}

// table: vehicle_categories
struct VehicleCategory: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var name: String
    var sort: Int

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case name
        case sort
    }

    static let selectColumns = "id,shop_id,name,sort"
}

// MARK: - Customer history (read-only projections)

// table: jobs
struct CustomerJobSummary: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var number: Int
    var status: JobStatus
    var scheduledStart: Date?
    var scheduledEnd: Date?
    var vehicleID: UUID?
    var totalCents: Int
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case status
        case scheduledStart = "scheduled_start"
        case scheduledEnd = "scheduled_end"
        case vehicleID = "vehicle_id"
        case totalCents = "total_cents"
        case createdAt = "created_at"
    }

    static let selectColumns = "id,number,status,scheduled_start,scheduled_end,vehicle_id,total_cents,created_at"
}

// table: quotes
struct CustomerQuoteSummary: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var number: Int
    var status: QuoteStatus
    /// `yyyy-MM-dd` (a Postgres `date`, valid through that shop-local day).
    var validUntil: String?
    var totalCents: Int
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case status
        case validUntil = "valid_until"
        case totalCents = "total_cents"
        case createdAt = "created_at"
    }

    static let selectColumns = "id,number,status,valid_until,total_cents,created_at"
}

// table: invoices
struct CustomerInvoiceSummary: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var number: Int
    var status: InvoiceStatus
    var issuedAt: Date?
    var dueAt: Date?
    var totalCents: Int
    var balanceCents: Int
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case status
        case issuedAt = "issued_at"
        case dueAt = "due_at"
        case totalCents = "total_cents"
        case balanceCents = "balance_cents"
        case createdAt = "created_at"
    }

    static let selectColumns = "id,number,status,issued_at,due_at,total_cents,balance_cents,created_at"
}

// table: memberships
/// A customer's membership. `priceCents`, `interval` and `intervalCount` are
/// the billing terms of THIS membership (copied from the plan at checkout and
/// kept when the plan's price later changes), so they are what the customer is
/// actually billed; the plan is only used for its name.
struct CustomerMembershipSummary: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var planID: UUID
    var vehicleID: UUID?
    var status: MembershipStatus
    var priceCents: Int
    /// `week` | `month` | `year` (`membership_interval`)
    var interval: String
    var intervalCount: Int
    var currentPeriodEnd: Date?
    var cancelAtPeriodEnd: Bool
    var startedAt: Date?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case planID = "plan_id"
        case vehicleID = "vehicle_id"
        case status
        case priceCents = "price_cents"
        case interval
        case intervalCount = "interval_count"
        case currentPeriodEnd = "current_period_end"
        case cancelAtPeriodEnd = "cancel_at_period_end"
        case startedAt = "started_at"
        case createdAt = "created_at"
    }

    static let selectColumns = "id,plan_id,vehicle_id,status,price_cents,interval,interval_count,current_period_end,cancel_at_period_end,started_at,created_at"

    /// "per week", "every 2 weeks", "per month", "every 3 months", "per year".
    /// An interval this build doesn't know yet shows no cadence rather
    /// than a wrong one.
    var cadenceText: String {
        MembershipPlanInterval(rawValue: interval)?.billingText(count: intervalCount) ?? ""
    }
}

// table: membership_plans
/// Only the plan's name: its current price/cadence may differ from what an
/// existing membership is billed (see `CustomerMembershipSummary`).
struct CustomerMembershipPlanRef: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String

    static let selectColumns = "id,name"
}

/// A membership joined with its plan for display.
struct CustomerMembershipItem: Identifiable, Hashable, Sendable {
    var membership: CustomerMembershipSummary
    var plan: CustomerMembershipPlanRef?

    var id: UUID { membership.id }
}

// MARK: - Overview (customer_summary)

/// Server-computed overview of one customer (manager+). Money is derived
/// by the server: lifetime paid is net of refunds and excludes tips.
// rpc: customer_summary
struct CustomerSummary: Codable, Hashable, Sendable {
    var customerID: UUID
    var lifetimePaidCents: Int
    var tipsCents: Int
    var refundedCents: Int
    var openBalanceCents: Int
    var overdueBalanceCents: Int
    var completedJobs: Int
    var upcomingJobs: Int
    var firstVisitAt: Date?
    var lastVisitAt: Date?
    var nextJobAt: Date?
    var openQuotes: Int
    var activeMemberships: Int

    enum CodingKeys: String, CodingKey {
        case customerID = "customer_id"
        case lifetimePaidCents = "lifetime_paid_cents"
        case tipsCents = "tips_cents"
        case refundedCents = "refunded_cents"
        case openBalanceCents = "open_balance_cents"
        case overdueBalanceCents = "overdue_balance_cents"
        case completedJobs = "completed_jobs"
        case upcomingJobs = "upcoming_jobs"
        case firstVisitAt = "first_visit_at"
        case lastVisitAt = "last_visit_at"
        case nextJobAt = "next_job_at"
        case openQuotes = "open_quotes"
        case activeMemberships = "active_memberships"
    }
}
