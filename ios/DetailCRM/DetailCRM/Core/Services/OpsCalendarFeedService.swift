//
//  OpsCalendarFeedService.swift
//  DetailCRM
//
//  The signed-in member's iCal feed (P-19, sched 0055). Creating a feed
//  revokes the member's previous link; `include_all` (every job of the
//  shop) is for owners / admins / managers (42501 otherwise, and re-checked
//  whenever the calendar app reads the feed).
//

import Foundation
import Supabase

enum OpsCalendarFeedService {

    /// The member's live feed, or nil when they have none.
    static func current(shopID: UUID, memberID: UUID) async throws -> OpsCalendarFeed? {
        let rows: [OpsCalendarFeed] = try await Supa.client
            .from("calendar_feed_tokens")
            .select(OpsCalendarFeed.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("member_id", value: memberID.uuidString)
            .is("revoked_at", value: nil)
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Creates a new feed link (the old one stops working) and returns the
    /// live row. Once `create_calendar_feed` has succeeded the new link is
    /// live and the old one is dead, so a failed re-read never fails the
    /// call: the row is then built from the RPC result.
    static func create(shopID: UUID, memberID: UUID, includeAll: Bool) async throws -> OpsCalendarFeed {
        struct Params: Encodable {
            let p_shop_id: UUID
            let p_include_all: Bool
        }
        let created: OpsCalendarFeed.Created = try await Supa.client
            .rpc("create_calendar_feed", params: Params(p_shop_id: shopID, p_include_all: includeAll))
            .execute()
            .value
        let reread = try? await current(shopID: shopID, memberID: memberID)
        return OpsCalendarFeed.live(
            created: created,
            reread: reread,
            shopID: shopID,
            memberID: memberID,
            includeAll: includeAll
        )
    }

    /// Turns the member's feed off. True when there was one.
    @discardableResult
    static func revoke(shopID: UUID) async throws -> Bool {
        struct Params: Encodable {
            let p_shop_id: UUID
        }
        return try await Supa.client
            .rpc("revoke_calendar_feed", params: Params(p_shop_id: shopID))
            .execute()
            .value
    }
}
