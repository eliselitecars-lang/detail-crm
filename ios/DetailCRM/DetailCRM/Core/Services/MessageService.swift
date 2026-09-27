//
//  MessageService.swift
//  DetailCRM
//
//  The staff inbox (SPEC §4.7; owner/admin/manager only — RLS returns
//  nothing to technicians). Conversations are grouped client-side from
//  recent `messages` rows; unread = inbound rows with `read_at` null.
//  Sending always goes through the `messaging` edge function's `send`
//  action, which checks the role, queues the message with the database's
//  consent rules (opt-outs, missing address, SMS not configured) and
//  delivers it right away.
//

import Foundation
import Supabase

enum MessageService {

    /// How many recent messages the inbox groups into conversations.
    static let inboxWindow = 500
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

    /// Conversations, newest activity first, with unread counts.
    static func threads(shopID: UUID) async throws -> [MessageThread] {
        async let recentTask: [Message] = Supa.client
            .from("messages")
            .select(Message.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .neq("status", value: "cancelled")
            .order("created_at", ascending: false)
            .limit(inboxWindow)
            .execute()
            .value
        async let unreadTask: [MessageUnreadRow] = Supa.client
            .from("messages")
            .select("customer_id,from_address")
            .eq("shop_id", value: shopID.uuidString)
            .eq("direction", value: Message.Direction.inbound.rawValue)
            .is("read_at", value: nil)
            .limit(2000)
            .execute()
            .value
        let (recent, unread) = try await (recentTask, unreadTask)

        var unreadCounts: [MessageThreadKey: Int] = [:]
        for row in unread {
            if let key = threadKey(customerID: row.customerID, fromAddress: row.fromAddress) {
                unreadCounts[key, default: 0] += 1
            }
        }

        var order: [MessageThreadKey] = []
        var latestByKey: [MessageThreadKey: Message] = [:]
        for message in recent {
            let address = message.isInbound ? message.fromAddress : nil
            guard let key = threadKey(customerID: message.customerID, fromAddress: address) else { continue }
            if latestByKey[key] == nil {
                latestByKey[key] = message
                order.append(key)
            }
        }

        var customerIDs: [UUID] = []
        for key in order {
            if case .customer(let id) = key { customerIDs.append(id) }
        }
        // Names are a secondary lookup: if it fails, the conversations still
        // show (titled "Customer") instead of failing the whole inbox.
        let customers: [Customer]
        do {
            customers = try await CustomerService.fetch(shopID: shopID, ids: customerIDs)
        } catch {
            customers = []
        }
        let customersByID = Dictionary(customers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return order.compactMap { key -> MessageThread? in
            guard let latest = latestByKey[key] else { return nil }
            var customer: Customer?
            if case .customer(let id) = key { customer = customersByID[id] }
            return MessageThread(key: key, customer: customer, latest: latest, unreadCount: unreadCounts[key] ?? 0)
        }
    }

    /// Total unread inbound messages in the shop (for badges).
    static func unreadCount(shopID: UUID) async throws -> Int {
        let response = try await Supa.client
            .from("messages")
            .select("id", head: true, count: .exact)
            .eq("shop_id", value: shopID.uuidString)
            .eq("direction", value: Message.Direction.inbound.rawValue)
            .is("read_at", value: nil)
            .execute()
        return response.count ?? 0
    }

    private static func threadKey(customerID: UUID?, fromAddress: String?) -> MessageThreadKey? {
        if let customerID { return .customer(customerID) }
        if let address = fromAddress?.trimmedNonEmpty { return .unknownSender(address) }
        return nil
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
        jobID: UUID? = nil
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
            body: trimmed
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
        jobID: UUID? = nil
    ) async throws -> InboxSendResult {
        let payload = MessageSendBody(
            action: "send",
            shop_id: shopID.uuidString.lowercased(),
            customer_id: customerID.uuidString.lowercased(),
            job_id: jobID?.uuidString.lowercased(),
            channel: channel.rawValue,
            template_key: key,
            subject: nil,
            body: nil
        )
        return try await invokeSend(payload, channel: channel)
    }

    private static func invokeSend(_ payload: MessageSendBody, channel: Message.Channel) async throws -> InboxSendResult {
        do {
            let reply: MessageSendReply = try await Supa.client.functions.invoke(
                "messaging",
                options: FunctionInvokeOptions(body: payload)
            )
            return InboxSendResult(
                messageID: reply.message_id.flatMap { UUID(uuidString: $0) },
                channel: Message.Channel(rawValue: reply.channel ?? "") ?? channel,
                status: Message.Status(rawValue: reply.status ?? "") ?? .unknown,
                error: reply.error
            )
        } catch let error as FunctionsError {
            throw readable(error)
        }
    }

    /// Turns the function's `{"error": "...", "code": "..."}` body into a
    /// readable `AppError`.
    private static func readable(_ error: FunctionsError) -> Error {
        if case .httpError(let code, let data) = error {
            if let decoded = try? JSONDecoder().decode(MessageFunctionErrorBody.self, from: data),
               let message = decoded.error?.trimmedNonEmpty {
                return AppError.message(ErrorText.sentence(message))
            }
            if code == 401 { return AppError.notSignedIn }
            if code == 403 { return AppError.message("You don't have permission to send messages.") }
            return AppError.message("The message couldn't be sent. Try again.")
        }
        return AppError.message("Couldn't reach the messaging service. Try again.")
    }
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
}

/// Response of `send`: `{message_id, channel, status, error}`.
private struct MessageSendReply: Decodable {
    let message_id: String?
    let channel: String?
    let status: String?
    let error: String?
}

private struct MessageFunctionErrorBody: Decodable {
    let error: String?
    let code: String?
}

private struct MessagePreviewParams: Encodable {
    let p_job_id: String
    let p_key: String
    let p_channel: String
}

// table: messages
private struct MessageUnreadRow: Decodable {
    let customerID: UUID?
    let fromAddress: String?

    enum CodingKeys: String, CodingKey {
        case customerID = "customer_id"
        case fromAddress = "from_address"
    }
}

// table: messages
private struct MessageReadPatch: Encodable {
    let readAt: String

    enum CodingKeys: String, CodingKey {
        case readAt = "read_at"
    }
}
