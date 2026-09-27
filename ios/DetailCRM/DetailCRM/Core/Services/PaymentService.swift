//
//  PaymentService.swift
//  DetailCRM
//
//  Payments: the ledger, manual (cash/check/…) payments, and the card
//  actions of the `payments` edge function (PaymentSheet on the shop's
//  connected Stripe account, charge a saved card, refunds). Every amount is
//  derived server-side; the app may only request a partial amount or a tip,
//  which the server bounds (0 < amount ≤ balance, 0 ≤ tip ≤ balance).
//
//  Also home to the small edge-function helper (`MoneyEdge`) and the client
//  link builder (`MoneyLinks`) shared by the money services.
//

import Foundation
import Supabase
import DetailCore

// MARK: - Edge-function calls

/// Error body every edge function returns: `{ error, code, details }`.
private struct MoneyEdgeErrorBody: Decodable {
    let error: String?
    let code: String?
    let details: MoneyEdgeErrorDetails?
}

private struct MoneyEdgeErrorDetails: Decodable {
    let reason: String?
}

/// A refused edge-function request with the server's human message, its
/// stable `code` (e.g. `payment_failed`, `conflict`) and `details.reason`.
struct MoneyEdgeError: LocalizedError, Equatable {
    let status: Int
    let code: String?
    let reason: String?
    let message: String

    var errorDescription: String? { message }

    /// Off-session charge needs the customer (3-D Secure): send a pay link.
    var needsCustomerAuthentication: Bool {
        reason == "authentication_required"
    }
}

enum MoneyEdge {

