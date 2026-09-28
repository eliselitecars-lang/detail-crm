//
//  InvoiceService.swift
//  DetailCRM
//
//  Invoices (SPEC §4.5). Creation, issuing and voiding go through RPCs;
//  totals, amount paid, balance and status are server-maintained. Managers
//  and above see every invoice; technicians see (and may collect on) the
//  invoice of a job assigned to them only when the shop allows it — RLS
//  (`can_collect_for_job`) enforces that regardless of the UI.
//

import Foundation
import Supabase
import DetailCore

enum InvoiceService {

    // MARK: - List

    struct ListData: Sendable {
        var invoices: [Invoice]
        var customers: [UUID: QuoteCustomerRef]
        /// More (older) invoices match beyond the rows loaded so far.
        var hasMore: Bool = false

        /// Appends the next page (skipping rows already shown).
        func appending(_ page: ListData) -> ListData {
            let known = Set(invoices.map { $0.id })
            var merged = self
            merged.invoices += page.invoices.filter { !known.contains($0.id) }
            merged.customers.merge(page.customers) { current, _ in current }
            merged.hasMore = page.hasMore
            return merged
        }
    }

    /// Rows per list page ("Load more" fetches the next page).
    static let listPageSize = 100

    /// Invoices, newest first, filtered and searched by number or customer;
    /// one page starting at `offset`.
    static func list(
        shopID: UUID,
        filter: InvoiceListFilter,
        search: String,
        offset: Int = 0,
        now: Date = Date()
    ) async throws -> ListData {
        var query = Supa.client
            .from("invoices")
            .select(Invoice.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
        switch filter {
        case .all:
            break
        case .unpaid:
            query = query.in("status", values: [InvoiceStatus.open.rawValue, InvoiceStatus.partiallyPaid.rawValue])
        case .overdue:
            query = query
                .in("status", values: [InvoiceStatus.open.rawValue, InvoiceStatus.partiallyPaid.rawValue])
                .gt("balance_cents", value: 0)
                .lt("due_at", value: Supa.iso(now))
        case .draft:
            query = query.eq("status", value: InvoiceStatus.draft.rawValue)
        case .paid:
            query = query.eq("status", value: InvoiceStatus.paid.rawValue)
        case .void:
            query = query.eq("status", value: InvoiceStatus.void.rawValue)
        }
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            if let number = QuoteService.documentNumber(from: term) {
                query = query.eq("number", value: number)
            } else {
                let matches = try await QuoteService.searchCustomers(
                    shopID: shopID, term: term, includeArchived: true, limit: 100
                )
                guard !matches.isEmpty else { return ListData(invoices: [], customers: [:]) }
                query = query.in("customer_id", values: matches.map { $0.id.uuidString })
            }
        }
        // One extra row tells whether another page exists.
        let start = max(0, offset)
        var invoices: [Invoice] = try await query
            .order("created_at", ascending: false)
            .order("id", ascending: false)
            .range(from: start, to: start + listPageSize)
            .execute()
            .value
        let hasMore = invoices.count > listPageSize
        if hasMore { invoices = Array(invoices.prefix(listPageSize)) }
        let customers = try await PaymentService.customerRefs(shopID: shopID, ids: invoices.map { $0.customerID })
        return ListData(invoices: invoices, customers: customers, hasMore: hasMore)
    }

    // MARK: - Detail

    struct DetailData: Sendable {
        var invoice: Invoice
        var lines: [InvoiceLineItem]
        var payments: [Payment]
        var customer: QuoteCustomerRef?
        /// Saved cards (manager+ only; empty otherwise, and when they
        /// couldn't be read — see `savedCardsProblem`).
        var savedCards: [SavedCard]
        /// The customer's pay-link token (manager+ only; nil otherwise, and
        /// when it couldn't be read — see `linkTokenProblem`).
        var linkToken: UUID?
        /// Why the saved cards couldn't be read (nil when they were, or
        /// weren't asked for). The screen shows it with a retry, so a
        /// failed read never looks like "no card on file".
        var savedCardsProblem: String? = nil
        /// Why the pay-link token couldn't be read (nil when it was, or
        /// wasn't asked for); shown in place of "Share pay link".
        var linkTokenProblem: String? = nil
        /// The jobs this invoice bills, in billing order (P-7). One for a
        /// job's own invoice, 2+ for a grouped (fleet) invoice; empty for an
        /// invoice without a job or when they can't be read.
        var billedJobs: [BilledJob] = []
        /// Vehicles named on the lines (and the billed jobs), by id.
        var vehicles: [UUID: QuoteVehicleRef] = [:]

        /// Several jobs on one invoice: lines are shown per job.
        var isGrouped: Bool { billedJobs.count > 1 }

