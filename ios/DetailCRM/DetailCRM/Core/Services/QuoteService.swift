//
//  QuoteService.swift
//  DetailCRM
//
//  Quotes (owner/admin/manager only — RLS `is_shop_manager`). Totals are
//  computed by the database triggers; this service never sends totals.
//  Status moves: draft → sent via `mark_quote_sent`; staff may record an
//  approval / decline or revise back to draft with a direct update (the
//  status machine trigger validates it); approved → converted via
//  `convert_quote_to_job`.
//

import Foundation
import Supabase
import DetailCore

enum QuoteService {

    // MARK: - Lists

    struct ListData: Sendable {
        var quotes: [Quote]
        var customers: [UUID: QuoteCustomerRef]
        /// More (older) quotes match beyond the rows loaded so far.
        var hasMore: Bool = false

        /// Appends the next page (skipping rows already shown).
        func appending(_ page: ListData) -> ListData {
            let known = Set(quotes.map { $0.id })
            var merged = self
            merged.quotes += page.quotes.filter { !known.contains($0.id) }
            merged.customers.merge(page.customers) { current, _ in current }
            merged.hasMore = page.hasMore
            return merged
        }
    }

    /// Rows per list page ("Load more" fetches the next page).
    static let listPageSize = 100

    /// Quotes, newest first, optionally filtered by status and searched by
    /// number ("1042" / "#1042") or customer name / email / phone. Returns
    /// one page starting at `offset`.
    static func list(shopID: UUID, status: QuoteStatus?, search: String, offset: Int = 0) async throws -> ListData {
        var query = Supa.client
            .from("quotes")
            .select(Quote.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
        if let status {
            query = query.eq("status", value: status.rawValue)
        }
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            if let number = documentNumber(from: term) {
                query = query.eq("number", value: number)
            } else {
                let matches = try await searchCustomers(shopID: shopID, term: term, includeArchived: true, limit: 100)
                guard !matches.isEmpty else { return ListData(quotes: [], customers: [:]) }
                query = query.in("customer_id", values: matches.map { $0.id.uuidString })
            }
        }
        // One extra row tells whether another page exists.
        let start = max(0, offset)
        var quotes: [Quote] = try await query
            .order("created_at", ascending: false)
            .order("id", ascending: false)
            .range(from: start, to: start + listPageSize)
            .execute()
            .value
        let hasMore = quotes.count > listPageSize
        if hasMore { quotes = Array(quotes.prefix(listPageSize)) }
        let customers = try await PaymentService.customerRefs(shopID: shopID, ids: quotes.map { $0.customerID })
        return ListData(quotes: quotes, customers: customers, hasMore: hasMore)
    }

