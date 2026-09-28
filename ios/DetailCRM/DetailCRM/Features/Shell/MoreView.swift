//
//  MoreView.swift
//  DetailCRM
//
//  Everything that isn't a main tab. Items are hidden by role using the
//  DetailCore capability matrix (the server enforces the same rules).
//  Under the account header: the shop's subscription status line when
//  there is one (BillingNoticeBanner — neutral text, no purchase links).
//

import SwiftUI
import DetailCore

enum MoreItem: String, CaseIterable, Identifiable, Hashable {
    case quotes
    case invoices
    case payments
    case memberships
    case timeClock
    case tasks
    case reports
    case team
    case catalog
    case settings
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quotes: return "Quotes"
        case .invoices: return "Invoices"
        case .payments: return "Payments"
        case .memberships: return "Memberships"
        case .timeClock: return "Time Clock"
        case .tasks: return "Tasks"
        case .reports: return "Reports"
        case .team: return "Team"
        case .catalog: return "Catalog"
        case .settings: return "Settings"
        case .notifications: return "Notifications"
        }
    }

    var systemImage: String {
        switch self {
        case .quotes: return "doc.text"
        case .invoices: return "doc.plaintext"
        case .payments: return "creditcard"
        case .memberships: return "arrow.triangle.2.circlepath"
        case .timeClock: return "clock"
        case .tasks: return "checklist"
        case .reports: return "chart.bar"
        case .team: return "person.3"
        case .catalog: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        case .notifications: return "bell"
        }
    }

    /// Whether a member with `role` in a shop with `policy` sees this item.
    func isVisible(role: ShopRole, policy: ShopPolicy) -> Bool {
        switch self {
        case .quotes: return role.can(.manageQuotes, policy: policy)
        case .invoices: return role.can(.manageInvoices, policy: policy)
        case .payments: return role.can(.managePayments, policy: policy)
        case .memberships: return role.can(.manageMemberships, policy: policy)
        case .timeClock: return role.can(.useOwnTimeClock, policy: policy)
        case .tasks: return true
        case .reports: return role.can(.viewAllReports, policy: policy) || role.can(.viewOwnReports, policy: policy)
        case .team: return role.can(.viewTeam, policy: policy)
        case .catalog: return role.can(.viewCatalog, policy: policy)
        case .settings: return role.can(.viewShopSettings, policy: policy)
        case .notifications: return true
        }
    }

    /// Where task notifications open.
    static var tasksDestination: MoreItem { .tasks }

    static let moneyItems: [MoreItem] = [.quotes, .invoices, .payments, .memberships]
    static let workItems: [MoreItem] = [.timeClock, .tasks, .reports, .team, .catalog]
    static let shopItems: [MoreItem] = [.settings, .notifications]
}

struct MoreView: View {
    @Environment(AppState.self) private var appState
    @State private var confirmation: ConfirmationRequest?
    @State private var billingNotice: ShopEntitlement.Notice?

    var body: some View {
        List {
            Section {
                AccountHeader()
                if let billingNotice {
                    BillingNoticeBanner(notice: billingNotice, clock: appState.clock)
                        .padding(.vertical, Theme.Spacing.xs)
                        .themedRow()
                }
            }
            itemSection("Money", items: MoreItem.moneyItems)
            itemSection("Work", items: MoreItem.workItems)
            itemSection("Shop", items: MoreItem.shopItems)
            Section {
                // Every role: profile, and deleting the account (App Store 5.1.1(v)).
                NavigationLink {
                    SettingsAccountView()
                } label: {
                    Label("Your account", systemImage: "person.crop.circle")
                        .foregroundStyle(Theme.textPrimary)
                }
                .themedRow()
                Button {
                    appState.beginSwitchingShop()
                } label: {
                    Label(appState.memberships.count > 1 ? "Switch shop" : "Add or join a shop",
                          systemImage: "arrow.left.arrow.right")
                        .foregroundStyle(Theme.textPrimary)
                }
                .themedRow()
                Button(role: .destructive) {
                    confirmation = ConfirmationRequest(
                        title: "Sign out?",
                        message: "You'll need your email and password to sign back in.",
                        confirmTitle: "Sign out",
                        isDestructive: true
                    ) {
                        await appState.signOut()
                    }
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(Theme.danger)
                }
                .themedRow()
            }
        }
        .listStyle(.insetGrouped)
        .screenBackground()
        .navigationTitle("More")
        .navigationDestination(for: MoreItem.self) { item in
            MoreDestinationView(item: item)
        }
        .confirmation($confirmation)
        .billingNotice($billingNotice, shopID: appState.shop?.id)
    }

    @ViewBuilder
    private func itemSection(_ title: String, items: [MoreItem]) -> some View {
        let visible = visibleItems(items)
        if !visible.isEmpty {
            Section(title) {
                ForEach(visible) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.systemImage)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .themedRow()
                }
            }
        }
    }

    private func visibleItems(_ items: [MoreItem]) -> [MoreItem] {
        guard let current = appState.current else { return [] }
        return items.filter { $0.isVisible(role: current.role, policy: current.shop.policy) }
    }
}

/// Shop name, the signed-in member and their role.
private struct AccountHeader: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            AvatarView(
                name: appState.displayName,
                size: Theme.Size.avatarMedium,
                colorHex: appState.member?.calendarColor
            )
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(appState.displayName)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(appState.shop?.name ?? "")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            if let role = appState.role {
                StatusBadge(role)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .themedRow()
    }
}

/// Maps a More item to its feature's root screen.
struct MoreDestinationView: View {
    let item: MoreItem

    var body: some View {
        switch item {
        case .quotes: QuotesView()
        case .invoices: InvoicesView()
        case .payments: PaymentsView()
        case .memberships: MembershipsView()
        case .timeClock: TimeClockView()
        case .tasks: OpsTasksView()
        case .reports: ReportsView()
        case .team: TeamView()
        case .catalog: CatalogView()
        case .settings: SettingsView()
        case .notifications: NotificationsView()
        }
    }
}
