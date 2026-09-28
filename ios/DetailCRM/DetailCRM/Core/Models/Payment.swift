//
//  Payment.swift
//  DetailCRM
//
//  Payments (card rows are written only by the Stripe webhook / payments
//  edge function; manual rows only via record_manual_payment), saved card
//  references (Stripe ids + brand/last4 only — never card numbers), and the
//  payments / messaging edge-function responses the money screens use.
//

import Foundation
import DetailCore

// table: payments
struct Payment: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var invoiceID: UUID?
    var jobID: UUID?
    var customerID: UUID
    var membershipID: UUID?
    var kind: PaymentKind
    var method: PaymentMethod
    var status: PaymentStatus
    /// Excludes the tip.
    var amountCents: Int
    var tipCents: Int
    /// Refunded part of the whole charge (amount first, then tip).
    var refundedCents: Int
    var stripePaymentIntentID: String?
    /// Stripe's payment method type as the webhook saw it (`card`,
    /// `us_bank_account`, `affirm`, `klarna`, `afterpay_clearpay`, `link`,
    /// …); nil for manual and gift card payments.
    var stripeMethodType: String?
    var cardBrand: String?
    var cardLast4: String?
    var note: String?
    var recordedBy: UUID?
    var paidAt: Date?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case invoiceID = "invoice_id"
        case jobID = "job_id"
        case customerID = "customer_id"
        case membershipID = "membership_id"
        case kind
        case method
        case status
        case amountCents = "amount_cents"
        case tipCents = "tip_cents"
        case refundedCents = "refunded_cents"
        case stripePaymentIntentID = "stripe_payment_intent_id"
        case stripeMethodType = "stripe_method_type"
        case cardBrand = "card_brand"
        case cardLast4 = "card_last4"
        case note
        case recordedBy = "recorded_by"
        case paidAt = "paid_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Stripe charge/session ids are deliberately not selected.
    static let selectColumns = [
        "id", "shop_id", "invoice_id", "job_id", "customer_id", "membership_id", "kind",
        "method", "status", "amount_cents", "tip_cents", "refunded_cents",
        "stripe_payment_intent_id", "stripe_method_type", "card_brand", "card_last4", "note",
        "recorded_by", "paid_at", "created_at", "updated_at",
    ].joined(separator: ",")

    var isCard: Bool { method == .card || method == .cardPresent }

    /// Taken through Stripe (card, in person, bank debit, pay later): the
    /// `payments` function refunds it through Stripe. Cash / check / bank
    /// transfer / other and gift card payments are refunded by
    /// `refund_manual_payment` (a gift card payment goes back onto the card).
    var isStripeBacked: Bool {
        switch method {
        case .card, .cardPresent, .achDebit, .bnpl: return true
        case .cash, .check, .bankTransfer, .other, .giftCard: return false
        }
    }

    /// Money on its way that the balance doesn't count yet: an unfinished
    /// card attempt (`pending`) or a bank debit / pay-later payment that
    /// Stripe is still settling (`processing`, can take several days).
    var isInFlight: Bool { status == .pending || status == .processing }

    /// The server's `payment_in_flight` (0064), which caps what a gift card,
    /// store credit or another payment may still apply: processing, or a
    /// pending attempt opened within the last hour (older ones no longer
    /// hold the balance).
    func holdsBalance(at now: Date) -> Bool {
        switch status {
        case .processing: return true
        case .pending: return createdAt > now.addingTimeInterval(-Self.pendingHoldSeconds)
        default: return false
        }
    }

    /// How long an unfinished attempt holds the balance (`payment_in_flight`).
    static let pendingHoldSeconds: TimeInterval = 60 * 60

    /// Money the server counts as on its way on these payments (amounts
    /// without tips, like `payment_in_flight` sums).
    static func inFlightCents(_ payments: [Payment], at now: Date) -> Int {
        payments.filter { $0.holdsBalance(at: now) }.reduce(0) { $0 + $1.amountCents }
    }

    /// "Visa •••• 4242", "Bank debit (ACH)", "Klarna", or the method name.
    var methodLabel: String {
        if isCard, let last4 = cardLast4 {
            let brand = cardBrand.map { MoneyCardBrand.displayName($0) } ?? "Card"
            return "\(brand) •••• \(last4)"
        }
        if method == .bnpl, let provider = Self.payLaterProviderName(stripeMethodType) {
            return provider
        }
        return method.displayName
    }

    /// The pay-later provider's name for a Stripe payment method type
    /// ("Klarna", "Affirm", …), else nil.
    static func payLaterProviderName(_ stripeMethodType: String?) -> String? {
        switch stripeMethodType?.lowercased() {
        case "affirm": return "Affirm"
        case "klarna": return "Klarna"
        case "afterpay_clearpay": return "Afterpay"
        case "zip": return "Zip"
        default: return nil
        }
    }

    /// One line explaining a payment that is still settling, or nil.
    var processingNote: String? {
        guard status == .processing else { return nil }
        switch method {
        case .achDebit:
            return "Bank payments take a few business days to clear. It counts toward the balance once the bank confirms it."
        case .bnpl:
            return "The pay-later provider is confirming this payment. It counts toward the balance once Stripe confirms it."
        default:
            return "Stripe is still confirming this payment. It counts toward the balance once it clears."
        }
    }

    /// Amount + tip still refundable (for the refund sheet's default).
    var refundableCents: Int {
        max(0, amountCents + tipCents - refundedCents)
    }

    /// Received money that can still be (partly) refunded.
    var isRefundable: Bool {
        (status == .succeeded || status == .partiallyRefunded) && refundableCents > 0
    }

    /// The moment to show in lists: when it was paid, else when created.
    var displayDate: Date { paidAt ?? createdAt }
}

