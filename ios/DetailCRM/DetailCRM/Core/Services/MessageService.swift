//
//  MessageService.swift
//  DetailCRM
//
//  The staff inbox (SPEC §4.7; owner/admin/manager only). Conversations
//  come from the server (`inbox_threads`: the newest message per customer
//  or unknown sender, with unread counts), paged newest first; the total
//  unread count is `inbox_unread_count`. Sending always goes through the
//  `messaging` edge function's `send` action, which checks the role, queues
//  the message with the database's consent rules (opt-outs, missing
//  address, SMS not configured) and delivers it right away. Every compose
//  carries a `request_nonce`, so a retry never queues a second copy.
//

import Foundation
import Supabase

enum MessageService {

    /// Conversations per inbox page (`inbox_threads` p_limit).
    static let inboxPageSize = 50
    /// How many messages a conversation screen loads.
    static let threadWindow = 300

    /// SMS body limit (database + `messaging` edge function).
    static let smsLimit = 1600

    /// Length of a text as the `messaging` function measures it: JS
    /// `body.length`, i.e. UTF-16 code units (an emoji counts as 2). This is
    /// the strictest of the server's checks, so the app matches it.
    static func smsLength(_ text: String) -> Int {
        text.utf16.count
    }

    // MARK: - Inbox

    /// One page of conversations, newest activity first. `before` is the
    /// `lastCreatedAt` of the last conversation already shown (strictly
    /// older ones are returned); nil for the first page.
    static func inbox(shopID: UUID, before: Date? = nil) async throws -> InboxPage {
        let rows: [InboxThreadRow] = try await Supa.client
            .rpc("inbox_threads", params: InboxThreadsParams(
                p_shop_id: shopID,
                p_limit: inboxPageSize,
                p_before: before.map { Supa.iso($0) }
            ))
            .execute()
            .value
        return InboxPage(
            threads: rows.compactMap { MessageThread(row: $0) },
            nextBefore: rows.count >= inboxPageSize ? rows.last?.lastCreatedAt : nil
        )
    }

    /// Total unread inbound messages in the shop (for badges).
    static func unreadCount(shopID: UUID) async throws -> Int {
        try await Supa.client
            .rpc("inbox_unread_count", params: InboxUnreadParams(p_shop_id: shopID))
            .execute()
            .value
    }

    // MARK: - One conversation

