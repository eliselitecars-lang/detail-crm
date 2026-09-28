//
//  OpsServiceFollowup.swift
//  DetailCRM
//
//  Per-service maintenance follow-ups (P-4, `public.service_followups`,
//  comms 0081/0086): a text or email sent `offset_days` after a completed
//  job with the service ("time for your 6-month coating check"). Managers
//  and up read them here; the wording is written in the web app. Each
//  channel also needs the shop's "Service follow-up" template switched on,
//  which is the shop-wide ON/OFF switch for that channel.
//

import Foundation

// table: service_followups
struct OpsServiceFollowup: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var serviceID: UUID
    /// `message_channel`: sms | email.
    var channel: String
    var offsetDays: Int
    var subject: String?
    var body: String
    var enabled: Bool
    var sort: Int

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case serviceID = "service_id"
        case channel
        case offsetDays = "offset_days"
        case subject
        case body
        case enabled
        case sort
    }

    static let selectColumns = [
        "id", "shop_id", "service_id", "channel", "offset_days", "subject", "body", "enabled", "sort",
    ].joined(separator: ",")

    /// The channel as the app's message channel (nil for an unknown value).
    var messageChannel: Message.Channel? { Message.Channel(rawValue: channel) }

    var channelName: String { messageChannel?.displayName ?? channel.capitalized }

    var channelImage: String { messageChannel?.systemImage ?? "bubble.left" }

    /// "After 6 months", "After 2 weeks", "After 10 days".
    var delayText: String {
        Self.delayText(days: offsetDays)
    }

    static func delayText(days: Int) -> String {
        let days = max(0, days)
        if days >= 365, days % 365 == 0 {
            let years = days / 365
            return "After \(years) year\(years == 1 ? "" : "s")"
        }
        if days >= 30, days % 30 == 0 {
            let months = days / 30
            return "After \(months) month\(months == 1 ? "" : "s")"
        }
        if days >= 7, days % 7 == 0 {
            let weeks = days / 7
            return "After \(weeks) week\(weeks == 1 ? "" : "s")"
        }
        return "After \(days) day\(days == 1 ? "" : "s")"
    }
}
