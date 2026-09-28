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
    /// The proposal option the customer chose (P-15); nil until then (the
    /// lowest-sort option is counted meanwhile).
    var selectedOptionID: UUID?
    /// The customer may schedule this quote online once approved (P-16;
    /// the shop's booking settings must allow it too).
    var selfSchedule: Bool
    /// When the customer scheduled it on the quote page (server-set).
    var selfScheduledAt: Date?
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
        case selectedOptionID = "selected_option_id"
        case selfSchedule = "self_schedule"
        case selfScheduledAt = "self_scheduled_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    static let selectColumns = [
        "id", "shop_id", "number", "customer_id", "vehicle_id", "status", "valid_until",
        "notes", "terms", "internal_notes", "discount_kind", "discount_value", "tax_rate_bps",
        "subtotal_cents", "discount_cents", "tax_cents", "total_cents", "public_token",
        "sent_at", "viewed_at", "approved_at", "approved_by_name", "declined_at",
        "declined_reason", "expired_at", "converted_at", "converted_job_id",
        "selected_option_id", "self_schedule", "self_scheduled_at",
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

    /// The option the quote's totals count: the customer's choice, else the
    /// first option (lowest sort) — `quote_effective_option` on the server.
    func effectiveOptionID(options: [MoneyQuoteOption]) -> UUID? {
        if let selectedOptionID, options.contains(where: { $0.id == selectedOptionID }) {
            return selectedOptionID
        }
        return MoneyQuoteOption.ordered(options).first?.id
    }

    /// Whether a line counts toward the quote total: shared or of the
    /// effective option, and (for optional upsells) picked.
    func counts(_ line: QuoteLineItem, effectiveOptionID: UUID?) -> Bool {
        guard !line.isOptional || line.isSelected else { return false }
        guard let optionID = line.optionID else { return true }
        return optionID == effectiveOptionID
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
    /// The quote's document discount applies to this line (default true).
    var discountEligible: Bool
    /// The proposal option this line belongs to; nil = shared by every option.
    var optionID: UUID?
    /// A preset fee line (`shop_fees`), added with `add_fee_line`.
    var feeID: UUID?
    var membershipID: UUID?
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
        case discountEligible = "discount_eligible"
        case optionID = "option_id"
        case feeID = "fee_id"
        case membershipID = "membership_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    static let selectColumns = [
        "id", "shop_id", "quote_id", "service_id", "vehicle_id", "name", "description",
        "quantity", "unit_price_cents", "discount_cents", "taxable", "duration_minutes",
        "optional", "selected", "sort", "total_cents", "discount_eligible", "option_id",
        "fee_id", "membership_id", "created_at", "updated_at",
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
    /// The builder option (`MoneyQuoteOption.Draft.localID`) this line
    /// belongs to; nil = shared by every option.
    var optionLocalID: UUID?
    /// A preset fee line. New fee lines are added by `add_fee_line` on save,
    /// so the server prices them.
    var feeID: UUID?
    /// A new fee line nobody edited yet: saved exactly as the server adds it
    /// (only its place and option are set afterwards).
    var feeIsPristine: Bool = false
    /// `add_fee_line`'s request nonce for this line (0095): made once, when
    /// the fee is added to the draft, and sent by every save that adds it —
    /// a save retried after a lost response gets the same line back instead
    /// of a second fee.
    var feeRequestNonce: String = UUID().uuidString
    /// Kept from the saved line (the server's value); preview only.
    var discountEligible: Bool = true
    /// The option the saved row is on right now (nil = shared, or not
    /// saved yet). A save uses it to take kept lines off an option before
    /// that option is deleted (the delete cascades to its lines).
    var savedOptionID: UUID?

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
        pricingNote: String? = nil,
        optionLocalID: UUID? = nil,
        feeID: UUID? = nil,
        discountEligible: Bool = true
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
        self.optionLocalID = optionLocalID
        self.feeID = feeID
        self.discountEligible = discountEligible
    }

    /// A new line for a preset fee (priced by the server when saved).
    init(fee: JobsShopFee, optionLocalID: UUID?) {
        self.init(
            name: fee.name,
            unitPriceCents: fee.amountCents,
            taxable: fee.taxable,
            optionLocalID: optionLocalID,
            feeID: fee.id
        )
        self.feeIsPristine = true
    }

    init(line: QuoteLineItem, optionLocalID: UUID?) {
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
            isSelected: line.isSelected,
            optionLocalID: optionLocalID,
            feeID: line.feeID,
            discountEligible: line.discountEligible
        )
        self.savedOptionID = line.optionID
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
            isSelected: isOptional ? isSelected : true,
            discountEligible: discountEligible
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
    /// Proposal options (P-15), in display order; empty = a plain quote.
    var options: [MoneyQuoteOption.Draft] = []
    /// Option ids that were saved when editing began (to delete removed ones).
    var originalOptionIDs: [UUID] = []
    /// The customer's choice (saved quotes), kept for the preview.
    var selectedOptionID: UUID?
    /// Ids of option / line inserts whose outcome is unknown (the request
    /// failed, perhaps after the server committed it). The next save checks
    /// which exist before inserting anything, so a retry never duplicates.
    var unconfirmedInsertIDs: Set<UUID> = []

    init() {}

    init(
        quote: Quote,
        lines: [QuoteLineItem],
        options: [MoneyQuoteOption] = [],
        customer: QuoteCustomerRef?,
        vehicle: QuoteVehicleRef?
    ) {
        self.quoteID = quote.id
        self.customer = customer
        self.vehicle = vehicle
        let drafts = MoneyQuoteOption.ordered(options).map { MoneyQuoteOption.Draft(option: $0) }
        var localByID: [UUID: UUID] = [:]
        for draft in drafts {
            if let id = draft.id { localByID[id] = draft.localID }
        }
        self.options = drafts
        self.originalOptionIDs = drafts.compactMap { $0.id }
        self.selectedOptionID = quote.selectedOptionID
        self.lines = lines.map { line in
            QuoteDraftLine(line: line, optionLocalID: line.optionID.flatMap { localByID[$0] })
        }
        self.discountKind = quote.discountKind
        self.discountValue = quote.discountValue
        self.validUntil = quote.validUntil
        self.notes = quote.notes ?? ""
        self.terms = quote.terms ?? ""
        self.internalNotes = quote.internalNotes ?? ""
        self.taxRateBps = quote.taxRateBps
        self.originalLineIDs = lines.map { $0.id }
    }

    /// The option the quote total counts (the customer's choice, else the
    /// first option); nil for a quote without options.
    var effectiveOptionLocalID: UUID? {
        if let selectedOptionID, let chosen = options.first(where: { $0.id == selectedOptionID }) {
            return chosen.localID
        }
        return options.first?.localID
    }

    /// Lines shown for one builder segment: the shared lines (nil) or one
    /// option's own lines.
    func lines(inSegment optionLocalID: UUID?) -> [QuoteDraftLine] {
        lines.filter { $0.optionLocalID == optionLocalID }
    }

    /// Client-side estimate for the builder (labelled as such in the UI):
    /// shared lines plus the counted option's lines, like the server.
    var previewTotals: DocumentTotals {
        previewTotals(forOption: effectiveOptionLocalID)
    }

    /// Estimate for one option (shared lines + that option's lines, same
    /// discount and tax). With no options every line is shared.
    func previewTotals(forOption optionLocalID: UUID?) -> DocumentTotals {
        let counted = lines.filter { $0.optionLocalID == nil || $0.optionLocalID == optionLocalID }
        return DocumentTotals(
            lines: counted.map { $0.totalsLine },
            discount: discountKind.documentDiscount(value: discountValue),
            taxRateBps: taxRateBps
        )
    }
}

