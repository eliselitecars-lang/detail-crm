//
//  OpsCalendarFeed.swift
//  DetailCRM
//
//  Personal iCal feed (P-19, sched 0055): every active member may create a
//  private link that Apple Calendar, Google Calendar or Outlook subscribes
//  to. It lists the member's assigned jobs (and, for managers who ask, every
//  job of the shop). The token is the credential: anyone with the link sees
//  the feed, so it can be reset (a new link revokes the old one) or turned
//  off at any time.
//
//  `create_calendar_feed` returns {token, path}; the member's live token row
//  is readable in `calendar_feed_tokens` (own rows only).
//

import Foundation

// table: calendar_feed_tokens
struct OpsCalendarFeed: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var shopID: UUID
    var memberID: UUID
    var token: UUID
    var includeAll: Bool
    var createdAt: Date
    var revokedAt: Date?
    var lastAccessedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case shopID = "shop_id"
        case memberID = "member_id"
        case token
        case includeAll = "include_all"
        case createdAt = "created_at"
        case revokedAt = "revoked_at"
        case lastAccessedAt = "last_accessed_at"
    }

    static let selectColumns = [
        "id", "shop_id", "member_id", "token", "include_all", "created_at", "revoked_at", "last_accessed_at",
    ].joined(separator: ",")

    /// The calendar-feed edge function's path (the server returns the same
    /// path from `create_calendar_feed`).
    static let functionPath = "/functions/v1/calendar-feed"

    /// `https://<project>/functions/v1/calendar-feed?token=…` — for Google
    /// Calendar ("From URL") and for copying.
    var httpsURL: URL? { Self.feedURL(token: token, scheme: "https") }

    /// `webcal://…` — opens the iPhone's "Subscribe to calendar" prompt.
    var webcalURL: URL? { Self.feedURL(token: token, scheme: "webcal") }

    /// The feed URL on the configured Supabase host (nil while the app is
    /// not configured).
    static func feedURL(token: UUID, scheme: String, base: URL? = AppConfig.supabaseURL) -> URL? {
        guard let base,
              let baseComponents = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let host = baseComponents.host, !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = baseComponents.port
        var basePath = baseComponents.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + functionPath
        components.queryItems = [URLQueryItem(name: "token", value: token.uuidString.lowercased())]
        return components.url
    }

    /// The feed after `create_calendar_feed` returned `created`: the
    /// re-read row when it is that new link, else one built from the RPC
    /// result (the re-read failed, or raced another reset). The RPC's token
    /// is always the one handed out, never a stale one.
    static func live(
        created: Created,
        reread: OpsCalendarFeed?,
        shopID: UUID,
        memberID: UUID,
        includeAll: Bool,
        now: Date = Date()
    ) -> OpsCalendarFeed {
        if let reread, reread.token == created.token {
            return reread
        }
        return OpsCalendarFeed(
            id: created.token,
            shopID: shopID,
            memberID: memberID,
            token: created.token,
            includeAll: includeAll,
            createdAt: now,
            revokedAt: nil,
            lastAccessedAt: nil
        )
    }

    /// `create_calendar_feed` result.
    // rpc: create_calendar_feed
    struct Created: Codable, Hashable, Sendable {
        var token: UUID
        var path: String

        enum CodingKeys: String, CodingKey {
            case token
            case path
        }
    }
}
