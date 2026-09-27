//
//  NotificationService.swift
//  DetailCRM
//
//  The signed-in member's in-app notifications in the active shop
//  (`public.notifications`, 0031). RLS limits every call to the caller's
//  own rows; only `read_at` is client-writable, and rows may be deleted.
//

import Foundation
import Supabase

enum NotificationService {

    /// Newest notifications first (the screen puts unread ones on top).
    static func list(shopID: UUID, limit: Int = 100) async throws -> [AppNotification] {
        let userID = try await Supa.currentUserID()
        return try await Supa.client
            .from("notifications")
            .select(AppNotification.selectColumns)
            .eq("shop_id", value: shopID.uuidString)
            .eq("user_id", value: userID.uuidString)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    /// Unread notifications in the shop (for badges; the More tab badge is
    /// wired by the shell).
    static func unreadCount(shopID: UUID) async throws -> Int {
        let userID = try await Supa.currentUserID()
        let response = try await Supa.client
            .from("notifications")
            .select("id", head: true, count: .exact)
            .eq("shop_id", value: shopID.uuidString)
            .eq("user_id", value: userID.uuidString)
            .is("read_at", value: nil)
            .execute()
        return response.count ?? 0
    }

    /// Marks one notification read (or unread again with `read: false`).
    static func setRead(shopID: UUID, id: UUID, read: Bool = true) async throws {
        try await Supa.client
            .from("notifications")
            .update(readChange(read), returning: .minimal)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: id.uuidString)
            .execute()
    }

    /// `read_at` = now, or an explicit JSON null to mark unread (a
    /// synthesized Encodable would drop the nil and send an empty patch).
    private static func readChange(_ read: Bool) -> [String: AnyJSON] {
        ["read_at": read ? AnyJSON.string(Supa.iso(Date())) : AnyJSON.null]
    }

    /// Marks every unread notification in the shop read. Returns how many
    /// changed (`mark_all_notifications_read`).
    @discardableResult
    static func markAllRead(shopID: UUID) async throws -> Int {
        try await Supa.client
            .rpc("mark_all_notifications_read", params: ["p_shop_id": shopID.uuidString])
            .execute()
            .value
    }

    /// Dismisses (deletes) one notification.
    static func delete(shopID: UUID, id: UUID) async throws {
        try await Supa.client
            .from("notifications")
            .delete(returning: .minimal)
            .eq("shop_id", value: shopID.uuidString)
            .eq("id", value: id.uuidString)
            .execute()
    }

    /// Unread first, then newest first (pure; keeps server order otherwise).
    static func sortedForDisplay(_ items: [AppNotification]) -> [AppNotification] {
        items.sorted { lhs, rhs in
            if lhs.isUnread != rhs.isUnread { return lhs.isUnread }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
