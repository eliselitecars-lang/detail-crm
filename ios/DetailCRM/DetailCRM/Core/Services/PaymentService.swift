//
//  PaymentService.swift
//  DetailCRM
//
//  Payments: the ledger, manual (cash/check/…) payments, and the card
//  actions of the `payments` edge function (PaymentSheet on the shop's
//  connected Stripe account, charge a saved card, refunds, saved-card
//  removal). Every amount is derived server-side; the app may only request
//  a partial amount or a tip, which the server bounds (0 < amount ≤
//  balance, 0 ≤ tip ≤ balance).
//
//  Also home to the small edge-function helper (`MoneyEdge`), the client
//  link builder (`MoneyLinks`) and the quote / invoice message sender
//  (`MoneyDocumentMessage`) shared by the money services.
//

import Foundation
import Supabase
import DetailCore

// MARK: - Edge-function calls

enum MoneyEdge {

    /// Canonical lowercase id for edge-function bodies (Postgres renders
    /// uuids in lowercase and some functions compare ids as strings).
    static func wire(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    /// A url-safe per-request nonce (32 hex characters) so a network retry
    /// of the same tap reuses Stripe's idempotency key / the message the
    /// database already queued, while a new tap gets a new one.
    static func newNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Invokes an edge function with a JSON body and decodes the reply;
    /// non-2xx replies become `EdgeFunctionError` with the server's wording
    /// (see `EdgeErrorDecoder`).
    static func invoke<Body: Encodable, Reply: Decodable>(
        _ functionName: String,
        body: Body
    ) async throws -> Reply {
        try await EdgeFunctions.invoke(functionName, body: body)
    }
}

// MARK: - Client links

/// Public client links on the web app (`WEB_APP_URL`): `/q/<token>` for
/// quotes and `/i/<token>` for invoices. nil until WEB_APP_URL is set.
enum MoneyLinks {
    static func quote(token: UUID) -> URL? {
        link(kind: "q", token: token)
    }

    static func invoice(token: UUID) -> URL? {
        link(kind: "i", token: token)
    }

    private static func link(kind: String, token: UUID) -> URL? {
        guard let base = AppConfig.webAppURL else { return nil }
        return base
            .appendingPathComponent(kind)
            .appendingPathComponent(token.uuidString.lowercased())
    }
}

// MARK: - Quote / invoice messages

/// Sends a quote or invoice to the customer with the shop's `quote_sent` /
/// `invoice_sent` wording. The database renders and queues the message
/// (`enqueue_document_message`, through the `messaging` function's `send`
/// with `quote_id` / `invoice_id`) with the document's own link, total and
/// balance, so the text is exactly what the web app sends. Manager+ only;
/// consent and opt-outs are enforced by the server.
enum MoneyDocumentMessage {

    struct Request: Hashable, Sendable {
        var kind: MoneyDocumentTemplate
        /// The quote id (`quoteSent`) or invoice id (`invoiceSent`).
        var id: UUID
        var channel: MoneyMessageChannel
    }

    /// Sends the message. `nonce` is one per compose, reused on a retry of
    /// it: the database then returns the message it already queued instead
    /// of sending a second copy.
    static func send(shopID: UUID, request: Request, nonce: String) async throws -> MoneyMessageResult {
        let body = MoneyDocumentSendBody(
            shop_id: MoneyEdge.wire(shopID),
            channel: request.channel.rawValue,
            template_key: request.kind.rawValue,
            quote_id: request.kind == .quoteSent ? MoneyEdge.wire(request.id) : nil,
            invoice_id: request.kind == .invoiceSent ? MoneyEdge.wire(request.id) : nil,
            request_nonce: nonce
        )
        do {
            return try await MoneyEdge.invoke("messaging", body: body)
        } catch let error as EdgeFunctionError where error.reason == "template_disabled" {
            throw AppError.message(disabledText(request))
        }
    }

    /// What the message will say (`preview_document_message`), rendered by
    /// the server with the document's link as it reads once sent. nil when
    /// the shop has no such template.
    static func preview(request: Request) async throws -> MoneyDocumentPreview? {
        let params = MoneyDocumentPreviewParams(
            p_quote_id: request.kind == .quoteSent ? request.id : nil,
            p_invoice_id: request.kind == .invoiceSent ? request.id : nil,
            p_channel: request.channel.rawValue
        )
        do {
            let rows: [MoneyDocumentPreview] = try await Supa.client
                .rpc("preview_document_message", params: params)
                .execute()
                .value
            return rows.first
        } catch let error as PostgrestError where error.code == "P0002" && error.message.lowercased().contains("template") {
            return nil
        }
    }

