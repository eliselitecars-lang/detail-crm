//
//  MainTabView.swift
//  DetailCRM
//
//  The signed-in, shop-selected shell: Today, Calendar, Customers, Inbox,
//  More. Each tab owns its NavigationStack; feature root views must NOT
//  create their own. Inbox is hidden for roles without inbox access
//  (technicians send templated job messages from the job screen instead).
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
    @State private var selection: AppTab = .today

    var body: some View {
        TabView(selection: $selection) {
            TabRoot {
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

            TabRoot {
                MoreView()
            }
            .tabItem { Label("More", systemImage: "ellipsis.circle") }
            .tag(AppTab.more)
        }
    }
}

/// One tab's navigation root with the shared cross-feature destinations.
struct TabRoot<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            content
                .appRouteDestinations()
        }
    }
}