    /// Canonical lowercase id for edge-function bodies (Postgres renders
    /// uuids in lowercase and some functions compare ids as strings).
    static func wire(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    /// A url-safe per-request nonce so a network retry of the same tap
    /// reuses Stripe's idempotency key while a new tap gets a new one.
    static func newNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Invokes an edge function with a JSON body and decodes the reply;
    /// non-2xx replies become `MoneyEdgeError` with the server's wording.
    static func invoke<Body: Encodable, Reply: Decodable>(
        _ functionName: String,
        body: Body
    ) async throws -> Reply {
        do {
            let reply: Reply = try await Supa.client.functions.invoke(
                functionName,
                options: FunctionInvokeOptions(body: body)
            )
            return reply
        } catch let error as FunctionsError {
            throw readable(error)
        }
    }

    static func readable(_ error: FunctionsError) -> Error {
        switch error {
        case .httpError(let status, let data):
            let body = try? JSONDecoder().decode(MoneyEdgeErrorBody.self, from: data)
            let message = body?.error?.trimmedNonEmpty
                ?? "The request failed (\(status)). Try again."
            return MoneyEdgeError(
                status: status,
                code: body?.code,
                reason: body?.details?.reason,
                message: ErrorText.sentence(message)
            )
        case .relayError:
            return MoneyEdgeError(
                status: 0,
                code: "relay_error",
                reason: nil,
                message: "Couldn't reach the server. Try again."
            )
        }
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
/// `invoice_sent` wording and the document's own client link.
///
/// The messaging function's template path only knows job-level variables
/// (a quote being sent has no job; an ad-hoc invoice has none either), so
/// — like the web app — the template is rendered here with the link and the
/// server's totals (`TemplateRenderer` matches `render_template` exactly)
/// and sent as a free-form message (manager+; consent and opt-outs are
/// still enforced by the server).
enum MoneyDocumentMessage {

    struct Request: Sendable {
        var template: MoneyDocumentTemplate
        var customerID: UUID
        /// Links the message to the job's history when there is one.
        var jobID: UUID?
        var channel: MoneyMessageChannel
        var link: URL
        /// Server totals (invoices only; formatted like the server does).
        var amountCents: Int?
        var balanceCents: Int?
    }

    static func send(shopID: UUID, request: Request) async throws -> MoneyMessageResult {
        async let templateTask = template(shopID: shopID, key: request.template, channel: request.channel)
        async let shopTask = shop(shopID: shopID)
        async let customerTask = QuoteService.customer(shopID: shopID, customerID: request.customerID)
        let (template, shop, customer) = try await (templateTask, shopTask, customerTask)
        guard let customer else { throw AppError.notFound("That customer") }
        if let template, !template.enabled {
            let kind = request.channel == .sms ? "text" : "email"
            let noun = request.template.documentNoun
            throw AppError.message(
                "Your shop's \"\(noun) sent\" \(kind) is turned off. Turn it on in Settings, or share the link yourself."
            )
        }

        let values = variables(request: request, customer: customer, shop: shop)
        let body: String
        var subject: String?
        if let template {
            body = TemplateRenderer.render(template.body, values: values)
            subject = template.subject.map { TemplateRenderer.render($0, values: values) }
        } else {
            let first = values["customer_first_name"] ?? "there"
            body = "Hi \(first), here is your \(request.template.documentNoun) from \(shop.name): \(request.link.absoluteString)"
        }
        guard body.trimmedNonEmpty != nil else {
            throw AppError.message("The message template produced an empty message.")
        }
        if request.channel == .sms {
            subject = nil
            if body.count > 1600 {
                throw AppError.invalidInput("The text is longer than 1,600 characters. Shorten the template or send an email.")
            }
        } else if subject?.trimmedNonEmpty == nil {
            subject = "Your \(request.template.documentNoun) from \(shop.name)"
        }

        struct Body: Encodable {
            let action = "send"
            let shop_id: String
            let customer_id: String
            let job_id: String?
            let channel: String
            let subject: String?
            let body: String
        }
        return try await MoneyEdge.invoke(
            "messaging",
            body: Body(
                shop_id: MoneyEdge.wire(shopID),
                customer_id: MoneyEdge.wire(request.customerID),
                job_id: request.jobID.map { MoneyEdge.wire($0) },
                channel: request.channel.rawValue,
                subject: subject,
                body: body
            )
        )
    }

    /// The shop's wording for this template and channel (nil when missing).
    static func template(
        shopID: UUID,
        key: MoneyDocumentTemplate,
        channel: MoneyMessageChannel
    ) async throws -> MoneyTemplateRow? {
        let rows: [MoneyTemplateRow] = try await Supa.client
            .from("message_templates")
            .select(MoneyTemplateRow.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("key", value: key.rawValue)
            .eq("channel", value: channel.rawValue)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    static func shop(shopID: UUID) async throws -> MoneyMessageShopRow {
        let rows: [MoneyMessageShopRow] = try await Supa.client
            .from("shops")
            .select(MoneyMessageShopRow.selectColumns)
            .eq("id", value: shopID.uuidString)
            .limit(1)
            .execute()
            .value
        guard let shop = rows.first else { throw AppError.notFound("Your shop") }
        return shop
    }

    /// Template variables, formatted like the server's comms variables
    /// (`comms_customer_vars` + the document's link and totals).
    static func variables(
        request: Request,
        customer: QuoteCustomerRef,
        shop: MoneyMessageShopRow
    ) -> [String: String] {
        let first = customer.firstName?.trimmedNonEmpty
            ?? customer.company?.trimmedNonEmpty
            ?? customer.lastName?.trimmedNonEmpty
            ?? "there"
        let person = [customer.firstName?.trimmedNonEmpty, customer.lastName?.trimmedNonEmpty]
            .compactMap { $0 }
            .joined(separator: " ")
        var values: [String: String] = [
            "customer_first_name": first,
            "customer_name": person.isEmpty ? (customer.company?.trimmedNonEmpty ?? "") : person,
            "shop_name": shop.name,
            "shop_phone": shop.phone?.trimmedNonEmpty.map { PhoneNumber.format($0) } ?? "",
            "review_link": shop.reviewURL?.trimmedNonEmpty ?? "",
            "booking_page_link": bookingPageLink(slug: shop.slug) ?? "",
        ]
        values[request.template.linkVariable] = request.link.absoluteString
        if let amount = request.amountCents {
            values["amount"] = serverMoneyText(cents: amount, currency: shop.currency)
        }
        if let balance = request.balanceCents {
            values["balance"] = serverMoneyText(cents: max(balance, 0), currency: shop.currency)
        }
        return values
    }

    private static func bookingPageLink(slug: String) -> String? {
        guard let base = AppConfig.webAppURL, let slug = slug.trimmedNonEmpty else { return nil }
        return base.appendingPathComponent("book").appendingPathComponent(slug).absoluteString
    }

    /// Same text as SQL `format_money` (e.g. "$1,234.56", "EUR"-style code
    /// prefix for currencies without a symbol), so a message reads the same
    /// whether the app or the server rendered it.
    static func serverMoneyText(cents: Int, currency: String) -> String {
        let code = currency.lowercased()
        let symbol: String
        switch code {
        case "usd", "cad", "aud", "nzd": symbol = "$"
        case "eur": symbol = "€"
        case "gbp": symbol = "£"
        case "jpy": symbol = "¥"
        default: symbol = code.uppercased() + " "
        }
        let magnitude = cents.magnitude
        let number: String
        if zeroDecimalCurrencies.contains(code) {
            number = grouped(magnitude)
        } else {
            let fraction = magnitude % 100
            number = grouped(magnitude / 100) + "." + (fraction < 10 ? "0" : "") + String(fraction)
        }
        return (cents < 0 ? "-" : "") + symbol + number
    }

    private static let zeroDecimalCurrencies: Set<String> = [
        "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf",
        "ugx", "vnd", "vuv", "xaf", "xof", "xpf",
    ]

    /// 1234567 → "1,234,567".
    private static func grouped(_ value: UInt) -> String {
        let digits = Array(String(value))
        var text = ""
        for (index, digit) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 {
                text.append(",")
            }
            text.append(digit)
        }
        return text
    }
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

    /// Manager+: charges a saved card off-session (default card when
    /// `paymentMethodID` is nil). Throws `MoneyEdgeError` with
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