    /// "Your shop's "quote sent" text is turned off. …"
    static func disabledText(_ request: Request) -> String {
        let kind = request.channel == .sms ? "text" : "email"
        return "Your shop's \"\(request.kind.documentNoun) sent\" \(kind) is turned off. Turn it on in Settings, or share the link yourself."
    }
}

/// `messaging` / `send` for a document. nil fields are omitted (the
/// function's schema is strict and rejects nulls and unknown keys).
private struct MoneyDocumentSendBody: Encodable {
    var action = "send"
    let shop_id: String
    let channel: String
    let template_key: String
    let quote_id: String?
    let invoice_id: String?
    let request_nonce: String
}

/// Exactly one of the two ids is sent (nil ids are omitted).
private struct MoneyDocumentPreviewParams: Encodable {
    let p_quote_id: UUID?
    let p_invoice_id: UUID?
    let p_channel: String
}

// MARK: - Payment service

enum PaymentService {

    // MARK: Ledger

    struct LedgerData: Sendable {
        var payments: [Payment]
        var customers: [UUID: QuoteCustomerRef]
        var summary: PaymentsLedgerSummary
        /// Per-method rows from the server (for the method filter).
        var methodRows: [PaymentsLedgerMethodRow]
        /// More (older) payments in the range beyond the rows loaded.
        var hasMore: Bool = false

        /// Appends the next page of rows (the summary covers the whole range).
        func appending(_ page: LedgerPage) -> LedgerData {
            let known = Set(payments.map { $0.id })
            var merged = self
            merged.payments += page.payments.filter { !known.contains($0.id) }
            merged.customers.merge(page.customers) { current, _ in current }
            merged.hasMore = page.hasMore
            return merged
        }
    }

    struct LedgerPage: Sendable {
        var payments: [Payment]
        var customers: [UUID: QuoteCustomerRef]
        var hasMore: Bool
    }

    /// Ledger rows per page ("Load more" fetches the next page).
    static let ledgerPageSize = 200

    /// Received payments whose `paid_at` falls in [start, end) (first page)
    /// plus the server-computed totals for the same shop-local days
    /// (`report_payments`, inclusive `fromDay`…`toDay`).
    static func ledger(
        shopID: UUID,
        start: Date,
        end: Date,
        fromDay: String,
        toDay: String,
        method: PaymentMethod?
    ) async throws -> LedgerData {
        let page = try await ledgerPage(shopID: shopID, start: start, end: end, method: method, offset: 0)

        struct Params: Encodable {
            let p_shop_id: UUID
            let p_from: String
            let p_to: String
        }
        let rows: [PaymentsLedgerMethodRow] = try await Supa.client
            .rpc("report_payments", params: Params(p_shop_id: shopID, p_from: fromDay, p_to: toDay))
            .execute()
            .value
        let counted = method.map { wanted in rows.filter { $0.method == wanted } } ?? rows

        return LedgerData(
            payments: page.payments,
            customers: page.customers,
            summary: PaymentsLedgerSummary(rows: counted),
            methodRows: rows,
            hasMore: page.hasMore
        )
    }

    /// One page of received payments in [start, end), newest first.
    static func ledgerPage(
        shopID: UUID,
        start: Date,
        end: Date,
        method: PaymentMethod?,
        offset: Int
    ) async throws -> LedgerPage {
        var query = Supa.client
            .from("payments")
            .select(Payment.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .gte("paid_at", value: Supa.iso(start))
            .lt("paid_at", value: Supa.iso(end))
        if let method {
            query = query.eq("method", value: method.rawValue)
        }
        // One extra row tells whether another page exists.
        let first = max(0, offset)
        var payments: [Payment] = try await query
            .order("paid_at", ascending: false)
            .order("id", ascending: false)
            .range(from: first, to: first + ledgerPageSize)
            .execute()
            .value
        let hasMore = payments.count > ledgerPageSize
        if hasMore { payments = Array(payments.prefix(ledgerPageSize)) }
        let customers = try await customerRefs(shopID: shopID, ids: payments.map { $0.customerID })
        return LedgerPage(payments: payments, customers: customers, hasMore: hasMore)
    }

    /// Customer names for a set of ids (one query).
    static func customerRefs(shopID: UUID, ids: [UUID]) async throws -> [UUID: QuoteCustomerRef] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [:] }
        var result: [UUID: QuoteCustomerRef] = [:]
        // Keep URLs short: chunks of 100 ids.
        var index = 0
        while index < unique.count {
            let chunk = Array(unique[index..<min(index + 100, unique.count)])
            let rows: [QuoteCustomerRef] = try await Supa.client
                .from("customers")
                .select(QuoteCustomerRef.selectColumns)
                .eq("shop_id", value: shopID.uuidString)
                .in("id", values: chunk.map { $0.uuidString })
                .execute()
                .value
            for row in rows { result[row.id] = row }
            index += 100
        }
        return result
    }

