//
//  SettingsView.swift
//  DetailCRM
//
//  The settings subset on the phone. Managers and above read; owners and
//  admins edit (RLS enforces the same): business profile, online booking
//  switches, business hours, tax rate, whether technicians may collect
//  payments, the Stripe connection status (connecting happens on the web)
//  and the signed-in user's own account. Everything else lives in the web
//  app's settings. After a shop change AppState is refreshed so the new
//  time zone / tax / payment policy apply everywhere.
//

import SwiftUI
import DetailCore

/// What the Settings root shows (the Stripe status loads separately).
struct SettingsSnapshot: Equatable {
    var shop: Shop
    var booking: ShopSettingsBooking?
}

/// The Stripe Connect row (nil account = not connected).
struct SettingsStripeStatus: Equatable {
    var account: ShopSettingsStripeAccount?
}

enum SettingsLoader {
    static func load(shopID: UUID) async throws -> SettingsSnapshot {
        async let shopRow = SettingsService.shop(shopID: shopID)
        async let bookingRow = SettingsService.booking(shopID: shopID)
        return try await SettingsSnapshot(shop: shopRow, booking: bookingRow)
    }
}

/// One online-booking switch (each is saved on its own column).
enum SettingsBookingSwitch {
    case enabled
    case autoConfirm
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var state: LoadState<SettingsSnapshot> = .idle
    /// Secondary: a failed Stripe read only affects its own section.
    @State private var stripeState: LoadState<SettingsStripeStatus> = .idle
    @State private var editingTax = false
    /// True while a booking switch is being saved (both switches wait).
    @State private var savingBooking = false

    var body: some View {
        LoadStateView(state, loadingLabel: "Loading settings…", retry: { await load() }) { snapshot in
            SettingsList(
                snapshot: snapshot,
                stripeState: stripeState,
                stripeVisible: appState.can(.manageStripeConnect),
                canEdit: appState.can(.editShopSettings),
                savingBooking: savingBooking,
                clock: appState.clock,
                setBooking: { field, value in await saveBooking(field, value: value) },
                setTechsCollect: { allowed in await saveTechsCollect(allowed) },
                editTax: { editingTax = true },
                retryStripe: { await loadStripe() },
                reload: { await load() }
            )
            .sheet(isPresented: $editingTax) {
                SettingsTaxSheet(currentBps: snapshot.shop.taxRateBps) {
                    await load()
                }
            }
        }
        .screenBackground()
        .navigationTitle("Settings")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let shopID = appState.shop?.id else {
            state = .failed(AppError.noShopSelected.errorDescription ?? "Choose a shop first.")
            return
        }
        state.beginLoading()
        let result = await LoadState<SettingsSnapshot>.result {
            try await SettingsLoader.load(shopID: shopID)
        }
        if let message = result.errorMessage, state.value != nil {
            toasts.show(message, style: .error)
        }
        state.apply(result)
        await loadStripe()
    }

    /// Stripe status (owners/admins); errors stay inside the Stripe section.
    private func loadStripe() async {
        guard appState.can(.manageStripeConnect), let shopID = appState.shop?.id else {
            stripeState = .loaded(SettingsStripeStatus(account: nil))
            return
        }
        stripeState.beginLoading()
        let result = await LoadState<SettingsStripeStatus>.result {
            SettingsStripeStatus(account: try await SettingsService.stripeAccount(shopID: shopID))
        }
        stripeState.apply(result)
    }

    private func saveBooking(_ field: SettingsBookingSwitch, value: Bool) async {
        guard !savingBooking else { return }
        savingBooking = true
        defer { savingBooking = false }
        do {
            let shopID = try appState.requireShopID()
            let saved: ShopSettingsBooking
            switch field {
            case .enabled:
                saved = try await SettingsService.updateBooking(shopID: shopID, enabled: value)
            case .autoConfirm:
                saved = try await SettingsService.updateBooking(shopID: shopID, autoConfirm: value)
            }
            if var snapshot = state.value {
                snapshot.booking = saved
                state = .loaded(snapshot)
            }
            toasts.show("Booking settings saved.")
        } catch {
            toasts.showError(error)
            await load()
        }
    }

    private func saveTechsCollect(_ allowed: Bool) async {
        do {
            let shopID = try appState.requireShopID()
            let shop = try await SettingsService.updateTechsCanCollect(shopID: shopID, allowed: allowed)
            if var snapshot = state.value {
                snapshot.shop = shop
                state = .loaded(snapshot)
            }
            toasts.show(allowed ? "Technicians can now collect payments on their jobs." : "Only managers and above can collect payments now.")
            try await appState.refreshCurrentShop()
        } catch {
            toasts.showError(error)
            await load()
        }
    }
}

