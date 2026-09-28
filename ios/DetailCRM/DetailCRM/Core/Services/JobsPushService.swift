//
//  JobsPushService.swift
//  DetailCRM
//
//  Push notifications (P-2). The device token is registered for the
//  signed-in user (`register_push_token`; a token that belonged to another
//  account moves to this one) and removed on sign-out. What gets pushed is
//  decided by the server: notifications the member may read, of the kinds
//  switched on in their preferences, unless muted (`claim_push_batch`).
//

import Foundation
import Supabase

enum JobsPushService {

    /// The caller's push preferences in one shop (`member_notification_prefs`,
    /// own row only). No row yet means every kind, not muted.
    // table: member_notification_prefs
    struct Prefs: Codable, Hashable, Sendable {
        var memberID: UUID
        var shopID: UUID
        /// Raw `notification_kind` values that may be pushed.
        var pushKinds: [String]
        var mutedUntil: Date?

        enum CodingKeys: String, CodingKey {
            case memberID = "member_id"
            case shopID = "shop_id"
            case pushKinds = "push_kinds"
            case mutedUntil = "muted_until"
        }

        static let selectColumns = "member_id,shop_id,push_kinds,muted_until"

        func isMuted(now: Date = Date()) -> Bool {
            guard let mutedUntil else { return false }
            return mutedUntil > now
        }
    }

    /// Reply of the `push` edge function's `send_test` action (property
    /// names are the JSON keys).
    struct TestReply: Decodable, Sendable {
        var sent: Int
        var failed: Int
    }

    // MARK: - Device token

    /// Registers (or refreshes) this device for the signed-in user.
    /// `environment` is `sandbox` for development builds, else `production`.
    static func register(token: String, environment: String, bundleID: String, appVersion: String?) async throws {
        var params: [String: AnyJSON] = [
            "p_token": .string(token),
            "p_apns_env": .string(environment),
            "p_bundle_id": .string(bundleID),
        ]
        params["p_app_version"] = appVersion.map { AnyJSON.string(String($0.prefix(40))) } ?? .null
        try await Supa.client
            .rpc("register_push_token", params: params)
            .execute()
    }

    /// Removes this device from the signed-in user (sign-out).
    static func unregister(token: String) async throws {
        try await Supa.client
            .rpc("unregister_push_token", params: ["p_token": token])
            .execute()
    }

    // MARK: - Preferences

    /// The member's saved preferences, or nil when never saved (defaults).
    static func prefs(shopID: UUID, memberID: UUID) async throws -> Prefs? {
        let rows: [Prefs] = try await Supa.client
            .from("member_notification_prefs")
            .select(Prefs.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("member_id", value: memberID.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Saves which kinds may be pushed and an optional mute end
    /// (`set_notification_prefs`; own membership only).
    @discardableResult
    static func savePrefs(shopID: UUID, pushKinds: [String], mutedUntil: Date?) async throws -> Prefs {
        let params: [String: AnyJSON] = [
            "p_shop_id": .string(shopID.uuidString),
            "p_push_kinds": .array(pushKinds.map { AnyJSON.string($0) }),
            "p_muted_until": mutedUntil.map { AnyJSON.string(Supa.iso($0)) } ?? .null,
        ]
        return try await Supa.client
            .rpc("set_notification_prefs", params: params)
            .single()
            .execute()
            .value
    }

    /// Sends "Test notification" to the caller's registered devices.
    static func sendTest(shopID: UUID) async throws -> TestReply {
        try await EdgeFunctions.invoke(
            "push",
            body: ["action": "send_test", "shop_id": shopID.uuidString.lowercased()]
        )
    }
}

extension JobsPushService {
    /// Unread notifications of the signed-in user in every shop they may
    /// read (RLS), for the app icon badge.
    static func unreadCountAllShops() async throws -> Int {
        let userID = try await Supa.currentUserID()
        let response = try await Supa.client
            .from("notifications")
            .select("id", head: true, count: .exact)
            .eq("user_id", value: userID.uuidString)
            .is("read_at", value: nil)
            .execute()
        return response.count ?? 0
    }
}
