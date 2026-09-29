//
//  SettingsYourShopsSection.swift
//  DetailCRM
//
//  Your account > Your shops: the shop teams the user belongs to, each with
//  "Leave…" (`leave_shop`) for every role but owner — the same list as the
//  web account page. Leaving deactivates only that membership: the person
//  loses access, stops being assignable, stops counting as a seat and stops
//  getting that shop's notifications; their other shops are not affected.
//  An owner hands the shop over (or deletes it) first.
//

import SwiftUI
import DetailCore

struct SettingsYourShopsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var confirmation: ConfirmationRequest?

    var body: some View {
        if !appState.memberships.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(title: "Your shops")
                Text("The shop teams you belong to. Leaving one removes your access to it; your other shops are not affected.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(appState.memberships) { membership in
                    row(membership)
                }
            }
            .confirmation($confirmation)
        }
    }

    private func row(_ membership: ShopMembership) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(membership.shop.name)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                StatusBadge(membership.role)
            }
            Spacer(minLength: Theme.Spacing.sm)
            if membership.role == .owner {
                Text("Transfer ownership to leave")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.trailing)
            } else {
                Button("Leave…") { confirmLeave(membership) }
                    .buttonStyle(.themeSecondaryCompact)
                    .fixedSize()
                    .accessibilityLabel("Leave \(membership.shop.name)")
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .contain)
    }

    private func confirmLeave(_ membership: ShopMembership) {
        let name = membership.shop.name
        let shopID = membership.shop.id
        confirmation = ConfirmationRequest(
            title: "Leave \(name)?",
            message: "You lose access to its schedule, jobs and customers right away, and you're clocked out of any open time entry there. To come back, an admin has to invite you again.",
            confirmTitle: "Leave shop",
            isDestructive: true
        ) {
            do {
                try await appState.leaveShop(shopID)
                toasts.show("You left \(name)")
            } catch {
                toasts.showError(error)
            }
        }
    }
}