    // MARK: Invoice payments

    /// Payments recorded against an invoice, newest first.
    static func payments(shopID: UUID, invoiceID: UUID) async throws -> [Payment] {
        try await Supa.client
            .from("payments")
            .select(Payment.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("invoice_id", value: invoiceID.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// Cash / check / bank transfer / other (`record_manual_payment`).
    /// 0 < amount ≤ balance; the tip never counts toward the balance.
    static func recordManualPayment(
        invoiceID: UUID,
        amountCents: Int,
        method: PaymentMethod,
        tipCents: Int,
        note: String?
    ) async throws -> Payment {
        guard PaymentMethod.manualMethods.contains(method) else {
            throw AppError.invalidInput("Card payments are recorded automatically by Stripe.")
        }
        struct Params: Encodable {
            let p_invoice_id: UUID
            let p_amount_cents: Int
            let p_method: String
            let p_tip_cents: Int
            let p_note: String?

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: ParamKeys.self)
                try c.encode(p_invoice_id, forKey: .p_invoice_id)
                try c.encode(p_amount_cents, forKey: .p_amount_cents)
                try c.encode(p_method, forKey: .p_method)
                try c.encode(p_tip_cents, forKey: .p_tip_cents)
                // Explicit null keeps the call matching the function signature.
                try c.encode(p_note, forKey: .p_note)
            }

            enum ParamKeys: String, CodingKey {
                case p_invoice_id, p_amount_cents, p_method, p_tip_cents, p_note
            }
        }
        return try await Supa.client
            .rpc("record_manual_payment", params: Params(
                p_invoice_id: invoiceID,
                p_amount_cents: amountCents,
                p_method: method.rawValue,
                p_tip_cents: max(0, tipCents),
                p_note: note?.trimmedNonEmpty
            ))
            .execute()
            .value
    }

    /// Owner/admin: money handed back for a manual payment
    /// (`refund_manual_payment`; refunded from the amount first, then tip).
    static func refundManualPayment(paymentID: UUID, amountCents: Int) async throws -> Payment {
        struct Params: Encodable {
            let p_payment_id: UUID
            let p_amount_cents: Int
        }
        return try await Supa.client
            .rpc("refund_manual_payment", params: Params(p_payment_id: paymentID, p_amount_cents: amountCents))
            .execute()
            .value
    }

    // MARK: Card actions (payments edge function)

    /// PaymentIntent on the shop's connected account for the invoice balance
    /// (or a partial `amountCents` ≤ balance) plus an optional tip.
    /// `ephemeralKeyAPIVersion` is the Stripe SDK's own API version
    /// (`STPAPIClient.apiVersion`): the ephemeral key must be created with it.
    static func paymentSheet(
        shopID: UUID,
        invoiceID: UUID,
        amountCents: Int?,
        tipCents: Int,
        nonce: String,
        ephemeralKeyAPIVersion: String
    ) async throws -> PaymentSheetParams {
        struct Body: Encodable {
            let action = "payment_sheet"
            let shop_id: String
            let invoice_id: String
            let amount_cents: Int?
            let tip_cents: Int?
            let request_nonce: String
            let ephemeral_key_api_version: String
        }
        let body = Body(
            shop_id: MoneyEdge.wire(shopID),
            invoice_id: MoneyEdge.wire(invoiceID),
            amount_cents: amountCents,
            tip_cents: tipCents > 0 ? tipCents : nil,
            request_nonce: nonce,
            ephemeral_key_api_version: ephemeralKeyAPIVersion
        )
        return try await MoneyEdge.invoke("payments", body: body)
    }

    /// Releases the invoice (`cancel_open_payments`, same callers as
    /// `paymentSheet`): cancels its unconfirmed PaymentSheet attempts and
    /// expires open pay-link sessions, so an abandoned card sheet stops
    /// blocking cash/check payments and voiding. Payments already
    /// processing are left alone (reported in `inProgress`).
    @discardableResult
    static func cancelOpenPayments(shopID: UUID, invoiceID: UUID) async throws -> MoneyOpenPaymentsRelease {
        struct Body: Encodable {
            let action = "cancel_open_payments"
            let shop_id: String
            let invoice_id: String
        }
        return try await MoneyEdge.invoke(
            "payments",
            body: Body(shop_id: MoneyEdge.wire(shopID), invoice_id: MoneyEdge.wire(invoiceID))
        )
    }

    /// Releases a job before it is cancelled / marked no-show
    /// (`cancel_open_payments` with `job_id`; collectors only): cancels its
    /// unconfirmed card attempts (deposits and its invoice's sheets) and
    /// expires its open deposit / pay links, so nobody can pay for an
    /// appointment that is not happening. Payments already processing are
    /// reported in `inProgress`; ones that went through in `succeeded`. A
    /// shop without Stripe answers with zeros.
    @discardableResult
    static func cancelOpenPayments(shopID: UUID, jobID: UUID) async throws -> MoneyOpenPaymentsRelease {
        struct Body: Encodable {
            let action = "cancel_open_payments"
            let shop_id: String
            let job_id: String
        }
        return try await MoneyEdge.invoke(
            "payments",
            body: Body(shop_id: MoneyEdge.wire(shopID), job_id: MoneyEdge.wire(jobID))
        )
    }

    /// Manager+: removes a customer's saved card (`remove_saved_card`): the
    /// card is detached from the customer in Stripe, then removed from the
    /// CRM. Returns false when the CRM no longer listed it (already gone).
    @discardableResult
    static func removeSavedCard(shopID: UUID, customerID: UUID, paymentMethodID: String) async throws -> Bool {
        struct Body: Encodable {
            let action = "remove_saved_card"
            let shop_id: String
            let customer_id: String
            let payment_method_id: String
        }
        let reply: MoneySavedCardRemoval = try await MoneyEdge.invoke(
            "payments",
            body: Body(
                shop_id: MoneyEdge.wire(shopID),
                customer_id: MoneyEdge.wire(customerID),
                payment_method_id: paymentMethodID
            )
        )
        return reply.removed
    }

    /// Manager+: charges a saved card off-session (default card when
    /// `paymentMethodID` is nil). Throws `EdgeFunctionError` with
    /// `needsCustomerAuthentication` when the bank wants the customer.
    static func chargeSavedCard(
        shopID: UUID,
        invoiceID: UUID,
        paymentMethodID: String?,
        amountCents: Int?,
        nonce: String
    ) async throws -> MoneySavedCardCharge {
        struct Body: Encodable {
            let action = "charge_saved_card"
            let shop_id: String
            let invoice_id: String
            let payment_method_id: String?
            let amount_cents: Int?
            let request_nonce: String
        }
        let body = Body(
            shop_id: MoneyEdge.wire(shopID),
            invoice_id: MoneyEdge.wire(invoiceID),
            payment_method_id: paymentMethodID,
            amount_cents: amountCents,
            request_nonce: nonce
        )
        return try await MoneyEdge.invoke("payments", body: body)
    }

    /// Owner/admin: refunds a card payment through Stripe (full refundable
    /// amount when `amountCents` is nil).
    static func refundCardPayment(shopID: UUID, paymentID: UUID, amountCents: Int?) async throws -> MoneyRefundResult {
        struct Body: Encodable {
            let action = "refund"
            let shop_id: String
            let payment_id: String
            let amount_cents: Int?
        }
        return try await MoneyEdge.invoke(
            "payments",
            body: Body(shop_id: MoneyEdge.wire(shopID), payment_id: MoneyEdge.wire(paymentID), amount_cents: amountCents)
        )
    }

    /// After PaymentSheet completes, the webhook settles the payment. Polls
    /// the payment row a few times; returns its latest status (nil when the
    /// row isn't visible yet).
    static func awaitSettlement(
        shopID: UUID,
        paymentIntentID: String,
        attempts: Int = 8,
        interval: Duration = .milliseconds(1500)
    ) async -> PaymentStatus? {
        var latest: PaymentStatus?
        for attempt in 0..<max(1, attempts) {
            if attempt > 0 {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return latest
                }
            }
            let rows: [Payment]? = try? await Supa.client
                .from("payments")
                .select(Payment.selectColumns)
                .eq("shop_id", value: shopID.uuidString)
                .eq("stripe_payment_intent_id", value: paymentIntentID)
                .limit(1)
                .execute()
                .value
            if let status = rows?.first?.status {
                latest = status
                if status != .pending { return status }
            }
        }
        return latest
    }
}