        /// A payment the balance doesn't count yet (card attempt or a bank /
        /// pay-later payment still settling).
        var hasPaymentInFlight: Bool { payments.contains { $0.isInFlight } }

        /// Bank debit / pay-later payments still settling.
        var processingPayments: [Payment] { payments.filter { $0.status == .processing } }
    }

    /// Links of an invoice to the jobs it bills (server-maintained).
    // table: invoice_jobs
    struct InvoiceJobLink: Codable, Hashable, Sendable {
        var jobID: UUID
        var voided: Bool

        enum CodingKeys: String, CodingKey {
            case jobID = "job_id"
            case voided
        }

        static let selectColumns = "job_id,voided"
    }

    /// A job billed by the invoice (number, date and vehicle for headings).
    // table: jobs
    struct BilledJob: Codable, Identifiable, Hashable, Sendable {
        var id: UUID
        var number: Int
        var status: JobStatus
        var vehicleID: UUID?
        var scheduledStart: Date?
        var completedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case number
            case status
            case vehicleID = "vehicle_id"
            case scheduledStart = "scheduled_start"
            case completedAt = "completed_at"
        }

        static let selectColumns = "id,number,status,vehicle_id,scheduled_start,completed_at"

        /// "Job #1042"
        var title: String { "Job #\(number)" }

