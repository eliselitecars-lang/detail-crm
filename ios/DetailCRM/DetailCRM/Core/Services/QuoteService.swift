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
        /// Proposal options in display order (empty for a plain quote).
        var options: [MoneyQuoteOption] = []
        /// The job the quote became (number + how it was scheduled).
        var convertedJob: ConvertedJobRef?
        /// The shop's online self-scheduling switch; nil when it couldn't
        /// be read.
        var selfScheduleSetting: SelfScheduleSetting?

        /// The option the totals count (the customer's choice, else first).
        var effectiveOptionID: UUID? { quote.effectiveOptionID(options: options) }

        /// Lines the quote total counts right now.
        var countedLines: [QuoteLineItem] {
            let effective = effectiveOptionID
            return lines.filter { quote.counts($0, effectiveOptionID: effective) }
        }
    }

    /// The job an approved quote was converted into.
    // table: jobs
    struct ConvertedJobRef: Codable, Hashable, Sendable {
        var id: UUID
        var number: Int
        var status: JobStatus
        var scheduledStart: Date?
        /// staff | online_booking | quote | membership
        var source: String

        enum CodingKeys: String, CodingKey {
            case id
            case number
            case status
            case scheduledStart = "scheduled_start"
            case source
        }

        static let selectColumns = "id,number,status,scheduled_start,source"
    }

    /// Whether the shop lets customers schedule approved quotes online.
    // table: booking_settings
    struct SelfScheduleSetting: Codable, Hashable, Sendable {
        /// Online booking is on.
        var enabled: Bool
        /// Quote self-scheduling is on.
        var quoteSelfSchedule: Bool

        enum CodingKeys: String, CodingKey {
            case enabled
            case quoteSelfSchedule = "quote_self_schedule"
        }

        static let selectColumns = "enabled,quote_self_schedule"

        /// Customers can actually schedule (both switches on).
        var isAvailable: Bool { enabled && quoteSelfSchedule }
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
        async let optionsTask = options(shopID: shopID, quoteID: quoteID)
        async let customerTask = customer(shopID: shopID, customerID: quote.customerID)
        async let vehicleTask = vehicle(shopID: shopID, vehicleID: quote.vehicleID)
        let (lines, options, customer, vehicle) = try await (linesTask, optionsTask, customerTask, vehicleTask)
        // Extras must not hide the quote itself.
        let jobRef = try? await convertedJob(shopID: shopID, jobID: quote.convertedJobID)
        let setting = try? await selfScheduleSetting(shopID: shopID)
        return DetailData(
            quote: quote,
            lines: lines,
            customer: customer,
            vehicle: vehicle,
            options: options,
            convertedJob: jobRef,
            selfScheduleSetting: setting
        )
    }

    /// The quote's proposal options in display order.
    static func options(shopID: UUID, quoteID: UUID) async throws -> [MoneyQuoteOption] {
        let rows: [MoneyQuoteOption] = try await Supa.client
            .from("quote_options")
            .select(MoneyQuoteOption.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("quote_id", value: quoteID.uuidString)
            .order("sort", ascending: true)
            .order("created_at", ascending: true)
            .execute()
            .value
        return MoneyQuoteOption.ordered(rows)
    }

    static func convertedJob(shopID: UUID, jobID: UUID?) async throws -> ConvertedJobRef? {
        guard let jobID else { return nil }
        let rows: [ConvertedJobRef] = try await Supa.client
            .from("jobs")
            .select(ConvertedJobRef.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: jobID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    static func selfScheduleSetting(shopID: UUID) async throws -> SelfScheduleSetting? {
        let rows: [SelfScheduleSetting] = try await Supa.client
            .from("booking_settings")
            .select(SelfScheduleSetting.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
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
        // The category comes from the vehicle server-side; unknown
        // arguments are omitted (SQL defaults: null).
        var params: [String: AnyJSON] = [
            "p_shop": .string(shopID.uuidString),
            "p_customer_id": .string(customerID.uuidString),
            "p_service_ids": .array(serviceIDs.map { AnyJSON.string($0.uuidString) }),
        ]
        if let vehicleID {
            params["p_vehicle_id"] = .string(vehicleID.uuidString)
        }
        return try await Supa.client
            .rpc("price_services", params: params)
            .execute()
            .value
    }

    // MARK: - Save (create / edit)

    /// Creates or updates the quote and reconciles its options and lines.
    /// Returns the quote id. Totals are recomputed by the database.
    ///
    /// The save is several requests (PostgREST has no multi-table
    /// transaction), so `draft` records each row as it is created or
    /// deleted: when a request fails, the caller keeps the updated draft and
    /// saving it again finishes the job without adding the same options and
    /// lines twice (`QuoteDraft.applyEdits(using:)`). New options and custom
    /// lines get their ids here, so an insert whose reply was lost is found
    /// on the retry instead of being inserted again.
    static func save(shopID: UUID, draft: inout QuoteDraft) async throws -> UUID {
        guard let customer = draft.customer else {
            throw AppError.invalidInput("Choose a customer.")
        }
        for line in draft.lines {
            guard line.name.trimmedNonEmpty != nil else {
                throw AppError.invalidInput("Every line needs a name.")
            }
        }
        guard draft.options.count <= MoneyQuoteOption.maxPerQuote else {
            throw AppError.invalidInput("A quote can have at most \(MoneyQuoteOption.maxPerQuote) options.")
        }
        if draft.options.contains(where: { $0.validName == nil }) {
            throw AppError.invalidInput("Every option needs a name (up to \(MoneyQuoteOption.maxNameLength) characters).")
        }
        let knownOptions = Set(draft.options.map { $0.localID })
        if draft.lines.contains(where: { $0.optionLocalID.map { !knownOptions.contains($0) } ?? false }) {
            throw AppError.invalidInput("An item belongs to an option that was removed. Move it to another option or remove it.")
        }
        let fields = QuoteFieldsPayload(draft: draft, customerID: customer.id)
        if let existing = draft.quoteID {
            try await draft.applyEdits(using: saveRequests(shopID: shopID, quoteID: existing) {
                try await Supa.client
                    .from("quotes")
                    .update(fields, returning: .minimal)
                    .eq("shop_id", value: shopID.uuidString)
                    .eq("id", value: existing.uuidString)
                    .execute()
            })
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
        var progress = draft
        progress.quoteID = created.id
        do {
            // The quote was just written with these fields.
            try await progress.applyEdits(using: saveRequests(shopID: shopID, quoteID: created.id) {})
        } catch {
            // Don't leave a half-built quote behind: a retry creates it anew.
            // If it can't be removed, the retry finishes this one instead.
            if (try? await delete(shopID: shopID, quoteID: created.id)) == nil {
                draft = progress
            }
            throw error
        }
        draft = progress
        return created.id
    }

    /// The Supabase requests of one save (see `QuoteDraft.SaveRequests`).
    private static func saveRequests(
        shopID: UUID,
        quoteID: UUID,
        updateQuote: @escaping () async throws -> Void
    ) -> QuoteDraft.SaveRequests {
        let shop = shopID.uuidString
        let quote = quoteID.uuidString
        return QuoteDraft.SaveRequests(
            existingOptionIDs: { ids in
                let rows: [IDRow] = try await Supa.client
                    .from("quote_options")
                    .select("id")
                    .eq("shop_id", value: shop)
                    .eq("quote_id", value: quote)
                    .in("id", values: ids.map { $0.uuidString })
                    .execute()
                    .value
                return Set(rows.map { $0.id })
            },
            existingLines: { ids in
                let rows: [LineRefRow] = try await Supa.client
                    .from("quote_line_items")
                    .select("id,option_id")
                    .eq("shop_id", value: shop)
                    .eq("quote_id", value: quote)
                    .in("id", values: ids.map { $0.uuidString })
                    .execute()
                    .value
                return rows.map { QuoteDraft.SavedLineRef(id: $0.id, optionID: $0.optionID) }
            },
            deleteLines: { ids in
                try await Supa.client
                    .from("quote_line_items")
                    .delete(returning: .minimal)
                    .eq("shop_id", value: shop)
                    .eq("quote_id", value: quote)
                    .in("id", values: ids.map { $0.uuidString })
                    .execute()
            },
            deleteOptions: { ids in
                // Any lines still on them go with them (FK cascade).
                try await Supa.client
                    .from("quote_options")
                    .delete(returning: .minimal)
                    .eq("shop_id", value: shop)
                    .eq("quote_id", value: quote)
                    .in("id", values: ids.map { $0.uuidString })
                    .execute()
            },
            updateOption: { id, option, sort in
                try await Supa.client
                    .from("quote_options")
                    .update(QuoteOptionPayload(option: option, sort: sort), returning: .minimal)
                    .eq("shop_id", value: shop)
                    .eq("quote_id", value: quote)
                    .eq("id", value: id.uuidString)
                    .execute()
            },
            insertOption: { id, option, sort in
                let payload = QuoteOptionInsertPayload(
                    id: id,
                    shopID: shopID,
                    quoteID: quoteID,
                    fields: QuoteOptionPayload(option: option, sort: sort)
                )
                try await Supa.client
                    .from("quote_options")
                    .insert(payload, returning: .minimal)
                    .execute()
            },
            updateLine: { id, line, sort, optionID, placementOnly in
                let request = Supa.client.from("quote_line_items")
                if placementOnly {
                    try await request
                        .update(QuoteLinePlacementPayload(sort: sort, optionID: optionID), returning: .minimal)
                        .eq("shop_id", value: shop)
                        .eq("quote_id", value: quote)
                        .eq("id", value: id.uuidString)
                        .execute()
                } else {
                    try await request
                        .update(QuoteLinePayload(line: line, sort: sort, optionID: optionID), returning: .minimal)
                        .eq("shop_id", value: shop)
                        .eq("quote_id", value: quote)
                        .eq("id", value: id.uuidString)
                        .execute()
                }
            },
            insertLines: { lines in
                let inserts = lines.map { new in
                    QuoteLineInsertPayload(
                        id: new.id,
                        shopID: shopID,
                        quoteID: quoteID,
                        line: QuoteLinePayload(line: new.line, sort: new.sort, optionID: new.optionID)
                    )
                }
                try await Supa.client
                    .from("quote_line_items")
                    .insert(inserts, returning: .minimal)
                    .execute()
            },
            addFeeLine: { feeID in
                try await JobService.addFeeLine(kind: .quote, documentID: quoteID, feeID: feeID)
            },
            updateQuote: updateQuote
        )
    }

    /// A saved option's id (existence check on a retried save).
    private struct IDRow: Decodable {
        let id: UUID
    }

    /// A saved line's id and option (existence check on a retried save).
    // table: quote_line_items
    private struct LineRefRow: Decodable {
        let id: UUID
        let optionID: UUID?

        enum CodingKeys: String, CodingKey {
            case id
            case optionID = "option_id"
        }
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
    /// (`/q/<token>`) and total, rendered and queued by the server
    /// (`messaging` send with `quote_id`; consent and opt-outs enforced
    /// server-side). The quote must be sent (not a draft) first. `nonce`
    /// is one per compose, reused on a retry.
    static func sendQuoteMessage(
        shopID: UUID,
        quote: Quote,
        channel: MoneyMessageChannel,
        nonce: String
    ) async throws -> MoneyMessageResult {
        try await MoneyDocumentMessage.send(
            shopID: shopID,
            request: MoneyDocumentMessage.Request(kind: .quoteSent, id: quote.id, channel: channel),
            nonce: nonce
        )
    }

    /// Records the customer's approval given in person / by phone
    /// (`staff_record_quote_response`, manager+): in one transaction the
    /// optional items the customer chose become exactly
    /// `selectedOptionalIDs` (nil keeps the current choices), the chosen
    /// proposal option is stored (required for a quote with options, and
    /// only then) and the quote is approved. Only a sent / viewed,
    /// unexpired quote can be answered.
    @discardableResult
    static func recordApproval(
        shopID: UUID,
        quoteID: UUID,
        approvedByName: String,
        selectedOptionalIDs: [UUID]?,
        optionID: UUID? = nil
    ) async throws -> Quote {
        let name = approvedByName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppError.invalidInput("Enter who approved the quote.") }
        guard name.count <= 200 else { throw AppError.invalidInput("Keep the name under 200 characters.") }
        return try await Supa.client
            .rpc("staff_record_quote_response", params: QuoteResponseParams(
                p_quote_id: quoteID,
                p_action: "approve",
                p_selected_optional_line_ids: selectedOptionalIDs,
                p_approved_by_name: name,
                p_declined_reason: nil,
                p_option_id: optionID
            ))
            .execute()
            .value
    }

    /// Lets (or stops) the customer schedule this quote online once it is
    /// approved (P-16, `quotes.self_schedule`). The shop's booking settings
    /// must allow quote self-scheduling too.
    static func setSelfSchedule(shopID: UUID, quoteID: UUID, enabled: Bool) async throws {
        try await Supa.client
            .from("quotes")
            .update(["self_schedule": enabled], returning: .minimal)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: quoteID.uuidString)
            .execute()
    }

    /// Records the customer's decline given in person / by phone
    /// (`staff_record_quote_response`, manager+).
    @discardableResult
    static func recordDecline(shopID: UUID, quoteID: UUID, reason: String?) async throws -> Quote {
        let trimmed = reason?.trimmedNonEmpty
        if let trimmed, trimmed.count > 1000 {
            throw AppError.invalidInput("Keep the reason under 1,000 characters.")
        }
        return try await Supa.client
            .rpc("staff_record_quote_response", params: QuoteResponseParams(
                p_quote_id: quoteID,
                p_action: "decline",
                p_selected_optional_line_ids: nil,
                p_approved_by_name: nil,
                p_declined_reason: trimmed,
                p_option_id: nil
            ))
            .execute()
            .value
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
    /// The saved option id; nil = shared by every option.
    let optionID: UUID?

    init(line: QuoteDraftLine, sort: Int, optionID: UUID?) {
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
        self.optionID = optionID
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
        case optionID = "option_id"
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
        // Explicit null moves a line back to "shared".
        try c.encode(optionID, forKey: .optionID)
    }
}

/// A new custom line; its id is chosen by the app so a retried save can
/// tell whether the insert reached the server.
private struct QuoteLineInsertPayload: Encodable {
    let id: UUID
    let shopID: UUID
    let quoteID: UUID
    let line: QuoteLinePayload

    enum InsertKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case quoteID = "quote_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: InsertKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(shopID, forKey: .shopID)
        try c.encode(quoteID, forKey: .quoteID)
        try line.encode(to: encoder)
    }
}

/// `staff_record_quote_response` arguments; nil ones are omitted (their
/// SQL defaults apply: null keeps the current optional-line choices).
private struct QuoteResponseParams: Encodable {
    let p_quote_id: UUID
    let p_action: String
    let p_selected_optional_line_ids: [UUID]?
    let p_approved_by_name: String?
    let p_declined_reason: String?
    let p_option_id: UUID?
}

// MARK: - Option and fee-line payloads (P-15 / P-21)

extension QuoteService {
    /// Place and option of a fee line the server just added (its name, price
    /// and tax come from the shop's fee).
    fileprivate struct QuoteLinePlacementPayload: Encodable {
        let sort: Int
        let optionID: UUID?

        enum PlacementKeys: String, CodingKey {
            case sort
            case optionID = "option_id"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: PlacementKeys.self)
            try c.encode(sort, forKey: .sort)
            try c.encode(optionID, forKey: .optionID)
        }
    }

    /// Editable option columns (totals are server-maintained).
    fileprivate struct QuoteOptionPayload: Encodable {
        let name: String
        let optionDescription: String?
        let sort: Int

        init(option: MoneyQuoteOption.Draft, sort: Int) {
            self.name = option.validName ?? option.name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.optionDescription = option.optionDescription.trimmedNonEmpty
            self.sort = sort
        }

        enum OptionKeys: String, CodingKey {
            case name
            case optionDescription = "description"
            case sort
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: OptionKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(optionDescription, forKey: .optionDescription)
            try c.encode(sort, forKey: .sort)
        }
    }

    /// A new option; its id is chosen by the app (see QuoteLineInsertPayload).
    fileprivate struct QuoteOptionInsertPayload: Encodable {
        let id: UUID
        let shopID: UUID
        let quoteID: UUID
        let fields: QuoteOptionPayload

        enum InsertKeys: String, CodingKey {
            case id
            case shopID = "shop_id"
            case quoteID = "quote_id"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: InsertKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(shopID, forKey: .shopID)
            try c.encode(quoteID, forKey: .quoteID)
            try fields.encode(to: encoder)
        }
    }
}