    /// "1042" or "#1042" → 1042.
    static func documentNumber(from term: String) -> Int? {
        var text = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard !text.isEmpty, text.count <= 15, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    // MARK: - Detail

    struct DetailData: Sendable {
        var quote: Quote
        var lines: [QuoteLineItem]
        var customer: QuoteCustomerRef?
        var vehicle: QuoteVehicleRef?
    }

    static func detail(shopID: UUID, quoteID: UUID) async throws -> DetailData {
        let quotes: [Quote] = try await Supa.client
            .from("quotes")
            .select(Quote.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: quoteID.uuidString)
            .limit(1)
            .execute()
            .value
        guard let quote = quotes.first else { throw AppError.notFound("That quote") }

        async let linesTask = lines(shopID: shopID, quoteID: quoteID)
        async let customerTask = customer(shopID: shopID, customerID: quote.customerID)
        async let vehicleTask = vehicle(shopID: shopID, vehicleID: quote.vehicleID)
        let (lines, customer, vehicle) = try await (linesTask, customerTask, vehicleTask)
        return DetailData(quote: quote, lines: lines, customer: customer, vehicle: vehicle)
    }

    static func lines(shopID: UUID, quoteID: UUID) async throws -> [QuoteLineItem] {
        try await Supa.client
            .from("quote_line_items")
            .select(QuoteLineItem.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("quote_id", value: quoteID.uuidString)
            .order("sort", ascending: true)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    static func customer(shopID: UUID, customerID: UUID) async throws -> QuoteCustomerRef? {
        let rows: [QuoteCustomerRef] = try await Supa.client
            .from("customers")
            .select(QuoteCustomerRef.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: customerID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    static func vehicle(shopID: UUID, vehicleID: UUID?) async throws -> QuoteVehicleRef? {
        guard let vehicleID else { return nil }
        let rows: [QuoteVehicleRef] = try await Supa.client
            .from("vehicles")
            .select(QuoteVehicleRef.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: vehicleID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    // MARK: - Builder lookups

    /// Customers matching name / company / email / phone (generated
    /// `search_text`), active ones only unless `includeArchived`.
    static func searchCustomers(
        shopID: UUID,
        term: String,
        includeArchived: Bool = false,
        limit: Int = 30
    ) async throws -> [QuoteCustomerRef] {
        var query = Supa.client
            .from("customers")
            .select(QuoteCustomerRef.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            query = query.ilike("search_text", pattern: Supa.ilikePattern(trimmed.lowercased()))
        }
        if !includeArchived {
            query = query.is("archived_at", value: nil)
        }
        return try await query
            .order("updated_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    /// The customer's active vehicles.
    static func vehicles(shopID: UUID, customerID: UUID) async throws -> [QuoteVehicleRef] {
        try await Supa.client
            .from("vehicles")
            .select(QuoteVehicleRef.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("customer_id", value: customerID.uuidString)
            .is("archived_at", value: nil)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    /// Active, non-archived catalog services in display order.
    static func services(shopID: UUID) async throws -> [QuoteServiceOption] {
        try await Supa.client
            .from("services")
            .select(QuoteServiceOption.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("active", value: true)
            .is("archived_at", value: nil)
            .order("sort", ascending: true)
            .order("name", ascending: true)
            .execute()
            .value
    }

    /// Catalog prices for the chosen services (`price_services`): the
    /// vehicle's category price (else the base price), with active
    /// memberships applied. A nil unit price means the catalog has no price
    /// for this vehicle category.
    static func price(
        shopID: UUID,
        customerID: UUID,
        vehicleID: UUID?,
        serviceIDs: [UUID]
    ) async throws -> QuotePricing {
        guard !serviceIDs.isEmpty else {
            throw AppError.invalidInput("Choose at least one service.")
        }
        let params: [String: AnyJSON] = [
            "p_shop": .string(shopID.uuidString),
            "p_customer_id": .string(customerID.uuidString),
            "p_vehicle_category_id": .null,
            "p_service_ids": .array(serviceIDs.map { AnyJSON.string($0.uuidString) }),
            "p_vehicle_id": vehicleID.map { AnyJSON.string($0.uuidString) } ?? .null,
        ]
        return try await Supa.client
            .rpc("price_services", params: params)
            .execute()
            .value
    }

    // MARK: - Save (create / edit)

    /// Creates or updates the quote and reconciles its lines. Returns the
    /// quote id. Totals are recomputed by the database.
    static func save(shopID: UUID, draft: QuoteDraft) async throws -> UUID {
        guard let customer = draft.customer else {
            throw AppError.invalidInput("Choose a customer.")
        }
        for line in draft.lines {
            guard line.name.trimmedNonEmpty != nil else {
                throw AppError.invalidInput("Every line needs a name.")
            }
        }
        let fields = QuoteFieldsPayload(draft: draft, customerID: customer.id)
        if let existing = draft.quoteID {
            // Lines first: they carry no vehicle of their own (the quote's
            // vehicle applies), so a customer change can't trip the
            // "line vehicle belongs to the customer" check.
            try await updateExistingLines(shopID: shopID, quoteID: existing, draft: draft)
            try await Supa.client
                .from("quotes")
                .update(fields, returning: .minimal)
                .eq("shop_id", value: shopID.uuidString)
                .eq("id", value: existing.uuidString)
                .execute()
            try await insertNewLines(shopID: shopID, quoteID: existing, draft: draft)
            return existing
        }
        let insert = QuoteInsertPayload(shopID: shopID, fields: fields)
        let created: Quote = try await Supa.client
            .from("quotes")
            .insert(insert, returning: .representation)
            .select(Quote.selectColumns)
            .single()
            .execute()
            .value
        do {
            try await insertNewLines(shopID: shopID, quoteID: created.id, draft: draft)
        } catch {
            // Don't leave a half-built quote behind: a retry creates it anew.
            try? await delete(shopID: shopID, quoteID: created.id)
            throw error
        }
        return created.id
    }

    /// Deletes removed lines and updates the kept ones (with their new order).
    private static func updateExistingLines(shopID: UUID, quoteID: UUID, draft: QuoteDraft) async throws {
        let keptIDs = Set(draft.lines.compactMap { $0.id })
        let removed = draft.originalLineIDs.filter { !keptIDs.contains($0) }
        if !removed.isEmpty {
            try await Supa.client
                .from("quote_line_items")
                .delete(returning: .minimal)
                .eq("shop_id", value: shopID.uuidString)
                .eq("quote_id", value: quoteID.uuidString)
                .in("id", values: removed.map { $0.uuidString })
                .execute()
        }
        for (index, line) in draft.lines.enumerated() {
            guard let lineID = line.id else { continue }
            let payload = QuoteLinePayload(line: line, sort: index + 1)
            try await Supa.client
                .from("quote_line_items")
                .update(payload, returning: .minimal)
                .eq("shop_id", value: shopID.uuidString)
                .eq("quote_id", value: quoteID.uuidString)
                .eq("id", value: lineID.uuidString)
                .execute()
        }
    }

    /// Inserts the lines added in the builder (one request).
    private static func insertNewLines(shopID: UUID, quoteID: UUID, draft: QuoteDraft) async throws {
        var inserts: [QuoteLineInsertPayload] = []
        for (index, line) in draft.lines.enumerated() where line.id == nil {
            let payload = QuoteLinePayload(line: line, sort: index + 1)
            inserts.append(QuoteLineInsertPayload(shopID: shopID, quoteID: quoteID, line: payload))
        }
        guard !inserts.isEmpty else { return }
        try await Supa.client
            .from("quote_line_items")
            .insert(inserts, returning: .minimal)
            .execute()
    }

    // MARK: - Status actions

    /// draft → sent (or re-stamps a sent/viewed quote). Needs at least one
    /// line and an unexpired valid-until date (checked by the RPC).
    @discardableResult
    static func markSent(quoteID: UUID) async throws -> Quote {
        try await Supa.client
            .rpc("mark_quote_sent", params: ["p_quote_id": quoteID.uuidString])
            .execute()
            .value
    }

    /// Sends the shop's `quote_sent` wording with this quote's client link
    /// (`/q/<token>`) through the messaging edge function (consent and
    /// opt-outs enforced server-side). Rendered in the app: the server's
    /// template variables only carry a quote link for a job's quote.
    static func sendQuoteMessage(
        shopID: UUID,
        quote: Quote,
        channel: MoneyMessageChannel
    ) async throws -> MoneyMessageResult {
        guard let link = MoneyLinks.quote(token: quote.publicToken) else {
            throw AppError.message("Quote links need WEB_APP_URL in the app configuration, so the message can't include the link.")
        }
        return try await MoneyDocumentMessage.send(
            shopID: shopID,
            request: MoneyDocumentMessage.Request(
                template: .quoteSent,
                customerID: quote.customerID,
                jobID: nil,
                channel: channel,
                link: link,
                amountCents: nil,
                balanceCents: nil
            )
        )
    }

    /// Records the customer's answer given in person / by phone.
    static func recordApproval(shopID: UUID, quoteID: UUID, approvedByName: String) async throws {
        struct Payload: Encodable {
            let status = "approved"
            let approved_by_name: String
        }
        let name = approvedByName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppError.invalidInput("Enter who approved the quote.") }
        try await Supa.client
            .from("quotes")
            .update(Payload(approved_by_name: name), returning: .minimal)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: quoteID.uuidString)
            .execute()
    }

    static func recordDecline(shopID: UUID, quoteID: UUID, reason: String?) async throws {
        struct Payload: Encodable {
            let status = "declined"
            let declined_reason: String?

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: PayloadKeys.self)
                try c.encode(status, forKey: .status)
                try c.encode(declined_reason, forKey: .declined_reason)
            }

            enum PayloadKeys: String, CodingKey {
                case status, declined_reason
            }
        }
        try await Supa.client
            .from("quotes")
            .update(Payload(declined_reason: reason?.trimmedNonEmpty), returning: .minimal)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: quoteID.uuidString)
            .execute()
    }

    /// sent / viewed / approved / declined / expired → draft (clears stamps).
    static func reviseToDraft(shopID: UUID, quoteID: UUID) async throws {
        try await Supa.client
            .from("quotes")
            .update(["status": "draft"], returning: .minimal)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: quoteID.uuidString)
            .execute()
    }

    /// Deletes a quote that was never converted.
    static func delete(shopID: UUID, quoteID: UUID) async throws {
        try await Supa.client
            .from("quotes")
            .delete(returning: .minimal)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: quoteID.uuidString)
            .execute()
    }

    /// Approved quote → new job (`convert_quote_to_job`). With a start and
    /// end the job is scheduled; with neither it is an unscheduled request.
    static func convertToJob(quoteID: UUID, start: Date?, end: Date?) async throws -> QuoteConvertedJob {
        if let start, let end, end <= start {
            throw AppError.invalidInput("The end time must be after the start time.")
        }
        let params: [String: AnyJSON] = [
            "p_quote_id": .string(quoteID.uuidString),
            "p_start": start.map { AnyJSON.string(Supa.iso($0)) } ?? .null,
            "p_end": end.map { AnyJSON.string(Supa.iso($0)) } ?? .null,
        ]
        return try await Supa.client
            .rpc("convert_quote_to_job", params: params)
            .execute()
            .value
    }
}

// MARK: - Write payloads (never carry totals)

/// Editable quote columns. `nil` optionals are sent as JSON null so a
/// cleared field is cleared on the server.
private struct QuoteFieldsPayload: Encodable {
    let customerID: UUID
    let vehicleID: UUID?
    let validUntil: String?
    let notes: String?
    let terms: String?
    let internalNotes: String?
    let discountKind: String
    let discountValue: Int

    init(draft: QuoteDraft, customerID: UUID) {
        self.customerID = customerID
        self.vehicleID = draft.vehicle?.id
        self.validUntil = draft.validUntil
        self.notes = draft.notes.trimmedNonEmpty
        self.terms = draft.terms.trimmedNonEmpty
        self.internalNotes = draft.internalNotes.trimmedNonEmpty
        self.discountKind = draft.discountKind.rawValue
        self.discountValue = draft.discountKind == .none ? 0 : max(0, draft.discountValue)
    }

    enum FieldKeys: String, CodingKey {
        case customerID = "customer_id"
        case vehicleID = "vehicle_id"
        case validUntil = "valid_until"
        case notes
        case terms
        case internalNotes = "internal_notes"
        case discountKind = "discount_kind"
        case discountValue = "discount_value"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: FieldKeys.self)
        try c.encode(customerID, forKey: .customerID)
        try c.encode(vehicleID, forKey: .vehicleID)
        try c.encode(validUntil, forKey: .validUntil)
        try c.encode(notes, forKey: .notes)
        try c.encode(terms, forKey: .terms)
        try c.encode(internalNotes, forKey: .internalNotes)
        try c.encode(discountKind, forKey: .discountKind)
        try c.encode(discountValue, forKey: .discountValue)
    }
}

/// Insert = shop + editable fields (status defaults to draft; number, tax
/// rate and default terms are filled in by the database).
private struct QuoteInsertPayload: Encodable {
    let shopID: UUID
    let fields: QuoteFieldsPayload

    enum InsertKeys: String, CodingKey {
        case shopID = "shop_id"
    }

    func encode(to encoder: Encoder) throws {
        var shop = encoder.container(keyedBy: InsertKeys.self)
        try shop.encode(shopID, forKey: .shopID)
        var c = encoder.container(keyedBy: QuoteFieldsPayload.FieldKeys.self)
        try c.encode(fields.customerID, forKey: .customerID)
        try c.encodeIfPresent(fields.vehicleID, forKey: .vehicleID)
        try c.encodeIfPresent(fields.validUntil, forKey: .validUntil)
        try c.encodeIfPresent(fields.notes, forKey: .notes)
        // Omitted when empty so the shop's default quote terms apply.
        try c.encodeIfPresent(fields.terms, forKey: .terms)
        try c.encodeIfPresent(fields.internalNotes, forKey: .internalNotes)
        try c.encode(fields.discountKind, forKey: .discountKind)
        try c.encode(fields.discountValue, forKey: .discountValue)
    }
}

/// Editable line columns (no totals; `total_cents` is generated). Lines
/// carry no vehicle of their own: the quote's vehicle applies.
private struct QuoteLinePayload: Encodable {
    let serviceID: UUID?
    let name: String
    let lineDescription: String?
    let quantity: Decimal
    let unitPriceCents: Int
    let discountCents: Int
    let taxable: Bool
    let durationMinutes: Int
    let isOptional: Bool
    let isSelected: Bool
    let sort: Int

    init(line: QuoteDraftLine, sort: Int) {
        self.serviceID = line.serviceID
        self.name = line.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lineDescription = line.lineDescription?.trimmedNonEmpty
        self.quantity = line.quantity
        self.unitPriceCents = max(0, line.unitPriceCents)
        self.discountCents = max(0, line.discountCents)
        self.taxable = line.taxable
        self.durationMinutes = max(0, line.durationMinutes)
        self.isOptional = line.isOptional
        self.isSelected = line.isOptional ? line.isSelected : true
        self.sort = sort
    }

    enum LineKeys: String, CodingKey {
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
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: LineKeys.self)
        try c.encode(serviceID, forKey: .serviceID)
        try c.encodeNil(forKey: .vehicleID)
        try c.encode(name, forKey: .name)
        try c.encode(lineDescription, forKey: .lineDescription)
        try c.encode(quantity, forKey: .quantity)
        try c.encode(unitPriceCents, forKey: .unitPriceCents)
        try c.encode(discountCents, forKey: .discountCents)
        try c.encode(taxable, forKey: .taxable)
        try c.encode(durationMinutes, forKey: .durationMinutes)
        try c.encode(isOptional, forKey: .isOptional)
        try c.encode(isSelected, forKey: .isSelected)
        try c.encode(sort, forKey: .sort)
    }
}

private struct QuoteLineInsertPayload: Encodable {
    let shopID: UUID
    let quoteID: UUID
    let line: QuoteLinePayload

    enum InsertKeys: String, CodingKey {
        case shopID = "shop_id"
        case quoteID = "quote_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: InsertKeys.self)
        try c.encode(shopID, forKey: .shopID)
        try c.encode(quoteID, forKey: .quoteID)
        try line.encode(to: encoder)
    }
}