// MARK: - Saving the draft (retry-safe)

extension QuoteDraft {

    /// The requests one save makes against one quote. QuoteService supplies
    /// the Supabase ones; keeping them apart lets the order and the
    /// bookkeeping in `applyEdits(using:)` be exercised without a server.
    struct SaveRequests {
        /// Of `ids`, the quote's options that exist.
        var existingOptionIDs: (_ ids: [UUID]) async throws -> Set<UUID>
        /// Of `ids`, the quote's lines that exist, with their option.
        var existingLines: (_ ids: [UUID]) async throws -> [SavedLineRef]
        var deleteLines: (_ ids: [UUID]) async throws -> Void
        var deleteOptions: (_ ids: [UUID]) async throws -> Void
        var updateOption: (_ id: UUID, _ option: MoneyQuoteOption.Draft, _ sort: Int) async throws -> Void
        /// Inserts an option with the id chosen here.
        var insertOption: (_ id: UUID, _ option: MoneyQuoteOption.Draft, _ sort: Int) async throws -> Void
        /// Updates a saved line. `placementOnly` writes just its sort and
        /// option (a preset-fee line nobody edited keeps the server's
        /// pricing).
        var updateLine: (_ id: UUID, _ line: QuoteDraftLine, _ sort: Int, _ optionID: UUID?, _ placementOnly: Bool) async throws -> Void
        /// Inserts custom lines (one request) with the ids chosen here.
        var insertLines: (_ lines: [NewLine]) async throws -> Void
        /// `add_fee_line`: the server adds and prices the fee; returns the
        /// new line's id. `nonce` is the line's `feeRequestNonce` (a retry
        /// returns the line the first call added).
        var addFeeLine: (_ feeID: UUID, _ nonce: String) async throws -> UUID
        /// Writes the quote's own fields.
        var updateQuote: () async throws -> Void
    }

