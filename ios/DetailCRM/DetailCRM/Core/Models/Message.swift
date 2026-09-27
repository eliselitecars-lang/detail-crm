//
//  Message.swift
//  DetailCRM
//
//  Two-way customer messaging (SPEC §4.7). `messages` doubles as the send
//  queue and the conversation history; staff never insert rows directly —
//  they send through the `messaging` edge function (`send`), and may only
//  set `read_at` on inbound rows.
//

import Foundation
import DetailCore

// table: messages
struct Message: Codable, Identifiable, Hashable, Sendable {

    /// `message_direction` enum.
    enum Direction: String, Codable, Sendable {
        case outbound
        case inbound
    }

    /// `message_channel` enum.
    enum Channel: String, Codable, CaseIterable, Identifiable, Sendable {
        case sms
        case email

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .sms: return "Text"
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

    /// `message_status` enum. Unknown future values decode as `.unknown`
    /// so a new server status never breaks the inbox.
    enum Status: String, Codable, Sendable {
        case queued
        case sending
        case sent
        case delivered
        case failed
        case received
        case cancelled
        case unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .unknown
        }

        var displayName: String {
            switch self {
            case .queued: return "Queued"
            case .sending: return "Sending"
            case .sent: return "Sent"
            case .delivered: return "Delivered"
            case .failed: return "Failed"
            case .received: return "Received"
            case .cancelled: return "Not sent"
            case .unknown: return "Unknown"
            }
        }

        var tone: StatusTone {
            switch self {
            case .queued, .sending: return .neutral
            case .sent, .received: return .info
            case .delivered: return .success
            case .failed, .cancelled: return .danger
            case .unknown: return .neutral
            }
        }
    }

    var id: UUID
    var shopID: UUID
    var customerID: UUID?
    var jobID: UUID?
    var campaignID: UUID?
    var direction: Direction
    var channel: Channel
    var toAddress: String
    var fromAddress: String?
    var subject: String?
    var body: String
    var status: Status
    var sendAfter: Date
    var error: String?
    /// `message_template_key` value when sent from a template.
    var templateKey: String?
    var sentBy: UUID?
    var readAt: Date?
    var sentAt: Date?
    var deliveredAt: Date?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case customerID = "customer_id"
        case jobID = "job_id"
        case campaignID = "campaign_id"
        case direction
        case channel
        case toAddress = "to_address"
        case fromAddress = "from_address"
        case subject
        case body
        case status
        case sendAfter = "send_after"
        case error
        case templateKey = "template_key"
        case sentBy = "sent_by"
        case readAt = "read_at"
        case sentAt = "sent_at"
        case deliveredAt = "delivered_at"
        case createdAt = "created_at"
    }

    static let selectColumns = [
        "id", "shop_id", "customer_id", "job_id", "campaign_id", "direction", "channel",
        "to_address", "from_address", "subject", "body", "status", "send_after", "error",
        "template_key", "sent_by", "read_at", "sent_at", "delivered_at", "created_at",
    ].joined(separator: ",")

    var isInbound: Bool { direction == .inbound }
    var isUnread: Bool { direction == .inbound && readAt == nil }

    /// When the message happened for display: inbound = received,
    /// outbound = sent/delivered, else when it was queued.
    var displayDate: Date {
        if isInbound { return createdAt }
        return sentAt ?? deliveredAt ?? createdAt
    }

    /// Short preview for thread rows.
    var preview: String {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text.replacingOccurrences(of: "\n", with: " ") }
        if let subject = subject?.trimmedNonEmpty { return subject }
        return isInbound ? "(empty message)" : ""
    }
}

/// Key of an inbox conversation: a customer, or an unknown sender's
/// number (inbound texts from numbers no customer has yet).
enum MessageThreadKey: Hashable, Sendable {
    case customer(UUID)
    case unknownSender(String)

    var stableID: String {
        switch self {
        case .customer(let id): return "customer:" + id.uuidString
        case .unknownSender(let address): return "sender:" + address
        }
    }

    /// The customer of the conversation (nil for unknown senders).
    var customerID: UUID? {
        if case .customer(let id) = self { return id }
        return nil
    }
}

/// One row of `inbox_threads`: a conversation's newest message and its
/// unread count, grouped by the server (customer threads `c:<uuid>`,
/// unknown senders `a:<address>`).
// rpc: inbox_threads
struct InboxThreadRow: Codable, Hashable, Sendable {
    var threadKey: String
    var customerID: UUID?
    /// Counterpart address of the newest message (inbound sender /
    /// outbound recipient).
    var fromAddress: String?
    var customerFirstName: String?
    var customerLastName: String?
    var customerCompany: String?
    var lastMessageID: UUID
    var lastDirection: Message.Direction
    var lastChannel: Message.Channel
    var lastStatus: Message.Status
    /// The first 280 characters of the newest message.
    var lastBody: String
    var lastCreatedAt: Date
    var unreadCount: Int

    enum CodingKeys: String, CodingKey {
        case threadKey = "thread_key"
        case customerID = "customer_id"
        case fromAddress = "from_address"
        case customerFirstName = "customer_first_name"
        case customerLastName = "customer_last_name"
        case customerCompany = "customer_company"
        case lastMessageID = "last_message_id"
        case lastDirection = "last_direction"
        case lastChannel = "last_channel"
        case lastStatus = "last_status"
        case lastBody = "last_body"
        case lastCreatedAt = "last_created_at"
        case unreadCount = "unread_count"
    }
}