// table: customer_payment_methods
struct SavedCard: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var customerID: UUID
    var stripePaymentMethodID: String
    var brand: String?
    var last4: String?
    var expMonth: Int?
    var expYear: Int?
    var isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case customerID = "customer_id"
        case stripePaymentMethodID = "stripe_payment_method_id"
        case brand
        case last4
        case expMonth = "exp_month"
        case expYear = "exp_year"
        case isDefault = "is_default"
    }

    static let selectColumns = "id,customer_id,stripe_payment_method_id,brand,last4,exp_month,exp_year,is_default"

    /// "Visa •••• 4242 · 08/27"
    var label: String {
        let brandName = brand.map { MoneyCardBrand.displayName($0) } ?? "Card"
        var text = "\(brandName) •••• \(last4 ?? "????")"
        if let expMonth, let expYear {
            text += String(format: " · %02d/%02d", expMonth, expYear % 100)
        }
        return text
    }
}

/// Human card brand names from Stripe's brand codes.
enum MoneyCardBrand {
    static func displayName(_ code: String) -> String {
        switch code.lowercased() {
        case "visa": return "Visa"
        case "mastercard": return "Mastercard"
        case "amex", "american_express": return "Amex"
        case "discover": return "Discover"
        case "diners": return "Diners Club"
        case "jcb": return "JCB"
        case "unionpay": return "UnionPay"
        default: return code.capitalized
        }
    }
}

// MARK: - payments edge function responses
//
// These are edge-function payloads (not tables or RPCs), so they decode
// with their own key enums instead of `CodingKeys`.

/// `payments` → `payment_sheet`: everything StripePaymentSheet needs to take
/// a card payment on the shop's connected account, exactly as returned.
/// The Stripe customer and its ephemeral key are sent to manager+ only
/// (saved cards, SPEC §3); a technician's sheet has neither and takes a
/// new card.
struct PaymentSheetParams: Decodable, Hashable, Sendable {
    var paymentIntentID: String
    var clientSecret: String
    /// Manager+ only (nil for technicians).
    var ephemeralKeySecret: String?
    /// Stripe customer id on the connected account; manager+ only.
    var customerID: String?
    var publishableKey: String
    /// Connected account (`acct_…`) the PaymentIntent lives on.
    var stripeAccountID: String
    var amountCents: Int
    var tipCents: Int
    var currency: String

    private enum Keys: String, CodingKey {
        case paymentIntentID = "payment_intent_id"
        case clientSecret = "payment_intent_client_secret"
        case ephemeralKeySecret = "ephemeral_key_secret"
        case customerID = "customer_id"
        case publishableKey = "publishable_key"
        case stripeAccountID = "stripe_account_id"
        case amountCents = "amount_cents"
        case tipCents = "tip_cents"
        case currency
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        paymentIntentID = try c.decode(String.self, forKey: .paymentIntentID)
        clientSecret = try c.decode(String.self, forKey: .clientSecret)
        ephemeralKeySecret = try c.decodeIfPresent(String.self, forKey: .ephemeralKeySecret)
        customerID = try c.decodeIfPresent(String.self, forKey: .customerID)
        publishableKey = try c.decode(String.self, forKey: .publishableKey)
        stripeAccountID = try c.decode(String.self, forKey: .stripeAccountID)
        amountCents = try c.decode(Int.self, forKey: .amountCents)
        tipCents = try c.decodeIfPresent(Int.self, forKey: .tipCents) ?? 0
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "usd"
    }

    /// What the card will be charged (amount + tip), per the server.
    var chargeCents: Int { amountCents + tipCents }

