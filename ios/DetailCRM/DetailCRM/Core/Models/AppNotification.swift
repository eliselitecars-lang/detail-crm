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
        case readAt = "read_at"
        case createdAt = "created_at"
    }

    static let selectColumns = "id,shop_id,user_id,kind,title,body,job_id,read_at,created_at"

    var kindValue: AppNotificationKind {
        AppNotificationKind(rawValue: kind) ?? .general
    }

    var isUnread: Bool { readAt == nil }
}