    /// A saved line found while confirming an uncertain insert.
    struct SavedLineRef: Hashable, Sendable {
        var id: UUID
        var optionID: UUID?
    }

    /// A custom line to insert.
    struct NewLine: Hashable, Sendable {
        var id: UUID
        var line: QuoteDraftLine
        var sort: Int
        var optionID: UUID?
    }

    /// Saved lines the builder removed.
    var removedLineIDs: [UUID] {
        let kept = Set(lines.compactMap { $0.id })
        return originalLineIDs.filter { !kept.contains($0) }
    }

    /// Saved options the builder removed.
    var removedOptionIDs: [UUID] {
        let kept = Set(options.compactMap { $0.id })
        return originalOptionIDs.filter { !kept.contains($0) }
    }

    /// Brings the server in line with the draft, one request at a time, and
    /// records every row it creates or deletes in the draft as it goes
    /// (ids, `originalLineIDs` / `originalOptionIDs`). When a request fails
    /// the draft still says what is on the server, so saving it again
    /// finishes the job instead of adding the same options and lines twice.
    ///
    /// Order: removed lines go first, then the removed options (kept lines
    /// are taken off them first, as deleting an option deletes its lines),
    /// so a replaced option never trips the 4-option limit; then options,
    /// saved lines, the quote, new lines and new fee lines.
    mutating func applyEdits(using requests: SaveRequests) async throws {
        try await confirmUncertainInserts(using: requests)

        let removedLines = removedLineIDs
        if !removedLines.isEmpty {
            try await requests.deleteLines(removedLines)
            let gone = Set(removedLines)
            originalLineIDs.removeAll { gone.contains($0) }
        }

        // Lines (by localID) already written with their final place.
        var placed = Set<UUID>()
        let removedOptions = removedOptionIDs
        if !removedOptions.isEmpty {
            let gone = Set(removedOptions)
            let savedOptionIDs = savedOptionIDsByLocalID
            for index in lines.indices {
                let line = lines[index]
                guard let id = line.id, let current = line.savedOptionID, gone.contains(current) else { continue }
                // Its option is saved (or it becomes shared): final place.
                // Its option is new: shared until that option exists.
                let target = line.optionLocalID.flatMap { savedOptionIDs[$0] }
                try await requests.updateLine(id, line, index + 1, target, line.feeIsPristine)
                lines[index].savedOptionID = target
                if line.optionLocalID == nil || target != nil {
                    placed.insert(line.localID)
                }
            }
            try await requests.deleteOptions(removedOptions)
            originalOptionIDs.removeAll { gone.contains($0) }
        }

        for index in options.indices {
            let option = options[index]
            if let id = option.id {
                try await requests.updateOption(id, option, index + 1)
            } else {
                let id = option.localID
                unconfirmedInsertIDs.insert(id)
                try await requests.insertOption(id, option, index + 1)
                unconfirmedInsertIDs.remove(id)
                options[index].id = id
                originalOptionIDs.append(id)
            }
        }
        let optionIDs = savedOptionIDsByLocalID

        // Lines carry no vehicle of their own (the quote's applies), so they
        // go before the quote: a customer change can't trip the "line
        // vehicle belongs to the customer" check.
        for index in lines.indices {
            let line = lines[index]
            guard let id = line.id, !placed.contains(line.localID) else { continue }
            let optionID = line.optionLocalID.flatMap { optionIDs[$0] }
            try await requests.updateLine(id, line, index + 1, optionID, line.feeIsPristine)
            lines[index].savedOptionID = optionID
        }

        try await requests.updateQuote()

        var inserts: [NewLine] = []
        for (index, line) in lines.enumerated() where line.id == nil && line.feeID == nil {
            inserts.append(NewLine(
                id: line.localID,
                line: line,
                sort: index + 1,
                optionID: line.optionLocalID.flatMap { optionIDs[$0] }
            ))
        }
        if !inserts.isEmpty {
            let ids = inserts.map { $0.id }
            unconfirmedInsertIDs.formUnion(ids)
            try await requests.insertLines(inserts)
            unconfirmedInsertIDs.subtract(ids)
            let byID = Dictionary(inserts.map { ($0.id, $0.optionID) }, uniquingKeysWith: { first, _ in first })
            for index in lines.indices where lines[index].id == nil && lines[index].feeID == nil {
                let id = lines[index].localID
                guard let optionID = byID[id] else { continue }
                lines[index].id = id
                lines[index].savedOptionID = optionID
                originalLineIDs.append(id)
            }
        }

        // Preset fees are added (and priced) by the server, then placed.
        for index in lines.indices {
            guard lines[index].id == nil, let feeID = lines[index].feeID else { continue }
            let id = try await requests.addFeeLine(feeID, lines[index].feeRequestNonce)
            lines[index].id = id
            lines[index].savedOptionID = nil
            originalLineIDs.append(id)
            let line = lines[index]
            let optionID = line.optionLocalID.flatMap { optionIDs[$0] }
            try await requests.updateLine(id, line, index + 1, optionID, line.feeIsPristine)
            lines[index].savedOptionID = optionID
        }
    }