    /// The customer + ephemeral key pair, only when the server sent both
    /// (lets PaymentSheet offer and save the customer's cards).
    var customerCredentials: (customerID: String, ephemeralKeySecret: String)? {
        guard let customerID = customerID?.trimmedNonEmpty,
              let ephemeralKeySecret = ephemeralKeySecret?.trimmedNonEmpty else { return nil }
        return (customerID, ephemeralKeySecret)
    }
}

/// `payments` → `setup_card` (manager+): an off-session SetupIntent on the
/// shop's connected account plus the Stripe customer and its ephemeral
/// key — everything StripePaymentSheet needs in setup mode to save a card
/// without charging it. The webhook (`setup_intent.succeeded`) stores the
/// card (brand / last4 / expiry only) on the customer.
struct MoneySetupCardParams: Decodable, Hashable, Sendable {
    var setupIntentID: String
    var clientSecret: String
    var ephemeralKeySecret: String
    var customerID: String
    var publishableKey: String
    /// Connected account (`acct_…`) the SetupIntent lives on.
    var stripeAccountID: String

    private enum Keys: String, CodingKey {
        case setupIntentID = "setup_intent_id"
        case clientSecret = "setup_intent_client_secret"
        case ephemeralKeySecret = "ephemeral_key_secret"
        case customerID = "customer_id"
        case publishableKey = "publishable_key"
        case stripeAccountID = "stripe_account_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        setupIntentID = try c.decode(String.self, forKey: .setupIntentID)
        clientSecret = try c.decode(String.self, forKey: .clientSecret)
        ephemeralKeySecret = try c.decode(String.self, forKey: .ephemeralKeySecret)
        customerID = try c.decode(String.self, forKey: .customerID)
        publishableKey = try c.decode(String.self, forKey: .publishableKey)
        stripeAccountID = try c.decode(String.self, forKey: .stripeAccountID)
    }
}

/// `payments` → `cancel_open_payments`: what releasing an invoice did.
/// Unconfirmed PaymentSheet attempts are cancelled and open pay-link
/// sessions expired; payments already processing are only counted.
struct MoneyOpenPaymentsRelease: Decodable, Hashable, Sendable {
    var cancelled: Int
    /// Attempts that turned out to have taken the money (now recorded).
    var succeeded: Int
    /// Card payments still processing (never cancelled).
    var inProgress: Int
    var sessionsExpired: Int

    private enum Keys: String, CodingKey {
        case cancelled
        case succeeded
        case inProgress = "in_progress"
        case sessionsExpired = "sessions_expired"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        cancelled = try c.decodeIfPresent(Int.self, forKey: .cancelled) ?? 0
        succeeded = try c.decodeIfPresent(Int.self, forKey: .succeeded) ?? 0
        inProgress = try c.decodeIfPresent(Int.self, forKey: .inProgress) ?? 0
        sessionsExpired = try c.decodeIfPresent(Int.self, forKey: .sessionsExpired) ?? 0
    }
}

/// `payments` → `charge_saved_card`.
struct MoneySavedCardCharge: Decodable, Hashable, Sendable {
    var paymentID: UUID?
    var paymentIntentID: String
    /// `succeeded` or `processing`.
    var status: String
    var amountCents: Int
    var cardBrand: String?
    var cardLast4: String?

    private enum Keys: String, CodingKey {
        case paymentID = "payment_id"
        case paymentIntentID = "payment_intent_id"
        case status
        case amountCents = "amount_cents"
        case cardBrand = "card_brand"
        case cardLast4 = "card_last4"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        paymentID = try c.decodeIfPresent(UUID.self, forKey: .paymentID)
        paymentIntentID = try c.decode(String.self, forKey: .paymentIntentID)
        status = try c.decode(String.self, forKey: .status)
        amountCents = try c.decode(Int.self, forKey: .amountCents)
        cardBrand = try c.decodeIfPresent(String.self, forKey: .cardBrand)
        cardLast4 = try c.decodeIfPresent(String.self, forKey: .cardLast4)
    }

    var succeeded: Bool { status == "succeeded" }
}

/// `payments` → `refund`.
struct MoneyRefundResult: Decodable, Hashable, Sendable {
    var paymentID: UUID
    var refundStatus: String?
    var amountCents: Int

    private enum Keys: String, CodingKey {
        case paymentID = "payment_id"
        case refundStatus = "refund_status"
        case amountCents = "amount_cents"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        paymentID = try c.decode(UUID.self, forKey: .paymentID)
        refundStatus = try c.decodeIfPresent(String.self, forKey: .refundStatus)
        amountCents = try c.decode(Int.self, forKey: .amountCents)
    }
}

