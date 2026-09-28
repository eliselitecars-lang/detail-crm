//
//  AppNotification.swift
//  DetailCRM
//
//  In-app staff notifications (`public.notifications`, 0031). Rows are
//  created server-side (triggers / definer code); a recipient can only
//  read them, set `read_at` and delete (dismiss) them.
//

import Foundation

/// `notification_kind` enum. Unknown future kinds decode as `.general`
/// (the row keeps its raw `kind` string) so one new kind never breaks the
/// whole list.
enum AppNotificationKind: String, CaseIterable, Sendable {
    case newBooking = "new_booking"
    case bookingCancelled = "booking_cancelled"
    case quoteApproved = "quote_approved"
    case quoteDeclined = "quote_declined"
    case paymentReceived = "payment_received"
    case inboundMessage = "inbound_message"
    case formSigned = "form_signed"
    case general
    case giftCardPurchased = "gift_card_purchased"
    case membershipJoined = "membership_joined"
    case lowStock = "low_stock"
    case inspectionAcknowledged = "inspection_acknowledged"
    case jobAssigned = "job_assigned"
    case jobRescheduled = "job_rescheduled"
    case newLead = "new_lead"
    case taskAssigned = "task_assigned"
    case taskDue = "task_due"
    case smsNumberStatus = "sms_number_status"
    case webhookFailing = "webhook_failing"
    /// The shop's subscription payment failed (0100/0101; owners only).
    /// Neutral on iPhone: a plain notification — no prices, no plan, no
    /// link or call to action toward buying (App Store 3.1.1 / 3.1.3).
    case billingPaymentFailed = "billing_payment_failed"

    var systemImage: String {
        switch self {
        case .newBooking: return "calendar.badge.plus"
        case .bookingCancelled: return "calendar.badge.minus"
        case .quoteApproved: return "checkmark.seal"
        case .quoteDeclined: return "xmark.seal"
        case .paymentReceived: return "dollarsign.circle"
        case .inboundMessage: return "bubble.left"
        case .formSigned: return "signature"
        case .general: return "bell"
        case .giftCardPurchased: return "giftcard"
        case .membershipJoined: return "person.crop.circle.badge.plus"
        case .lowStock: return "shippingbox"
        case .inspectionAcknowledged: return "checkmark.shield"
        case .jobAssigned: return "person.badge.clock"
        case .jobRescheduled: return "calendar.badge.clock"
        case .newLead: return "person.crop.circle.badge.questionmark"
        case .taskAssigned: return "checklist"
        case .taskDue: return "alarm"
        case .smsNumberStatus: return "phone.badge.checkmark"
        case .webhookFailing: return "exclamationmark.arrow.triangle.2.circlepath"
        case .billingPaymentFailed: return "exclamationmark.circle"
        }
    }

    var displayName: String {
        switch self {
        case .newBooking: return "New booking"
        case .bookingCancelled: return "Booking cancelled"
        case .quoteApproved: return "Quote approved"
        case .quoteDeclined: return "Quote declined"
        case .paymentReceived: return "Payment received"
        case .inboundMessage: return "New message"
        case .formSigned: return "Form signed"
        case .general: return "Notification"
        case .giftCardPurchased: return "Gift card purchased"
        case .membershipJoined: return "New membership"
        case .lowStock: return "Low stock"
        case .inspectionAcknowledged: return "Inspection signed by customer"
        case .jobAssigned: return "Job assigned to you"
        case .jobRescheduled: return "Job rescheduled"
        case .newLead: return "New lead"
        case .taskAssigned: return "Task assigned to you"
        case .taskDue: return "Task due"
        case .smsNumberStatus: return "Texting number update"
        case .webhookFailing: return "Webhook failing"
        case .billingPaymentFailed: return "Subscription payment"
        }
    }

    /// Kinds every member may read (`notification_kind_for_managers` is
    /// false for them); every other kind reaches managers and up only. Used
    /// to offer only the push toggles a member can actually receive.
    var isForEveryMember: Bool {
        switch self {
        case .general, .jobAssigned, .jobRescheduled, .taskAssigned, .taskDue:
            return true
        default:
            return false
        }
    }

