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
        }
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
        switch kindValue {
        case .inboundMessage:
            return customerID.map { AppRoute.conversation($0) }
        case .quoteApproved, .quoteDeclined:
            if let quoteID { return .quote(quoteID) }
            return jobID.map { AppRoute.job($0) }
        case .paymentReceived:
            if let invoiceID { return .invoice(invoiceID) }
            return jobID.map { AppRoute.job($0) }
        case .newBooking, .bookingCancelled, .formSigned, .general:
            if let jobID { return .job(jobID) }
            return customerID.map { AppRoute.customer($0) }
        }
    }
}
