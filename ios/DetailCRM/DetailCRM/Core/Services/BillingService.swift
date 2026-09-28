//
//  BillingService.swift
//  DetailCRM
//
//  The shop's subscription standing (`shop_entitlement`, any active member).
//  The iPhone app only reads it to show neutral status text on Today and in
//  More (DetailCore `ShopEntitlement.notice`); plans, prices and purchase
//  live on the web app only (App Store 3.1.1 / 3.1.3). Every rule (writes
//  paused while lapsed, seat limits) is enforced by the database, which
//  refuses with PT402 / HTTP 402 — `ErrorText` shows its message.
//

import Foundation
import Supabase
import DetailCore

enum BillingService {

    /// The caller's view of the shop's subscription.
    static func entitlement(shopID: UUID) async throws -> ShopEntitlement {
        try await Supa.client
            .rpc("shop_entitlement", params: ["p_shop_id": shopID.uuidString])
            .execute()
            .value
    }

    /// The status line to show, or nil. Never throws: when the standing
    /// can't be read (offline, older server) the screens show nothing and
    /// work as usual — the server still enforces the rules.
    static func notice(shopID: UUID) async -> ShopEntitlement.Notice? {
        do {
            return try await entitlement(shopID: shopID).notice
        } catch {
            return nil
        }
    }
}