    /// Staff tasks (opened in the Tasks screen rather than a record).
    var isTaskKind: Bool {
        self == .taskAssigned || self == .taskDue
    }
}

// table: notifications
struct AppNotification: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var shopID: UUID
    var userID: UUID
    /// Raw `notification_kind`; see `kindValue`.
    var kind: String
    var title: String
    var body: String?
    var jobID: UUID?
    /// What the notification is about, for deep links (0031; any may be
    /// null, e.g. after the record was deleted).
    var customerID: UUID?
    var quoteID: UUID?
    var invoiceID: UUID?
    var readAt: Date?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case userID = "user_id"
        case kind
        case title
        case body
        case jobID = "job_id"
        case customerID = "customer_id"
        case quoteID = "quote_id"
        case invoiceID = "invoice_id"
        case readAt = "read_at"
        case createdAt = "created_at"
    }

    static let selectColumns =
        "id,shop_id,user_id,kind,title,body,job_id,customer_id,quote_id,invoice_id,read_at,created_at"

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        shopID = try c.decode(UUID.self, forKey: .shopID)
        userID = try c.decode(UUID.self, forKey: .userID)
        kind = try c.decode(String.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        jobID = try c.decodeIfPresent(UUID.self, forKey: .jobID)
        customerID = try c.decodeIfPresent(UUID.self, forKey: .customerID)
        quoteID = try c.decodeIfPresent(UUID.self, forKey: .quoteID)
        invoiceID = try c.decodeIfPresent(UUID.self, forKey: .invoiceID)
        readAt = try c.decodeIfPresent(Date.self, forKey: .readAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    var kindValue: AppNotificationKind {
        AppNotificationKind(rawValue: kind) ?? .general
    }

    var isUnread: Bool { readAt == nil }

    /// Where tapping the notification goes (same precedence as the web
    /// app): a new message opens that customer's conversation; a quote
    /// answer the quote, else its job; a payment the invoice, else the job;
    /// everything else the job, else the customer. nil = nothing to open.
    var route: AppRoute? {
        Self.route(kind: kindValue, jobID: jobID, customerID: customerID, quoteID: quoteID, invoiceID: invoiceID)
    }

    /// The destination rule shared by the list and push notifications.
    static func route(
        kind: AppNotificationKind,
        jobID: UUID?,
        customerID: UUID?,
        quoteID: UUID?,
        invoiceID: UUID?
    ) -> AppRoute? {
        switch kind {
        case .inboundMessage:
            return customerID.map { AppRoute.conversation($0) }
        case .quoteApproved, .quoteDeclined:
            if let quoteID { return .quote(quoteID) }
            return jobID.map { AppRoute.job($0) }
        case .paymentReceived:
            if let invoiceID { return .invoice(invoiceID) }
            return jobID.map { AppRoute.job($0) }
        case .newLead:
            return customerID.map { AppRoute.customer($0) }
        case .taskAssigned, .taskDue:
            // Callers check `isTaskKind` first and open the Tasks screen
            // (JobsPushRouter.target, NotificationsRowLink); the task's job
            // is only for a caller without that screen.
            return jobID.map { AppRoute.job($0) }
        case .giftCardPurchased, .membershipJoined:
            if let invoiceID { return .invoice(invoiceID) }
            return customerID.map { AppRoute.customer($0) }
        case .lowStock, .smsNumberStatus, .webhookFailing:
            // Inventory, texting numbers and webhooks are managed on the web.
            return nil
        case .billingPaymentFailed:
            // A plain notification: nothing to open on iPhone (the list
            // itself is the destination; no billing screen, no links).
            return nil
        case .newBooking, .bookingCancelled, .formSigned, .general,
             .inspectionAcknowledged, .jobAssigned, .jobRescheduled:
            if let jobID { return .job(jobID) }
            return customerID.map { AppRoute.customer($0) }
        }
    }
}
