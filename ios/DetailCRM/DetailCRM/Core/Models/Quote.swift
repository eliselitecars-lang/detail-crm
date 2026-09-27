//
//  Quote.swift
//  DetailCRM
//
//  Quotes and their line items (SPEC §4.5), plus the lightweight customer /
//  vehicle / service lookups the quote builder (and the other money screens)
//  use. Totals are always the server's (`quotes_compute_totals`); the app
//  only shows clearly-labelled previews while editing.
//

import Foundation
import DetailCore

/// `discount_kind`: none | percent (value in basis points) | fixed (cents).
/// Shared by quotes and invoices.
enum MoneyDiscountKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case none
    case percent
    case fixed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "No discount"
        case .percent: return "Percent"
        case .fixed: return "Amount"
        }
    }

    /// The DetailCore discount used for totals previews.
    func documentDiscount(value: Int) -> DocumentDiscount {
        DocumentDiscount(kind: rawValue, value: value)
    }
}

// table: quotes
struct Quote: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var number: Int
    var customerID: UUID
    var vehicleID: UUID?
    var status: QuoteStatus
    /// Postgres `date` (`yyyy-MM-dd`): valid through the end of this day in
    /// the shop's time zone; nil = no expiry.
    var validUntil: String?
    var notes: String?
    var terms: String?
    var internalNotes: String?
    var discountKind: MoneyDiscountKind
    var discountValue: Int
    var taxRateBps: Int
    var subtotalCents: Int
    var discountCents: Int
    var taxCents: Int
    var totalCents: Int
    var publicToken: UUID
    var sentAt: Date?
    var viewedAt: Date?
    var approvedAt: Date?
    var approvedByName: String?
    var declinedAt: Date?
    var declinedReason: String?
    var expiredAt: Date?
    var convertedAt: Date?
    var convertedJobID: UUID?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case number
        case customerID = "customer_id"
        case vehicleID = "vehicle_id"
        case status
        case validUntil = "valid_until"
        case notes
        case terms
        case internalNotes = "internal_notes"
        case discountKind = "discount_kind"
        case discountValue = "discount_value"
        case taxRateBps = "tax_rate_bps"
        case subtotalCents = "subtotal_cents"
        case discountCents = "discount_cents"
        case taxCents = "tax_cents"
        case totalCents = "total_cents"
        case publicToken = "public_token"
        case sentAt = "sent_at"
        case viewedAt = "viewed_at"
        case approvedAt = "approved_at"
        case approvedByName = "approved_by_name"
        case declinedAt = "declined_at"
        case declinedReason = "declined_reason"
        case expiredAt = "expired_at"
        case convertedAt = "converted_at"
        case convertedJobID = "converted_job_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    static let selectColumns = [
        "id", "shop_id", "number", "customer_id", "vehicle_id", "status", "valid_until",
        "notes", "terms", "internal_notes", "discount_kind", "discount_value", "tax_rate_bps",
        "subtotal_cents", "discount_cents", "tax_cents", "total_cents", "public_token",
        "sent_at", "viewed_at", "approved_at", "approved_by_name", "declined_at",
        "declined_reason", "expired_at", "converted_at", "converted_job_id",
        "created_at", "updated_at",
    ].joined(separator: ",")

    /// "Quote #1042"
    var title: String { "Quote #\(number)" }

    /// Staff may edit content while the customer has not answered.
    var isEditable: Bool { status.isEditable }

    /// sent / viewed / approved / declined / expired can be revised back to draft.
    var canReviseToDraft: Bool {
        status == .sent || status == .viewed || status == .approved
            || status == .declined || status == .expired
    }
}

// table: quote_line_items
struct QuoteLineItem: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var quoteID: UUID
    var serviceID: UUID?
    var vehicleID: UUID?
    var name: String
    var lineDescription: String?
    /// `numeric(10,2)`.
    var quantity: Decimal
    var unitPriceCents: Int
    var discountCents: Int
    var taxable: Bool
    var durationMinutes: Int
    /// Optional upsell the customer may pick when approving.
    var isOptional: Bool
    /// Counts toward totals (always true for non-optional lines).
    var isSelected: Bool
    var sort: Int
    /// Generated column: round(quantity × unit price) − discount.
    var totalCents: Int?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case quoteID = "quote_id"
        case serviceID = "service_id"
        case vehicleID = "vehicle_id"
        case name
        case lineDescription = "description"
        case quantity
        case unitPriceCents = "unit_price_cents"
        case discountCents = "discount_cents"
        case taxable
        case durationMinutes = "duration_minutes"
        case isOptional = "optional"
        case isSelected = "selected"
        case sort
        case totalCents = "total_cents"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    static let selectColumns = [
        "id", "shop_id", "quote_id", "service_id", "vehicle_id", "name", "description",
        "quantity", "unit_price_cents", "discount_cents", "taxable", "duration_minutes",
        "optional", "selected", "sort", "total_cents", "created_at", "updated_at",
    ].joined(separator: ",")
}

