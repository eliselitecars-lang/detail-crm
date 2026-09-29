//
//  ShopPickerView.swift
//  DetailCRM
//
//  Shown when the signed-in user has no active shop: pick one of their
//  shops, create a new shop, or join a team by invite. Also reached from
//  More > Switch Shop. The Terms of Service and Privacy Policy are linked
//  under the choices and in the account menu (a signed-in person with no
//  shop can't reach Settings).
//

import SwiftUI
import DetailCore

enum ShopPickerRoute: Hashable {
    case createShop
    case joinShop
}

struct ShopPickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var path: [ShopPickerRoute] = []
    @State private var confirmation: ConfirmationRequest?
    @State private var showsAccountDeletion = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(appState.memberships.isEmpty ? "Welcome" : "Your shops")
                .toolbar { toolbarContent }
                .navigationDestination(for: ShopPickerRoute.self) { route in
                    switch route {
                    case .createShop:
                        CreateShopView()
                    case .joinShop:
                        JoinShopView()
                    }
                }
                .refreshable {
                    // Only re-reads the list: the user stays in the picker
                    // (switching shops never bounces back to the old shop).
                    do {
                        try await appState.refreshMemberships()
                    } catch {
                        toasts.showError(error)
                    }
                }
        }
        .confirmation($confirmation)
        .sheet(isPresented: $showsAccountDeletion) {
            NavigationStack {
                AccountDeletionView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showsAccountDeletion = false }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if appState.memberships.isEmpty {
            NoShopsView(path: $path)
        } else {
            List {
                Section {
                    ForEach(appState.memberships) { membership in
                        Button {
                            appState.selectShop(membership.shop.id)
                        } label: {
                            ShopRow(membership: membership)
                        }
                        .buttonStyle(.plain)
                        .themedRow()
                    }
                } header: {
                    Text("Choose a shop")
                }
                Section {
                    NavigationLink(value: ShopPickerRoute.createShop) {
                        Label("Create a new shop", systemImage: "plus.circle")
                            .foregroundStyle(Theme.glacier)
                    }
                    .themedRow()
                    NavigationLink(value: ShopPickerRoute.joinShop) {
                        Label("Join a team with an invite", systemImage: "person.badge.plus")
                            .foregroundStyle(Theme.glacier)
                    }
                    .themedRow()
                } footer: {
                    LegalLinksFooter(step: .createOrJoinShop)
                }
            }
            .listStyle(.insetGrouped)
            .screenBackground()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if appState.canCancelShopSwitch {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    appState.cancelSwitchingShop()
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if let email = appState.userEmail {
                    Text("Signed in as \(email)")
                }
                // The legal pages, reachable before any shop exists.
                if let terms = LegalWebLinks.termsOfService {
                    Link(destination: terms) {
                        Label("Terms of Service", systemImage: "doc.text")
                    }
                }
                if let privacy = LegalWebLinks.privacyPolicy {
                    Link(destination: privacy) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                }
                Button("Sign out", role: .destructive) {
                    confirmation = .signOut(appState)
                }
                Button("Delete account…", role: .destructive) {
                    showsAccountDeletion = true
                }
            } label: {
                Image(systemName: "person.crop.circle")
                    .accessibilityLabel("Account")
            }
        }
    }
}

private struct ShopRow: View {
    let membership: ShopMembership

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            AvatarView(name: membership.shop.name, size: Theme.Size.avatarMedium, colorHex: membership.shop.brandColor)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(membership.shop.name)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.sm)
            StatusBadge(membership.role)
            Image(systemName: "chevron.right")
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        [membership.shop.city, membership.shop.region]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
            .nonEmpty ?? "/book/\(membership.shop.slug)"
    }
}

private struct NoShopsView: View {
    @Binding var path: [ShopPickerRoute]

    var body: some View {
        FormScreen {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                BrandMark(size: 52)
                Text("Let's get you set up")
                    .font(Theme.Typography.largeTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text("Create a workspace for your shop, or join your team if someone invited you.")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: Theme.Spacing.md) {
                Button {
                    path.append(.createShop)
                } label: {
                    Label("Create my shop", systemImage: "plus")
                }
                .buttonStyle(.themePrimary)
                Button {
                    path.append(.joinShop)
                } label: {
                    Label("I have an invite", systemImage: "envelope.open")
                }
                .buttonStyle(.themeSecondary)
            }
            LegalLinksFooter(step: .createOrJoinShop)
        }
    }
}