/// `payments` → `membership_checkout`: a hosted Checkout link to share.
struct MoneyCheckoutLink: Decodable, Hashable, Sendable {
    var url: URL
    /// Unix seconds when the link stops working.
    var expiresAt: Int?
    var amountCents: Int?

    private enum Keys: String, CodingKey {
        case url
        case expiresAt = "expires_at"
        case amountCents = "amount_cents"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let text = try c.decode(String.self, forKey: .url)
        guard let parsed = URL(string: text), parsed.scheme == "https" else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "not an https URL")
        }
        url = parsed
        expiresAt = try c.decodeIfPresent(Int.self, forKey: .expiresAt)
        amountCents = try c.decodeIfPresent(Int.self, forKey: .amountCents)
    }

    var expiresDate: Date? {
        expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

/// `payments` → `membership_cancel`.
struct MoneyMembershipCancelResult: Decodable, Hashable, Sendable {
    var status: String
    var cancelAtPeriodEnd: Bool

    private enum Keys: String, CodingKey {
        case status
        case cancelAtPeriodEnd = "cancel_at_period_end"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        status = try c.decode(String.self, forKey: .status)
        cancelAtPeriodEnd = try c.decodeIfPresent(Bool.self, forKey: .cancelAtPeriodEnd) ?? false
    }
}

/// `messaging` → `send`.
struct MoneyMessageResult: Decodable, Hashable, Sendable {
    var messageID: UUID?
    /// sent | failed | queued | sending | cancelled
    var status: String
    var error: String?

    private enum Keys: String, CodingKey {
        case messageID = "message_id"
        case status
        case error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        messageID = try c.decodeIfPresent(UUID.self, forKey: .messageID)
        status = try c.decode(String.self, forKey: .status)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    var failed: Bool { status == "failed" || status == "cancelled" }
}

/// Quote / invoice message templates the money screens send.
enum MoneyDocumentTemplate: String, Hashable, Sendable {
    case quoteSent = "quote_sent"
    case invoiceSent = "invoice_sent"

    var documentNoun: String {
        switch self {
        case .quoteSent: return "quote"
        case .invoiceSent: return "invoice"
        }
    }
}

/// What a quote / invoice message will say, rendered by the server.
// rpc: preview_document_message
struct MoneyDocumentPreview: Codable, Hashable, Sendable {
    /// The shop's template for this channel is turned on.
    var enabled: Bool
    /// The customer's number / email for the channel (nil when missing).
    var toAddress: String?
    /// Email only.
    var subject: String?
    var body: String

    enum CodingKeys: String, CodingKey {
        case enabled
        case toAddress = "to_address"
        case subject
        case body
    }
}

/// `payments` → `remove_saved_card`.
struct MoneySavedCardRemoval: Decodable, Hashable, Sendable {
    var removed: Bool

    private enum Keys: String, CodingKey {
        case removed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        removed = try c.decodeIfPresent(Bool.self, forKey: .removed) ?? false
    }
}

/// Channel for templated customer messages.
enum MoneyMessageChannel: String, CaseIterable, Identifiable, Hashable, Sendable {
    case sms
    case email

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sms: return "Text message"
        case .email: return "Email"
        }
    }

    var systemImage: String {
        switch self {
        case .sms: return "message"
        case .email: return "envelope"
        }
    }
}

// MARK: - Payments ledger summary

// rpc: report_payments
struct PaymentsLedgerMethodRow: Codable, Hashable, Sendable {
    var method: PaymentMethod
    var paymentsCount: Int
    var grossCents: Int
    var refundsCents: Int
    var netCents: Int
    var tipsCents: Int
    var tipRefundsCents: Int
    var collectedCents: Int

    enum CodingKeys: String, CodingKey {
        case method
        case paymentsCount = "payments_count"
        case grossCents = "gross_cents"
        case refundsCents = "refunds_cents"
        case netCents = "net_cents"
        case tipsCents = "tips_cents"
        case tipRefundsCents = "tip_refunds_cents"
        case collectedCents = "collected_cents"
    }
}

/// Server-computed totals for a ledger range (sums of `report_payments`
/// rows, all of which the server already derived).
struct PaymentsLedgerSummary: Hashable, Sendable {
    var collectedCents: Int
    var netCents: Int
    var tipsCents: Int
    var refundsCents: Int
    var count: Int

    init(rows: [PaymentsLedgerMethodRow]) {
        collectedCents = rows.reduce(0) { $0 + $1.collectedCents }
        netCents = rows.reduce(0) { $0 + $1.netCents }
        tipsCents = rows.reduce(0) { $0 + $1.tipsCents }
        refundsCents = rows.reduce(0) { $0 + $1.refundsCents + $1.tipRefundsCents }
        count = rows.reduce(0) { $0 + $1.paymentsCount }
    }
}