// MARK: - Lookups (lightweight, money-screen specific)

// table: customers
struct QuoteCustomerRef: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var firstName: String?
    var lastName: String?
    var company: String?
    var email: String?
    var phone: String?
    var archivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case company
        case email
        case phone
        case archivedAt = "archived_at"
    }

    static let selectColumns = "id,first_name,last_name,company,email,phone,archived_at"

    /// "Ana Ruiz", else the company, else the email / phone.
    var displayName: String {
        let person = [firstName, lastName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !person.isEmpty { return person }
        if let company = company?.trimmedNonEmpty { return company }
        if let email = email?.trimmedNonEmpty { return email }
        if let phone = phone?.trimmedNonEmpty { return phone }
        return "Unnamed customer"
    }

    /// Secondary line for pickers: company / email / phone.
    var detailLine: String? {
        let parts = [company, email, phone]
            .compactMap { $0?.trimmedNonEmpty }
            .filter { $0 != displayName }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// table: vehicles
struct QuoteVehicleRef: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var customerID: UUID
    var year: Int?
    var make: String?
    var model: String?
    var trim: String?
    var color: String?
    var licensePlate: String?
    var categoryID: UUID?
    var archivedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case customerID = "customer_id"
        case year
        case make
        case model
        case trim
        case color
        case licensePlate = "license_plate"
        case categoryID = "category_id"
        case archivedAt = "archived_at"
    }

    static let selectColumns = "id,customer_id,year,make,model,trim,color,license_plate,category_id,archived_at"

    /// "2021 Toyota RAV4 XLE", or "Vehicle" when nothing is filled in.
    var displayName: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        for value in [make, model, trim] {
            if let text = value?.trimmedNonEmpty { parts.append(text) }
        }
        return parts.isEmpty ? "Vehicle" : parts.joined(separator: " ")
    }

    /// Color and plate, when known.
    var detailLine: String? {
        let parts = [color, licensePlate].compactMap { $0?.trimmedNonEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// table: services
struct QuoteServiceOption: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// `service_kind`: service | package | addon | product.
    var kind: String
    var categoryID: UUID?
    var taxable: Bool
    var durationMinutes: Int
    var active: Bool
    var sort: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case categoryID = "category_id"
        case taxable
        case durationMinutes = "duration_minutes"
        case active
        case sort
    }

    static let selectColumns = "id,name,kind,category_id,taxable,duration_minutes,active,sort"

    var kindLabel: String {
        switch kind {
        case "package": return "Package"
        case "addon": return "Add-on"
        case "product": return "Product"
        default: return "Service"
        }
    }
}

// MARK: - Catalog pricing (price_services)

// rpc: price_services
struct QuotePricing: Codable, Hashable, Sendable {
    var vehicleCategoryID: UUID?
    var taxRateBps: Int
    /// Every line has a catalog price for this vehicle category.
    var priced: Bool?
    var lines: [QuotePricedLine]
    var suggestedDiscountKind: MoneyDiscountKind?
    var suggestedDiscountValue: Int?

    enum CodingKeys: String, CodingKey {
        case vehicleCategoryID = "vehicle_category_id"
        case taxRateBps = "tax_rate_bps"
        case priced
        case lines
        case suggestedDiscountKind = "suggested_discount_kind"
        case suggestedDiscountValue = "suggested_discount_value"
    }
}

// rpc: price_services
struct QuotePricedLine: Codable, Hashable, Sendable {
    var serviceID: UUID
    var name: String
    var kind: String
    var taxable: Bool
    var durationMinutes: Int?
    var catalogPriceCents: Int?
    /// Price to charge (0 when included with an active membership); nil
    /// when the catalog has no price for this vehicle category.
    var unitPriceCents: Int?
    var membershipIncluded: Bool
    var note: String?

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
}

// rpc: convert_quote_to_job
struct QuoteConvertedJob: Codable, Hashable, Sendable {
    var id: UUID
    var number: Int