private struct SettingsList: View {
    let snapshot: SettingsSnapshot
    let stripeState: LoadState<SettingsStripeStatus>
    let stripeVisible: Bool
    let canEdit: Bool
    let savingBooking: Bool
    let clock: ShopClock
    let setBooking: (SettingsBookingSwitch, Bool) async -> Void
    let setTechsCollect: (Bool) async -> Void
    let editTax: () -> Void
    let retryStripe: () async -> Void
    let reload: () async -> Void

    var body: some View {
        List {
            if !canEdit {
                Section {
                    InlineMessage(text: "Only owners and admins can change shop settings. You can view them here.", kind: .info)
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                NavigationLink {
                    SettingsBusinessProfileView(canEdit: canEdit) {
                        await reload()
                    }
                } label: {
                    SettingsNavRow(title: snapshot.shop.name, subtitle: profileSubtitle, systemImage: "building.2")
                }
                .themedRow()
                NavigationLink {
                    SettingsHoursView(canEdit: canEdit)
                } label: {
                    SettingsNavRow(title: "Business hours", subtitle: "Used for online booking availability", systemImage: "clock")
                }
                .themedRow()
            } header: {
                Text("Business")
            }
            SettingsBookingSection(booking: snapshot.booking, canEdit: canEdit, saving: savingBooking, setBooking: setBooking)
            SettingsMoneySection(shop: snapshot.shop, canEdit: canEdit, setTechsCollect: setTechsCollect, editTax: editTax)
            SettingsStripeSection(state: stripeState, visible: stripeVisible, clock: clock, retry: retryStripe)
            Section {
                NavigationLink {
                    SettingsAccountView()
                } label: {
                    SettingsNavRow(title: "Your account", subtitle: "Name and phone", systemImage: "person.crop.circle")
                }
                .themedRow()
            } header: {
                Text("Account")
            } footer: {
                Text("Sign out and switch shops from the More tab.")
            }
            Section {
                SettingsWebNote()
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var profileSubtitle: String {
        let zone = TimeZonePickerView.displayName(for: snapshot.shop.timezone)
        if let address = snapshot.shop.addressSummary {
            return "\(address) · \(zone)"
        }
        return zone
    }
}

/// Icon + title + subtitle row for NavigationLinks.
struct SettingsNavRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.glacier)
                .frame(width: Theme.Size.rowIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }
}

/// Online booking on/off and auto-confirm. Each switch saves only its
/// own column, and both wait while a save is running.
private struct SettingsBookingSection: View {
    let booking: ShopSettingsBooking?
    let canEdit: Bool
    let saving: Bool
    let setBooking: (SettingsBookingSwitch, Bool) async -> Void

    var body: some View {
        Section {
            if let booking {
                Toggle(isOn: Binding(
                    get: { booking.enabled },
                    set: { value in Task { await setBooking(.enabled, value) } }
                )) {
                    Text("Online booking")
                }
                .disabled(!canEdit || saving)
                .themedRow()
                Toggle(isOn: Binding(
                    get: { booking.autoConfirm },
                    set: { value in Task { await setBooking(.autoConfirm, value) } }
                )) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("Confirm bookings automatically")
                        Text("Off: new online bookings wait for your approval.")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .disabled(!canEdit || saving)
                .themedRow()
            } else {
                Text("Booking settings aren't available.")
                    .foregroundStyle(Theme.textSecondary)
                    .themedRow()
            }
        } header: {
            Text("Online booking")
        } footer: {
            Text("Lead time, slot length, deposits and service area are set in the web app.")
        }
    }
}

/// Tax rate and the technicians-collect-payments switch.
private struct SettingsMoneySection: View {
    let shop: Shop
    let canEdit: Bool
    let setTechsCollect: (Bool) async -> Void
    let editTax: () -> Void

    var body: some View {
        Section {
            Button {
                if canEdit { editTax() }
            } label: {
                HStack {
                    Text("Sales tax rate")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(ShopSettingsPercent.display(shop.taxRateBps))
                        .foregroundStyle(canEdit ? Theme.glacier : Theme.textSecondary)
                        .monospacedDigit()
                }
            }
            .disabled(!canEdit)
            .accessibilityHint(canEdit ? "Edit the tax rate" : "")
            .themedRow()
            Toggle(isOn: Binding(
                get: { shop.techsCanCollectPayments },
                set: { value in Task { await setTechsCollect(value) } }
            )) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Technicians can collect payments")
                    Text("On their assigned jobs only.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .disabled(!canEdit)
            .themedRow()
        } header: {
            Text("Taxes & payments")
        } footer: {
            Text("The tax rate applies to new jobs, quotes and invoices; existing documents keep their rate.")
        }
    }
}

/// Read-only Stripe Connect status with a link to the web settings.
/// Loading and errors stay inside this section.
private struct SettingsStripeSection: View {
    let state: LoadState<SettingsStripeStatus>
    let visible: Bool
    let clock: ShopClock
    let retry: () async -> Void

    private var isConnected: Bool { state.value?.account != nil }

    var body: some View {
        Section {
            if !visible {
                Text("Only owners and admins can see the payment account.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .themedRow()
            } else {
                SettingsStripeStatusRows(state: state, clock: clock, retry: retry)
                SettingsWebLinkRow(
                    title: isConnected ? "Manage in web settings" : "Open web settings to connect",
                    url: ShopSettingsWebLinks.paymentsSettings
                )
                .themedRow()
            }
        } header: {
            Text("Card payments")
        } footer: {
            Text("Connecting Stripe and changing payout details happen in the web app.")
        }
    }
}

private struct SettingsStripeStatusRows: View {
    let state: LoadState<SettingsStripeStatus>
    let clock: ShopClock
    let retry: () async -> Void

    var body: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: Theme.Spacing.sm) {
                Text("Stripe")
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                ProgressView()
                    .accessibilityLabel("Loading Stripe status")
            }
            .themedRow()
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                InlineMessage(text: message, kind: .error)
                AsyncButton("Try again", style: .themeSecondaryCompact) {
                    await retry()
                }
            }
            .themedRow()
        case .loaded(let status):
            if let account = status.account {
                HStack {
                    Text("Stripe")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    StatusBadge(text: account.statusText, tone: account.tone)
                }
                .themedRow()
                InfoRow(label: "Card payments", value: account.chargesEnabled ? "Enabled" : "Not yet")
                    .themedRow()
                InfoRow(label: "Payouts", value: account.payoutsEnabled ? "Enabled" : "Not yet")
                    .themedRow()
                InfoRow(label: "Last updated", value: clock.dateTimeText(account.updatedAt))
                    .themedRow()
            } else {
                HStack {
                    Text("Stripe")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    StatusBadge(text: "Not connected", tone: .warning)
                }
                .themedRow()
            }
        }
    }
}

