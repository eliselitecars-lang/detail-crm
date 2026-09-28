//
//  JobsPushRouter.swift
//  DetailCRM
//
//  Turns a tapped push notification into a place in the app. The payload
//  (sent by the `push` edge function) carries `kind`, `shop_id` and the ids
//  of what it is about; the destination follows the same rule as the
//  in-app list (`AppNotification.route`). A notification from another shop
//  switches to that shop first. The target waits in `AppState` until the
//  main tabs are on screen (cold start, shop switch) — MainTabView opens it.
//

import Foundation

enum JobsPushRouter {

    /// Where a tapped notification leads.
    enum Target: Hashable, Sendable {
        /// A record, pushed on the Today tab.
        case route(AppRoute)
        /// A More screen (tasks, the notification list).
        case more(MoreItem)
    }

    /// The tap waiting to be opened, with the shop it belongs to.
    struct Pending: Hashable, Sendable {
        var shopID: UUID?
        var target: Target
        /// The in-app notification to mark read once opened.
        var notificationID: UUID?
    }

    /// The fields the app reads from an APNs payload (plain values so they
    /// can cross from the notification delegate to the main actor).
    struct NotificationTap: Hashable, Sendable {
        var kind: String
        var shopID: UUID?
        var jobID: UUID?
        var customerID: UUID?
        var quoteID: UUID?
        var invoiceID: UUID?
        var notificationID: UUID?
    }

    /// Reads a notification's `userInfo`; nil when it isn't one of ours.
    static func payload(from userInfo: [AnyHashable: Any]) -> NotificationTap? {
        guard let kind = userInfo["kind"] as? String else { return nil }
        func uuid(_ key: String) -> UUID? {
            (userInfo[key] as? String).flatMap(UUID.init(uuidString:))
        }
        return NotificationTap(
            kind: kind,
            shopID: uuid("shop_id"),
            jobID: uuid("job_id"),
            customerID: uuid("customer_id"),
            quoteID: uuid("quote_id"),
            invoiceID: uuid("invoice_id"),
            notificationID: uuid("notification_id")
        )
    }

    /// The destination for a payload: tasks open the Tasks screen, records
    /// open their page, anything else the notification list.
    static func target(for payload: NotificationTap) -> Target {
        let kind = AppNotificationKind(rawValue: payload.kind) ?? .general
        if kind.isTaskKind {
            return .more(MoreItem.tasksDestination)
        }
        if let route = AppNotification.route(
            kind: kind,
            jobID: payload.jobID,
            customerID: payload.customerID,
            quoteID: payload.quoteID,
            invoiceID: payload.invoiceID
        ) {
            return .route(route)
        }
        return .more(.notifications)
    }

    /// Records the tap for MainTabView (switching shops when needed).
    @MainActor
    static func open(_ payload: NotificationTap, appState: AppState) {
        let pending = Pending(
            shopID: payload.shopID,
            target: target(for: payload),
            notificationID: payload.notificationID
        )
        appState.pendingPush = pending
        guard appState.phase == .ready, let shopID = payload.shopID,
              appState.shop?.id != shopID,
              appState.memberships.contains(where: { $0.shop.id == shopID }) else { return }
        // Rebuilds the tabs for that shop; the new MainTabView opens it.
        appState.selectShop(shopID)
    }
}