        /// When the work happened (completed, else scheduled).
        var workDate: Date? { completedAt ?? scheduledStart }
    }

    static func detail(
        shopID: UUID,
        invoiceID: UUID,
        includeSavedCards: Bool,
        includeLinkToken: Bool
    ) async throws -> DetailData {
        let invoice = try await invoice(shopID: shopID, invoiceID: invoiceID)
        async let linesTask = lines(shopID: shopID, invoiceID: invoiceID)
        async let paymentsTask = PaymentService.payments(shopID: shopID, invoiceID: invoiceID)
        async let customerTask = QuoteService.customer(shopID: shopID, customerID: invoice.customerID)
        let (lines, payments, customer) = try await (linesTask, paymentsTask, customerTask)
        // Saved cards and the pay-link token are extras: a failure must not
        // hide the invoice itself, but it is recorded so the screen says so
        // (with a retry) instead of leaving the action out as if there were
        // no card / no link.
        var cards: [SavedCard] = []
        var cardsProblem: String?
        if includeSavedCards {
            switch try await SideLoad.attempt({ try await savedCards(shopID: shopID, customerID: invoice.customerID) }) {
            case .success(let rows): cards = rows
            case .failure(let error): cardsProblem = ErrorText.message(for: error)
            }
        }
        var token: UUID?
        var tokenProblem: String?
        if includeLinkToken {
            switch try await SideLoad.attempt({ try await linkToken(invoiceID: invoiceID) }) {
            case .success(let value): token = value
            case .failure(let error): tokenProblem = ErrorText.message(for: error)
            }
        }
        // Job headings and vehicle names are extras: a failure (or RLS
        // hiding them from a technician) leaves the plain line list.
        let jobs = (try? await billedJobs(shopID: shopID, invoice: invoice)) ?? []
        var vehicleIDs = Set(lines.compactMap { $0.vehicleID })
        for job in jobs {
            if let vehicleID = job.vehicleID { vehicleIDs.insert(vehicleID) }
        }
        let vehicles = (try? await vehicleRefs(shopID: shopID, ids: Array(vehicleIDs))) ?? [:]
        return DetailData(
            invoice: invoice, lines: lines, payments: payments, customer: customer,
            savedCards: cards, linkToken: token,
            savedCardsProblem: cardsProblem, linkTokenProblem: tokenProblem,
            billedJobs: jobs, vehicles: vehicles
        )
    }

    /// The jobs the invoice bills, ordered like its lines (scheduled start,
    /// then number). Voided links are left out unless the invoice itself is
    /// void (then they show what it billed).
    static func billedJobs(shopID: UUID, invoice: Invoice) async throws -> [BilledJob] {
        let links: [InvoiceJobLink] = try await Supa.client
            .from("invoice_jobs")
            .select(InvoiceJobLink.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("invoice_id", value: invoice.id.uuidString)
            .execute()
            .value
        var ids = links.filter { invoice.status == .void || !$0.voided }.map { $0.jobID }
        if ids.isEmpty, let jobID = invoice.jobID { ids = [jobID] }
        guard !ids.isEmpty else { return [] }
        let jobs: [BilledJob] = try await Supa.client
            .from("jobs")
            .select(BilledJob.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .in("id", values: ids.map { $0.uuidString })
            .execute()
            .value
        return jobs.sorted { lhs, rhs in
            switch (lhs.scheduledStart, rhs.scheduledStart) {
            case let (l?, r?) where l != r: return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.number < rhs.number
            }
        }
    }

    /// Vehicle names for a set of ids. Keep URLs short: one request per
    /// chunk of 100 ids (every id of the list is looked up).
    static func vehicleRefs(shopID: UUID, ids: [UUID]) async throws -> [UUID: QuoteVehicleRef] {
        var map: [UUID: QuoteVehicleRef] = [:]
        for chunk in IDChunks.chunks(ids) {
            let rows: [QuoteVehicleRef] = try await Supa.client
                .from("vehicles")
                .select(QuoteVehicleRef.selectColumns)
                .eq("shop_id", value: shopID.uuidString)
                .in("id", values: chunk.map { $0.uuidString })
                .execute()
                .value
            for row in rows { map[row.id] = row }
        }
        return map
    }

    static func invoice(shopID: UUID, invoiceID: UUID) async throws -> Invoice {
        let rows: [Invoice] = try await Supa.client
            .from("invoices")
            .select(Invoice.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: invoiceID.uuidString)
            .limit(1)
            .execute()
            .value
        guard let invoice = rows.first else { throw AppError.notFound("That invoice") }
        return invoice
    }

    /// The customer's /i/<token> pay-link credential (`invoice_link_token`):
    /// owners/admins/managers only — technicians collect in the app instead.
    static func linkToken(invoiceID: UUID) async throws -> UUID {
        try await Supa.client
            .rpc("invoice_link_token", params: ["p_invoice_id": invoiceID.uuidString])
            .execute()
            .value
    }

    static func lines(shopID: UUID, invoiceID: UUID) async throws -> [InvoiceLineItem] {
        try await Supa.client
            .from("invoice_line_items")
            .select(InvoiceLineItem.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("invoice_id", value: invoiceID.uuidString)
            .order("sort", ascending: true)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    /// The customer's saved cards, default first (manager+ via RLS).
    static func savedCards(shopID: UUID, customerID: UUID) async throws -> [SavedCard] {
        try await Supa.client
            .from("customer_payment_methods")
            .select(SavedCard.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("customer_id", value: customerID.uuidString)
            .order("is_default", ascending: false)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// A card attempt the server still counts as in flight (a PaymentSheet
    /// or Tap to Pay attempt that was opened but not finished): it blocks
    /// cash payments for the balance and voiding until
    /// `PaymentService.cancelOpenPayments`.
    static func hasOpenCardAttempt(_ payments: [Payment]) -> Bool {
        payments.contains { $0.status == .pending && $0.isCard }
    }

    /// Money still settling on the invoice (bank debit / pay later): it
    /// can't be cancelled from the app, and the balance can't be collected
    /// twice meanwhile.
    static func processingCents(_ payments: [Payment]) -> Int {
        payments.filter { $0.status == .processing }.reduce(0) { $0 + $1.amountCents }
    }

    // MARK: - Actions

    /// Issues a draft (needs a line) and stamps sent_at; re-sending an
    /// issued invoice re-stamps it. Void invoices cannot be sent.
    @discardableResult
    static func markSent(invoiceID: UUID) async throws -> Invoice {
        try await Supa.client
            .rpc("mark_invoice_sent", params: ["p_invoice_id": invoiceID.uuidString])
            .execute()
            .value
    }

    /// Sends the shop's `invoice_sent` wording with this invoice's pay link
    /// (`/i/<token>`), total and balance, rendered and queued by the server
    /// (`messaging` send with `invoice_id`), so invoices without a job (and
    /// jobs with several invoices) get their own link and balance. `nonce`
    /// is one per compose, reused on a retry.
    static func sendInvoiceMessage(
        shopID: UUID,
        invoice: Invoice,
        channel: MoneyMessageChannel,
        nonce: String
    ) async throws -> MoneyMessageResult {
        switch invoice.status {
        case .draft:
            throw AppError.invalidInput("Send the invoice first so it's issued and can be paid.")
        case .void:
            throw AppError.invalidInput("A void invoice can't be sent.")
        case .open, .partiallyPaid, .paid:
            break
        }
        return try await MoneyDocumentMessage.send(
            shopID: shopID,
            request: MoneyDocumentMessage.Request(kind: .invoiceSent, id: invoice.id, channel: channel),
            nonce: nonce
        )
    }

    /// Owner/admin: voids the invoice (`void_invoice`). Job payments are
    /// detached back to the job; refused while a payment is in flight.
    @discardableResult
    static func void(invoiceID: UUID, reason: String?) async throws -> Invoice {
        let params: [String: AnyJSON] = [
            "p_invoice_id": .string(invoiceID.uuidString),
            "p_reason": reason?.trimmedNonEmpty.map { AnyJSON.string($0) } ?? .null,
        ]
        return try await Supa.client
            .rpc("void_invoice", params: params)
            .execute()
            .value
    }
}
