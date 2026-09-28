//
//  AccountDeletionView.swift
//  DetailCRM
//
//  Deleting your account (App Store guideline 5.1.1(v)), reached from
//  More > Your account and from the shop picker's account menu. A shop
//  can't be left without an owner, so the shops the person owns
//  (`account_deletion_blockers`) are listed first, each with what can be
//  done about it right here: delete the shop (`payments` → `delete_shop`,
//  ShopDeleteSheet) or, for the shop you're in, make another team member
//  the owner (Team > member > Make owner, `transfer_ownership`). Once no
//  shop is left, the account is deleted (`account` → `delete_account`) and
//  the app signs out. Every rule is enforced by the server.
//

import SwiftUI
import DetailCore

struct AccountDeletionView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var owned: LoadState<[AccountOwnedShop]> = .idle
    @State private var deleting: AccountOwnedShop?
    @State private var confirmation: ConfirmationRequest?
    @State private var errorMessage: String?
    /// The shop open in the app was deleted: memberships are re-read when
    /// this screen goes away, so the app leaves that shop.
    @State private var deletedCurrentShop = false

    var body: some View {
        FormScreen {
            Text("Deleting your account permanently removes your sign-in and profile and takes you off every shop's team. The shops' customers, jobs and payments stay with the shops.")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ownedShopsSection
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if let errorMessage {
                    InlineMessage(text: errorMessage, kind: .error)
                }
                Button(role: .destructive) {
                    confirmDeleteAccount()
                } label: {
                    Text("Delete account")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.themeDestructive)
                .disabled(!(owned.value?.isEmpty ?? true))
                if let shops = owned.value, !shops.isEmpty {
                    Text("Available once you no longer own a shop.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .navigationTitle("Delete account")
        .navigationBarTitleDisplayMode(.inline)
        .confirmation($confirmation)
        .sheet(item: $deleting) { shop in
            ShopDeleteSheet(shop: shop) { _ in
                await shopDeleted(shop)
            }
        }
        .task {
            if owned.value == nil { await loadOwned() }
        }
        .refreshable { await loadOwned() }
        .onDisappear {
            guard deletedCurrentShop else { return }
            deletedCurrentShop = false
            Task { try? await appState.refreshMemberships() }
        }
    }

    // MARK: Owned shops

    @ViewBuilder
    private var ownedShopsSection: some View {
        switch owned {
        case .idle, .loading:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                Text("Checking the shops you own…")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                InlineMessage(text: "Couldn't check which shops you own. \(message)", kind: .error)
                AsyncButton("Try again", style: .themeSecondaryCompact) {
                    await loadOwned()
                }
            }
        case .loaded(let shops):
            if !shops.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    SectionHeader(title: shops.count == 1 ? "First, the shop you own" : "First, the shops you own")
                    Text("A shop always needs an owner. For each shop, either make another team member the owner or delete the shop.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(shops) { shop in
                        AccountOwnedShopCard(
                            shop: shop,
                            isCurrentShop: shop.shopID == appState.shop?.id,
                            delete: { deleting = shop }
                        )
                    }
                }
            }
        }
    }

    private func loadOwned() async {
        owned.beginLoading()
        let result = await LoadState<[AccountOwnedShop]>.result {
            try await AccountService.ownedShops()
        }
        owned.apply(result)
    }

    private func shopDeleted(_ shop: AccountOwnedShop) async {
        toasts.show("\(shop.name) was deleted.")
        if let shops = owned.value {
            owned = .loaded(shops.filter { $0.shopID != shop.shopID })
        }
        if shop.shopID == appState.shop?.id {
            // Leaving the deleted shop tears this screen down, so wait until
            // the person is done here.
            deletedCurrentShop = true
        } else {
            try? await appState.refreshMemberships()
        }
        await loadOwned()
    }

    // MARK: Delete account

    private func confirmDeleteAccount() {
        errorMessage = nil
        var message = "This can't be undone. You'll be signed out on this device and can't sign in again with \(appState.userEmail ?? "this email")."
        // Signing out deletes the pending video uploads (their only copy).
        if let note = UnsentVideoWarning.accountDeletionNote(videoCount: JobsResumableUploader.pending(userID: appState.userID).count) {
            message += " " + note
        }
        confirmation = ConfirmationRequest(
            title: "Delete your account?",
            message: message,
            confirmTitle: "Delete account",
            isDestructive: true
        ) {
            await deleteAccount()
        }
    }

    private func deleteAccount() async {
        do {
            try await AccountService.deleteAccount()
        } catch let blocked as AccountDeletionBlocked {
            owned = .loaded(blocked.owned)
            errorMessage = blocked.errorDescription
            return
        } catch {
            errorMessage = ErrorText.message(for: error)
            return
        }
        toasts.show("Your account was deleted.")
        await appState.signOut()
    }
}

/// One shop the person owns, with what they can do about it here.
private struct AccountOwnedShopCard: View {
    let shop: AccountOwnedShop
    let isCurrentShop: Bool
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(shop.name)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(transferHint)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive, action: delete) {
                Label("Delete \(shop.name)…", systemImage: "trash")
            }
            .buttonStyle(.themeSecondaryCompact)
            .accessibilityHint("Permanently deletes the shop and everything in it.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var transferHint: String {
        isCurrentShop
            ? "To keep it running, open Team, choose a team member and tap Make owner. Or delete the shop."
            : "To keep it running, switch to this shop, then open Team, choose a team member and tap Make owner. Or delete the shop."
    }
}

/// Type the shop's name to delete it (owner only; `payments` → `delete_shop`).
struct ShopDeleteSheet: View {
    let shop: AccountOwnedShop
    let onDeleted: (ShopDeletionResult) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var typedName = ""
    @State private var errorMessage: String?
    @State private var isDeleting = false

    private var matches: Bool {
        ShopService.deletionNameMatches(typedName, name: shop.name)
    }

    var body: some View {
        NavigationStack {
            FormScreen {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("This permanently deletes \(shop.name) and everything in it: customers, vehicles, jobs, quotes, invoices, payment records, photos, files and the team. It can't be undone.")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("The shop's subscription and every membership billed by card are cancelled, and open pay links stop working. Your Stripe account, its balance and payouts are not touched.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ThemedTextField(
                    label: "Type the shop's name to confirm",
                    placeholder: shop.name,
                    text: $typedName,
                    kind: .plain
                )
                if let errorMessage {
                    InlineMessage(text: errorMessage, kind: .error)
                }
                AsyncButton("Delete shop", role: .destructive, style: .themeDestructive) {
                    await deleteShop()
                }
                .disabled(!matches)
            }
            .navigationTitle("Delete shop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep shop") { dismiss() }
                        .disabled(isDeleting)
                }
            }
            .interactiveDismissDisabled(isDeleting)
        }
    }

    private func deleteShop() async {
        guard matches else { return }
        errorMessage = nil
        isDeleting = true
        do {
            let result = try await ShopService.deleteShop(shopID: shop.shopID, confirmName: typedName)
            isDeleting = false
            dismiss()
            await onDeleted(result)
        } catch {
            isDeleting = false
            errorMessage = ErrorText.message(for: error)
        }
    }
}