    /// Messages of a conversation, oldest first (the most recent
    /// `threadWindow`). Withdrawn (`cancelled`) queue rows are included so
    /// staff can see a message was not sent.
    static func messages(shopID: UUID, thread key: MessageThreadKey) async throws -> [Message] {
        var request = Supa.client
            .from("messages")
            .select(Message.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
        switch key {
        case .customer(let id):
            request = request.eq("customer_id", value: id.uuidString)
        case .unknownSender(let address):
            request = request
                .is("customer_id", value: nil)
                .eq("direction", value: Message.Direction.inbound.rawValue)
                .eq("from_address", value: address)
        }
        let newestFirst: [Message] = try await request
            .order("created_at", ascending: false)
            .limit(threadWindow)
            .execute()
            .value
        return newestFirst.reversed()
    }

    /// Marks every unread inbound message of a conversation as read.
    /// Staff may only set `read_at` (column-level grant).
    static func markRead(shopID: UUID, thread key: MessageThreadKey) async throws {
        var request = try Supa.client
            .from("messages")
            .update(MessageReadPatch(readAt: Supa.iso(Date())), returning: .minimal)
            .eq("shop_id", value: shopID.uuidString)
            .eq("direction", value: Message.Direction.inbound.rawValue)
            .is("read_at", value: nil)
        switch key {
        case .customer(let id):
            request = request.eq("customer_id", value: id.uuidString)
        case .unknownSender(let address):
            request = request
                .is("customer_id", value: nil)
                .eq("from_address", value: address)
        }
        try await request.execute()
    }

    // MARK: - Templates

    /// Enabled, sendable templates of the shop (manager+ can read them).
    static func templates(shopID: UUID) async throws -> [InboxTemplate] {
        let rows: [InboxTemplate] = try await Supa.client
            .from("message_templates")
            .select(InboxTemplate.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("enabled", value: true)
            .order("key", ascending: true)
            .order("channel", ascending: true)
            .execute()
            .value
        return rows.filter { InboxTemplate.sendableKeys.contains($0.key) }
    }

    /// What a job template would send, rendered by the server.
    static func previewTemplate(jobID: UUID, key: String, channel: Message.Channel) async throws -> InboxTemplatePreview? {
        let rows: [InboxTemplatePreview] = try await Supa.client
            .rpc("preview_template_message", params: MessagePreviewParams(
                p_job_id: jobID.uuidString.lowercased(),
                p_key: key,
                p_channel: channel.rawValue
            ))
            .execute()
            .value
        return rows.first
    }

    // MARK: - Sending (edge function `messaging`, action `send`)

    /// Sends a free-form text or email to a customer.
    static func send(
        shopID: UUID,
        customerID: UUID,
        channel: Message.Channel,
        subject: String?,
        body: String,
        jobID: UUID? = nil,
        nonce: String
    ) async throws -> InboxSendResult {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError.invalidInput("Write a message first.") }
        if channel == .sms && smsLength(trimmed) > smsLimit {
            throw AppError.invalidInput("Text messages are limited to 1,600 characters.")
        }
        let payload = MessageSendBody(
            action: "send",
            shop_id: shopID.uuidString.lowercased(),
            customer_id: customerID.uuidString.lowercased(),
            job_id: jobID?.uuidString.lowercased(),
            channel: channel.rawValue,
            template_key: nil,
            subject: channel == .email ? subject?.trimmedNonEmpty : nil,
            body: trimmed,
            request_nonce: nonce
        )
        return try await invokeSend(payload, channel: channel)
    }

    /// Sends a shop template (rendered by the server) to a customer,
    /// optionally about one of their jobs.
    static func sendTemplate(
        shopID: UUID,
        customerID: UUID,
        key: String,
        channel: Message.Channel,
        jobID: UUID? = nil,
        nonce: String
    ) async throws -> InboxSendResult {
        let payload = MessageSendBody(
            action: "send",
            shop_id: shopID.uuidString.lowercased(),
            customer_id: customerID.uuidString.lowercased(),
            job_id: jobID?.uuidString.lowercased(),
            channel: channel.rawValue,
            template_key: key,
            subject: nil,
            body: nil,
            request_nonce: nonce
        )
        return try await invokeSend(payload, channel: channel)
    }

    private static func invokeSend(_ payload: MessageSendBody, channel: Message.Channel) async throws -> InboxSendResult {
        let reply: MessageSendReply = try await EdgeFunctions.invoke("messaging", body: payload)
        return InboxSendResult(
            messageID: reply.message_id.flatMap { UUID(uuidString: $0) },
            channel: Message.Channel(rawValue: reply.channel ?? "") ?? channel,
            status: Message.Status(rawValue: reply.status ?? "") ?? .unknown,
            error: reply.error
        )
    }

    /// A fresh per-compose nonce for `send` (url-safe, 32 characters).
    static func newNonce() -> String {
        MoneyEdge.newNonce()
    }
}

/// One page of the inbox.
struct InboxPage: Sendable {
    var threads: [MessageThread]
    /// Pass as `before` to load the next (older) page; nil when this was
    /// the last page.
    var nextBefore: Date?
}

// MARK: - Private wire types (file scope: never nest types in generic functions)

/// Request body of `messaging` / `send`. nil fields are omitted (the
/// function's schema is strict and rejects nulls and unknown keys). Ids
/// are sent lower-case: the function compares them as strings with ids
/// read from Postgres.
private struct MessageSendBody: Encodable {
    let action: String
    let shop_id: String
    let customer_id: String?
    let job_id: String?
    let channel: String
    let template_key: String?
    let subject: String?
    let body: String?
    let request_nonce: String
}

/// Response of `send`: `{message_id, channel, status, error}`.
private struct MessageSendReply: Decodable {
    let message_id: String?
    let channel: String?
    let status: String?
    let error: String?
}

private struct InboxThreadsParams: Encodable {
    let p_shop_id: UUID
    let p_limit: Int
    /// Omitted for the first page.
    let p_before: String?
}

private struct InboxUnreadParams: Encodable {
    let p_shop_id: UUID
}

private struct MessagePreviewParams: Encodable {
    let p_job_id: String
    let p_key: String
    let p_channel: String
}

// table: messages
private struct MessageReadPatch: Encodable {
    let readAt: String

    enum CodingKeys: String, CodingKey {
        case readAt = "read_at"
    }
}
