//
//  MainTabView.swift
//  DetailCRM
//
//  The signed-in, shop-selected shell: Today, Calendar, Customers, Inbox,
//  More. Each tab owns its NavigationStack; feature root views must NOT
//  create their own. Inbox is hidden for roles without inbox access
//  (technicians send templated job messages from the job screen instead).
//
//  The shell also starts the shop's Realtime channel (JobsRealtimeHub),
//  registers for push notifications once the tabs are up, and opens a
//  tapped notification (AppState.pendingPush) by pushing its page onto the
//  Today tab (records) or the More tab (tasks, notifications).
//

import SwiftUI
import DetailCore

enum AppTab: Hashable {
    case today
    case calendar
    case customers
    case inbox
    case more
}

struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(JobsRealtimeHub.self) private var realtime
    @Environment(JobsPushRegistrar.self) private var push
    @State private var selection: AppTab = .today
    @State private var todayPath = NavigationPath()
    @State private var morePath = NavigationPath()

    var body: some View {
        TabView(selection: $selection) {
            TabRoot(path: $todayPath) {
                TodayView()
            }
            .tabItem { Label("Today", systemImage: "sun.max") }
            .tag(AppTab.today)

            TabRoot {
                CalendarHomeView()
            }
            .tabItem { Label("Calendar", systemImage: "calendar") }
            .tag(AppTab.calendar)

            TabRoot {
                CustomersView()
            }
            .tabItem { Label("Customers", systemImage: "person.2") }
            .tag(AppTab.customers)

            if appState.can(.useInbox) {
                TabRoot {
                    InboxView()
                }
                .tabItem { Label("Inbox", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppTab.inbox)
            }

            TabRoot(path: $morePath) {
                MoreView()
            }
            .tabItem { Label("More", systemImage: "ellipsis.circle") }
            .tag(AppTab.more)
        }
        .task(id: appState.shop?.id) {
            guard let shopID = appState.shop?.id else { return }
            await realtime.start(shopID: shopID)
        }
        .task(id: appState.userID) {
            guard let userID = appState.userID else { return }
            await push.appBecameReady(userID: userID)
            await push.refreshBadge()
        }
        .onAppear { openPendingPush() }
        .onChange(of: appState.pendingPush) { _, _ in openPendingPush() }
        .onChange(of: realtime.revision(.notifications)) { _, _ in
            Task { await push.refreshBadge() }
        }
    }

    /// Opens a tapped notification that belongs to this shop. One for
    /// another shop waits: JobsPushRouter switches shops and the rebuilt
    /// shell opens it.
    private func openPendingPush() {
        guard let pending = appState.pendingPush else { return }
        if let shopID = pending.shopID, shopID != appState.shop?.id {
            if appState.memberships.contains(where: { $0.shop.id == shopID }) {
                appState.selectShop(shopID)
            } else {
                // No longer a member of that shop: nothing to open.
                appState.pendingPush = nil
            }
            return
        }
        appState.pendingPush = nil
        switch pending.target {
        case .route(let route):
            selection = .today
            todayPath = NavigationPath()
            todayPath.append(route)
        case .more(let item):
            selection = .more
            morePath = NavigationPath()
            morePath.append(item)
        }
        if let notificationID = pending.notificationID, let shopID = appState.shop?.id {
            Task { try? await NotificationService.setRead(shopID: shopID, id: notificationID) }
        }
    }
}

/// One tab's navigation root with the shared cross-feature destinations.
/// Tabs that notifications open pass a path so the shell can push onto them.
struct TabRoot<Content: View>: View {
    let content: Content
    private let path: Binding<NavigationPath>?

    init(path: Binding<NavigationPath>? = nil, @ViewBuilder content: () -> Content) {
        self.path = path
        self.content = content()
    }

    var body: some View {
        if let path {
            NavigationStack(path: path) {
                content
                    .appRouteDestinations()
            }
        } else {
            NavigationStack {
                content
                    .appRouteDestinations()
            }
        }
    }
}