    /// Saved option ids by builder `localID`.
    private var savedOptionIDsByLocalID: [UUID: UUID] {
        var ids: [UUID: UUID] = [:]
        for option in options {
            if let id = option.id { ids[option.localID] = id }
        }
        return ids
    }

    /// Marks the uncertain inserts that did reach the server as saved (rows
    /// the builder no longer has are then deleted like any removed row).
    private mutating func confirmUncertainInserts(using requests: SaveRequests) async throws {
        guard !unconfirmedInsertIDs.isEmpty else { return }
        let ids = Array(unconfirmedInsertIDs)
        let foundOptions = try await requests.existingOptionIDs(ids)
        let foundLines = try await requests.existingLines(ids)
        for id in foundOptions {
            if let index = options.firstIndex(where: { $0.id == nil && $0.localID == id }) {
                options[index].id = id
            }
            if !originalOptionIDs.contains(id) { originalOptionIDs.append(id) }
        }
        for found in foundLines {
            if let index = lines.firstIndex(where: { $0.id == nil && $0.localID == found.id }) {
                lines[index].id = found.id
                lines[index].savedOptionID = found.optionID
            }
            if !originalLineIDs.contains(found.id) { originalLineIDs.append(found.id) }
        }
        unconfirmedInsertIDs = []
    }

    /// Takes what a failed save recorded (quote id, saved rows) into this
    /// draft, matching options and lines by `localID`, so the next save
    /// continues where that one stopped. Edits made meanwhile are kept.
    mutating func adoptSaveProgress(from saved: QuoteDraft) {
        quoteID = saved.quoteID
        originalLineIDs = saved.originalLineIDs
        originalOptionIDs = saved.originalOptionIDs
        unconfirmedInsertIDs = saved.unconfirmedInsertIDs
        var optionIDs: [UUID: UUID] = [:]
        for option in saved.options {
            if let id = option.id { optionIDs[option.localID] = id }
        }
        for index in options.indices where options[index].id == nil {
            options[index].id = optionIDs[options[index].localID]
        }
        var savedLines: [UUID: QuoteDraftLine] = [:]
        for line in saved.lines {
            savedLines[line.localID] = line
        }
        for index in lines.indices {
            guard let savedLine = savedLines[lines[index].localID], let id = savedLine.id else { continue }
            lines[index].id = id
            lines[index].savedOptionID = savedLine.savedOptionID
        }
    }
}