/// A Link to the web app, or a note when WEB_APP_URL isn't configured.
struct SettingsWebLinkRow: View {
    let title: String
    let url: URL?

    var body: some View {
        if let url {
            Link(destination: url) {
                HStack {
                    Label(title, systemImage: "safari")
                        .foregroundStyle(Theme.glacier)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                }
            }
        } else {
            Text("Open the web app to manage this.")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct SettingsWebNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            InlineMessage(
                text: "Branding, message templates, coupons, resources, vehicle categories, forms and blocked times are managed in the web app.",
                kind: .info
            )
            if let url = ShopSettingsWebLinks.settings {
                Link(destination: url) {
                    Label("Open all settings on the web", systemImage: "safari")
                        .font(Theme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(Theme.glacier)
                }
            }
        }
    }
}

/// Owner/admin sheet for the shop's sales tax rate.
private struct SettingsTaxSheet: View {
    let currentBps: Int
    let onSaved: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var errorMessage: String?

    init(currentBps: Int, onSaved: @escaping () async -> Void) {
        self.currentBps = currentBps
        self.onSaved = onSaved
        _text = State(initialValue: ShopSettingsPercent.text(fromBasisPoints: currentBps))
    }

    private var bps: Int? {
        text.trimmedNonEmpty == nil ? 0 : ShopSettingsPercent.basisPoints(from: text)
    }

    var body: some View {
        NavigationStack {
            FormScreen {
                ThemedTextField(
                    label: "Sales tax rate (%)",
                    placeholder: "0",
                    text: $text,
                    kind: .money,
                    hint: "For example 8.25. Use 0 if you don't charge tax.",
                    error: bps == nil ? "Enter a percentage between 0 and 100 with up to 2 decimals." : nil
                )
                if let errorMessage {
                    InlineMessage(text: errorMessage, kind: .error)
                }
                AsyncButton("Save tax rate", style: .themePrimary) {
                    await save()
                }
                .disabled(bps == nil)
            }
            .navigationTitle("Tax rate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func save() async {
        errorMessage = nil
        guard let bps else { return }
        do {
            let shopID = try appState.requireShopID()
            _ = try await SettingsService.updateTaxRate(shopID: shopID, basisPoints: bps)
            toasts.show("Tax rate saved.")
            do {
                try await appState.refreshCurrentShop()
            } catch {
                toasts.showError(error)
            }
            await onSaved()
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
