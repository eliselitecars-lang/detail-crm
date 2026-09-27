//
//  SettingsBusinessProfileView.swift
//  DetailCRM
//
//  Business profile: name, phone, email, address, time zone and review
//  link. Owners/admins edit; managers read. The server validates every
//  field again (E.164 phone, email, time zone name, lengths).
//

import SwiftUI
import DetailCore

struct SettingsBusinessProfileView: View {
    let canEdit: Bool
    let onSaved: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var state: LoadState<Shop> = .idle
    @State private var draft: ShopSettingsProfileDraft?
    @State private var errorMessage: String?
    @State private var showErrors = false

    var body: some View {
        LoadStateView(state, retry: { await load() }) { shop in
            if canEdit, let binding = draftBinding {
                SettingsProfileForm(
                    draft: binding,
                    original: ShopSettingsProfileDraft(shop: shop),
                    showErrors: showErrors,
                    errorMessage: errorMessage,
                    save: { await save() }
                )
            } else {
                SettingsProfileReadOnly(shop: shop)
            }
        }
        .screenBackground()
        .navigationTitle("Business profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// A non-optional binding into `draft` once it exists.
    private var draftBinding: Binding<ShopSettingsProfileDraft>? {
        guard let current = draft else { return nil }
        return Binding(
            get: { draft ?? current },
            set: { draft = $0 }
        )
    }

    private func load() async {
        guard let shopID = appState.shop?.id else {
            state = .failed(AppError.noShopSelected.errorDescription ?? "Choose a shop first.")
            return
        }
        state.beginLoading()
        let result = await LoadState<Shop>.result {
            try await SettingsService.shop(shopID: shopID)
        }
        state.apply(result)
        if draft == nil, let shop = state.value {
            draft = ShopSettingsProfileDraft(shop: shop)
        }
    }

    private func save() async {
        errorMessage = nil
        showErrors = true
        guard let draft, let update = draft.update() else { return }
        do {
            let shopID = try appState.requireShopID()
            let shop = try await SettingsService.updateProfile(shopID: shopID, update: update)
            state = .loaded(shop)
            self.draft = ShopSettingsProfileDraft(shop: shop)
            showErrors = false
            toasts.show("Business profile saved.")
            do {
                try await appState.refreshCurrentShop()
            } catch {
                toasts.showError(error)
            }
            await onSaved()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

private struct SettingsProfileForm: View {
    @Binding var draft: ShopSettingsProfileDraft
    let original: ShopSettingsProfileDraft
    let showErrors: Bool
    let errorMessage: String?
    let save: () async -> Void

    var body: some View {
        let problems = draft.problems
        FormScreen {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                SectionHeader(title: "Business")
                ThemedTextField(label: "Business name", placeholder: "Your business", text: $draft.name, kind: .name,
                                error: showErrors ? problems["name"] : nil)
                ThemedTextField(label: "Phone", placeholder: "(555) 123-4567", text: $draft.phone, kind: .phone,
                                hint: "Shown to customers on quotes, invoices and your booking page.",
                                error: showErrors ? problems["phone"] : nil)
                ThemedTextField(label: "Email", placeholder: "hello@example.com", text: $draft.email, kind: .email,
                                error: showErrors ? problems["email"] : nil)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                SectionHeader(title: "Address")
                ThemedTextField(label: "Street address", placeholder: "123 Main St", text: $draft.addressLine1)
                ThemedTextField(label: "Address line 2", placeholder: "Suite, unit (optional)", text: $draft.addressLine2)
                ThemedTextField(label: "City", placeholder: "City", text: $draft.city)
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    ThemedTextField(label: "State / region", placeholder: "State", text: $draft.region)
                    ThemedTextField(label: "Postal code", placeholder: "ZIP", text: $draft.postalCode)
                }
                if showErrors, let problem = problems["address"] {
                    InlineMessage(text: problem, kind: .error)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                SectionHeader(title: "Time zone & reviews")
                FormRow("Time zone", hint: timezoneHint) {
                    NavigationLink {
                        TimeZonePickerView(selection: $draft.timezone)
                    } label: {
                        HStack {
                            Text(TimeZonePickerView.displayName(for: draft.timezone))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(Theme.Typography.footnote.weight(.semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .accessibilityHidden(true)
                        }
                        .inputFieldStyle()
                    }
                    .buttonStyle(.plain)
                }
                ThemedTextField(label: "Review link", placeholder: "https://g.page/r/…", text: $draft.reviewURL, kind: .url,
                                hint: "Sent in review requests after a job is completed.",
                                error: showErrors ? problems["reviewURL"] : nil)
            }
            if let errorMessage {
                InlineMessage(text: errorMessage, kind: .error)
            }
            AsyncButton("Save changes", style: .themePrimary) {
                await save()
            }
            .disabled(draft == original)
        }
    }

    private var timezoneHint: String {
        if draft.timezone != original.timezone {
            return "Changing the time zone changes how every date and business hour is read."
        }
        return "All dates, hours and reports use this time zone."
    }
}

private struct SettingsProfileReadOnly: View {
    let shop: Shop

    var body: some View {
        List {
            Section {
                InfoRow(label: "Name", value: shop.name).themedRow()
                InfoRow(label: "Phone", value: shop.phone.map { PhoneNumber.format($0) } ?? "—").themedRow()
                InfoRow(label: "Email", value: shop.email ?? "—").themedRow()
                InfoRow(label: "Address", value: shop.addressSummary ?? "—").themedRow()
                InfoRow(label: "Time zone", value: TimeZonePickerView.displayName(for: shop.timezone)).themedRow()
                InfoRow(label: "Review link", value: shop.reviewURL ?? "—").themedRow()
            } footer: {
                Text("Only owners and admins can change the business profile.")
            }
        }
        .listStyle(.insetGrouped)
    }
}