    enum CodingKeys: String, CodingKey {
        case id
        case number
    }
}

// MARK: - Builder draft (client-side only; never sent as totals)

/// One line while the quote is being edited. `id` is the saved row's id
/// (nil for new lines); `localID` keeps SwiftUI identity stable (use
/// `ForEach(lines, id: \.localID)`).
struct QuoteDraftLine: Hashable, Sendable {
    var localID = UUID()
    var id: UUID?
    var serviceID: UUID?
    var name: String
    var lineDescription: String?
    var quantity: Decimal = 1
    var unitPriceCents: Int
    var discountCents: Int = 0
    var taxable: Bool = true
    var durationMinutes: Int = 0
    var isOptional: Bool = false
    /// Kept for saved optional lines (the customer's pick); new optional
    /// lines start unselected.
    var isSelected: Bool = false
    /// Informational note from pricing (e.g. "Included with … membership").
    var pricingNote: String?

    init(
        id: UUID? = nil,
        serviceID: UUID? = nil,
        name: String,
        lineDescription: String? = nil,
        quantity: Decimal = 1,
        unitPriceCents: Int,
        discountCents: Int = 0,
        taxable: Bool = true,
        durationMinutes: Int = 0,
        isOptional: Bool = false,
        isSelected: Bool = false,
        pricingNote: String? = nil
    ) {
        self.id = id
        self.serviceID = serviceID
        self.name = name
        self.lineDescription = lineDescription
        self.quantity = quantity
        self.unitPriceCents = unitPriceCents
        self.discountCents = discountCents
        self.taxable = taxable
        self.durationMinutes = durationMinutes
        self.isOptional = isOptional
        self.isSelected = isSelected
        self.pricingNote = pricingNote
    }

    init(line: QuoteLineItem) {
        self.init(
            id: line.id,
            serviceID: line.serviceID,
            name: line.name,
            lineDescription: line.lineDescription,
            quantity: line.quantity,
            unitPriceCents: line.unitPriceCents,
            discountCents: line.discountCents,
            taxable: line.taxable,
            durationMinutes: line.durationMinutes,
            isOptional: line.isOptional,
            isSelected: line.isSelected
        )
    }

    /// For the preview only: optional lines count only when selected, the
    /// same rule the server applies.
    var totalsLine: TotalsLine {
        TotalsLine(
            quantity: quantity,
            unitPriceCents: unitPriceCents,
            discountCents: discountCents,
            taxable: taxable,
            isOptional: isOptional,
            isSelected: isOptional ? isSelected : true
        )
    }
}

/// Everything the builder edits. Converted to insert/update payloads by
/// QuoteService (which never sends totals).
struct QuoteDraft: Hashable, Sendable {
    var quoteID: UUID?
    var customer: QuoteCustomerRef?
    var vehicle: QuoteVehicleRef?
    var lines: [QuoteDraftLine] = []
    var discountKind: MoneyDiscountKind = .none
    /// Basis points for percent, cents for fixed.
    var discountValue: Int = 0
    /// Shop-local `yyyy-MM-dd`, or nil for no expiry.
    var validUntil: String?
    var notes: String = ""
    var terms: String = ""
    var internalNotes: String = ""
    /// Tax rate of the saved quote (preview only); the shop's rate for new ones.
    var taxRateBps: Int = 0
    /// Line ids that were saved when editing began (to delete removed ones).
    var originalLineIDs: [UUID] = []

    init() {}

    init(quote: Quote, lines: [QuoteLineItem], customer: QuoteCustomerRef?, vehicle: QuoteVehicleRef?) {
        self.quoteID = quote.id
        self.customer = customer
        self.vehicle = vehicle
        self.lines = lines.map { QuoteDraftLine(line: $0) }
        self.discountKind = quote.discountKind
        self.discountValue = quote.discountValue
        self.validUntil = quote.validUntil
        self.notes = quote.notes ?? ""
        self.terms = quote.terms ?? ""
        self.internalNotes = quote.internalNotes ?? ""
        self.taxRateBps = quote.taxRateBps
        self.originalLineIDs = lines.map { $0.id }
    }

    /// Client-side estimate for the builder (labelled as such in the UI).
    var previewTotals: DocumentTotals {
        DocumentTotals(
            lines: lines.map { $0.totalsLine },
            discount: discountKind.documentDiscount(value: discountValue),
            taxRateBps: taxRateBps
        )
    }
}
