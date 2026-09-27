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
        /// Saved cards (manager+ only; empty otherwise).
        var savedCards: [SavedCard]
        /// The customer's pay-link token (manager+ only; nil otherwise).
        var linkToken: UUID?
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
        var cards: [SavedCard] = []
        if includeSavedCards {
            // A failure here must not hide the invoice itself.
            cards = (try? await savedCards(shopID: shopID, customerID: invoice.customerID)) ?? []
        }
        var token: UUID?
        if includeLinkToken {
            // A failure here must not hide the invoice itself.
            token = try? await linkToken(invoiceID: invoiceID)
        }
        return DetailData(
            invoice: invoice, lines: lines, payments: payments, customer: customer,
            savedCards: cards, linkToken: token
        )
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
    /// that was opened but not finished): it blocks cash payments for the
    /// balance and voiding until `PaymentService.cancelOpenPayments`.
    static func hasOpenCardAttempt(_ payments: [Payment]) -> Bool {
        payments.contains { $0.status == .pending && $0.isCard }
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
    /// (`/i/<token>`) and the server's total and balance through the
    /// messaging edge function. Rendered in the app so invoices without a
    /// job (and jobs with several invoices) get their own link and balance.
    static func sendInvoiceMessage(
        shopID: UUID,
        invoice: Invoice,
        channel: MoneyMessageChannel
    ) async throws -> MoneyMessageResult {
        switch invoice.status {
        case .draft:
            throw AppError.invalidInput("Send the invoice first so it's issued and can be paid.")
        case .void:
            throw AppError.invalidInput("A void invoice can't be sent.")
        case .open, .partiallyPaid, .paid:
            break
        }
        let token = try await linkToken(invoiceID: invoice.id)
        guard let link = MoneyLinks.invoice(token: token) else {
            throw AppError.message("Pay links need WEB_APP_URL in the app configuration, so the message can't include the link.")
        }
        return try await MoneyDocumentMessage.send(
            shopID: shopID,
            request: MoneyDocumentMessage.Request(
                template: .invoiceSent,
                customerID: invoice.customerID,
                jobID: invoice.jobID,
                channel: channel,
                link: link,
                amountCents: invoice.totalCents,
                balanceCents: invoice.balanceCents
            )
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