/// One conversation in the inbox list (a row of `inbox_threads`).
struct MessageThread: Identifiable, Hashable, Sendable {
    var key: MessageThreadKey
    /// The customer's name as the server read it (nil for unknown senders).
    var customerName: String?
    /// Counterpart address of the newest message.
    var address: String?
    var lastMessageID: UUID
    var lastDirection: Message.Direction
    var lastChannel: Message.Channel
    var lastStatus: Message.Status
    var lastBody: String
    var lastCreatedAt: Date
    var unreadCount: Int

    var id: String { key.stableID }

    var customerID: UUID? { key.customerID }

    var isLastInbound: Bool { lastDirection == .inbound }

    /// nil when the row's thread key is not one this app understands.
    init?(row: InboxThreadRow) {
        let raw = row.threadKey
        if raw.hasPrefix("c:") {
            guard let id = row.customerID ?? UUID(uuidString: String(raw.dropFirst(2))) else { return nil }
            key = .customer(id)
        } else if raw.hasPrefix("a:") {
            // The conversation screen matches inbound rows by their stored
            // sender address; the key's address is the normalized form.
            let keyAddress = String(raw.dropFirst(2))
            let stored = row.lastDirection == .inbound ? row.fromAddress?.trimmedNonEmpty : nil
            guard let address = stored ?? keyAddress.trimmedNonEmpty else { return nil }
            key = .unknownSender(address)
        } else {
            return nil
        }
        let person = [row.customerFirstName, row.customerLastName]
            .compactMap { $0?.trimmedNonEmpty }
            .joined(separator: " ")
        customerName = person.isEmpty ? row.customerCompany?.trimmedNonEmpty : person
        address = row.fromAddress?.trimmedNonEmpty
        lastMessageID = row.lastMessageID
        lastDirection = row.lastDirection
        lastChannel = row.lastChannel
        lastStatus = row.lastStatus
        lastBody = row.lastBody
        lastCreatedAt = row.lastCreatedAt
        unreadCount = max(0, row.unreadCount)
    }

    var title: String {
        switch key {
        case .customer:
            return customerName ?? "Customer"
        case .unknownSender(let address):
            return PhoneNumber.format(address)
        }
    }

    var subtitle: String? {
        switch key {
        case .customer:
            guard let address else { return nil }
            return lastChannel == .sms ? PhoneNumber.format(address) : address
        case .unknownSender:
            return "Not a saved customer"
        }
    }

    /// Short preview for the list row.
    var preview: String {
        let text = lastBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text.replacingOccurrences(of: "\n", with: " ") }
        return isLastInbound ? "(empty message)" : ""
    }
}

/// A shop's wording for one (key, channel) template — read-only here
/// (admins edit templates in Settings).
// table: message_templates
struct InboxTemplate: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var key: String
    var channel: Message.Channel
    var subject: String?
    var body: String
    var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case key
        case channel
        case subject
        case body
        case enabled
    }

    static let selectColumns = "id,key,channel,subject,body,enabled"

    /// Keys whose wording depends on a specific job (appointment time,
    /// vehicle, invoice link…): these need a job to be sent.
    static let jobKeys: Set<String> = [
        "booking_request_received", "booking_confirmed", "appointment_reminder",
        "on_the_way", "job_started", "job_completed", "quote_sent", "invoice_sent",
        "payment_receipt",
    ]

    /// Keys the `send` action accepts (every key except staff invites).
    static let sendableKeys: Set<String> = jobKeys.union(["review_request", "follow_up", "membership_welcome"])

    var requiresJob: Bool { InboxTemplate.jobKeys.contains(key) }

    var displayName: String {
        InboxTemplate.displayName(forKey: key)
    }

    static func displayName(forKey key: String) -> String {
        switch key {
        case "booking_request_received": return "Booking request received"
        case "booking_confirmed": return "Booking confirmed"
        case "appointment_reminder": return "Appointment reminder"
        case "on_the_way": return "On my way"
        case "job_started": return "Job started"
        case "job_completed": return "Job complete"
        case "quote_sent": return "Quote"
        case "invoice_sent": return "Invoice"
        case "payment_receipt": return "Payment receipt"
        case "review_request": return "Review request"
        case "follow_up": return "Follow-up"
        case "membership_welcome": return "Membership welcome"
        case "invite": return "Team invite"
        default:
            return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Server-rendered preview of a job template (nothing is queued).
// rpc: preview_template_message
struct InboxTemplatePreview: Codable, Hashable, Sendable {
    var enabled: Bool
    var toAddress: String?
    var subject: String?
    var body: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case toAddress = "to_address"
        case subject
        case body
    }
}

/// Result of the messaging function's `send` action.
struct InboxSendResult: Hashable, Sendable {
    var messageID: UUID?
    var channel: Message.Channel
    /// Status right after the immediate delivery attempt.
    var status: Message.Status
    var error: String?

    /// Whether the send attempt failed outright (vs sent / queued for retry).
    var didFail: Bool { status == .failed || status == .cancelled }
}
