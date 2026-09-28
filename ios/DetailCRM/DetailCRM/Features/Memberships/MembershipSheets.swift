//
//  MembershipSheets.swift
//  DetailCRM
//
//  Membership sheets: new membership (customer + plan + optional vehicle →
//  create_membership → share the Stripe Checkout link), a member's details
//  (checkout link, cancel now / at period end) and the plan editor.
//

import SwiftUI
import DetailCore

// MARK: - Checkout link block

/// Fetches and shows a membership's Stripe Checkout link to share.
private struct MembershipCheckoutLinkBlock: View {
    let membershipID: UUID

    @Environment(AppState.self) private var appState
    @State private var link: MoneyCheckoutLink?
    @State private var errorText: String?
    @State private var nonce = MoneyEdge.newNonce()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let link {
                ShareLink(item: link.url) {
                    Label("Share checkout link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.themeMoney)
                if let expires = link.expiresDate {
                    Text("The link works until \(appState.clock.dateTimeText(expires)). Billing starts when the customer completes it.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                AsyncButton(style: .themeMoney) {
                    await fetch()
                } label: {
                    Label("Get checkout link", systemImage: "link")
                }
            }
            if let errorText {
                InlineMessage(text: errorText)
            }
        }
    }

    private func fetch() async {
        errorText = nil
        do {
            let shopID = try appState.requireShopID()
            link = try await MembershipService.checkoutLink(shopID: shopID, membershipID: membershipID, nonce: nonce)
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }
}

// MARK: - New membership

struct MembershipNewSheet: View {
    let onCreated: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var plans: LoadState<[MembershipPlan]> = .idle
    @State private var customer: QuoteCustomerRef?
    @State private var planID: UUID?
    @State private var vehicleID: UUID?
    @State private var vehicles: [QuoteVehicleRef] = []
    @State private var showingCustomerPicker = false
    @State private var created: Membership?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            LoadStateView(plans, loadingLabel: "Loading plans…", retry: { await loadPlans() }) { list in
                formContent(plans: list.filter { $0.isAvailable })
            }
            .screenBackground()
            .navigationTitle("New membership")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(created == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
            .task { await loadPlans() }
            .task(id: customer?.id) { await loadVehicles() }
            .sheet(isPresented: $showingCustomerPicker) {
                QuoteCustomerPickerSheet { picked in
                    if picked.id != customer?.id {
                        customer = picked
                        vehicleID = nil
                        vehicles = []
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func formContent(plans available: [MembershipPlan]) -> some View {
        if available.isEmpty {
            EmptyStateView(
                systemImage: "arrow.triangle.2.circlepath",
                title: "No active plans",
                message: "Create a plan first (Memberships › Plans), then sign customers up."
            )
        } else if let created {
            createdContent(created, plan: available.first(where: { $0.id == created.planID }))
        } else {
            FormScreen {
                MoneyPickerField(
                    label: "Customer",
                    value: customer?.displayName,
                    placeholder: "Choose a customer"
                ) {
                    showingCustomerPicker = true
                }
                FormRow("Plan") {
                    Picker("Plan", selection: $planID) {
                        Text("Choose a plan").tag(UUID?.none)
                        ForEach(available) { plan in
                            Text("\(plan.name) · \(Money.format(cents: plan.priceCents, currencyCode: appState.currencyCode)) \(plan.billingText)")
                                .tag(Optional(plan.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .inputFieldStyle()
                }
                FormRow("Vehicle (optional)", hint: "Limit the membership to one vehicle, or leave it for all of the customer's vehicles.") {
                    Picker("Vehicle", selection: $vehicleID) {
                        Text("All vehicles").tag(UUID?.none)
                        ForEach(vehicles) { vehicle in
                            Text(vehicle.displayName).tag(Optional(vehicle.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .inputFieldStyle()
                    .disabled(customer == nil)
                }
                if let errorText {
                    InlineMessage(text: errorText)
                }
                AsyncButton("Create membership") {
                    await create()
                }
                .disabled(customer == nil || planID == nil)
            }
        }
    }

    private func createdContent(_ membership: Membership, plan: MembershipPlan?) -> some View {
        FormScreen {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Label("Membership created", systemImage: "checkmark.circle.fill")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.success)
                Text("\(customer?.displayName ?? "The customer") is on \(plan?.name ?? "the plan"). Share the checkout link so they can add a card and start billing.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            MembershipCheckoutLinkBlock(membershipID: membership.id)
        }
    }

    private func loadPlans() async {
        guard let shopID = try? appState.requireShopID() else { return }
        plans.beginLoading()
        let result = await LoadState<[MembershipPlan]>.result {
            try await MembershipService.plans(shopID: shopID)
        }
        plans.apply(result)
    }

    private func loadVehicles() async {
        guard let customerID = customer?.id, let shopID = try? appState.requireShopID() else {
            vehicles = []
            return
        }
        do {
            vehicles = try await QuoteService.vehicles(shopID: shopID, customerID: customerID)
        } catch is CancellationError {
            return
        } catch {
            errorText = "Couldn't load vehicles: \(ErrorText.message(for: error))"
        }
    }

    private func create() async {
        errorText = nil
        guard let customer, let planID else {
            errorText = "Choose a customer and a plan."
            return
        }
        do {
            let membership = try await MembershipService.create(planID: planID, customerID: customer.id, vehicleID: vehicleID)
            created = membership
            toasts.show("Membership created")
            await onCreated()
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }
}

// MARK: - Member details

struct MembershipDetailSheet: View {
    let membership: Membership
    let plan: MembershipPlan?
    let customer: QuoteCustomerRef?
    let vehicle: QuoteVehicleRef?
    let onChanged: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var confirmation: ConfirmationRequest?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            FormScreen {
                header
                details
                if membership.needsCheckout {
                    MembershipCheckoutLinkBlock(membershipID: membership.id)
                }
                if let errorText {
                    InlineMessage(text: errorText)
                }
                cancelActions
            }
            .navigationTitle("Membership")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .confirmation($confirmation)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                Text(customer?.displayName ?? "Customer")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Theme.Spacing.sm)
                StatusBadge(membership.status)
            }
            if let periodText = MembershipText.period(membership, clock: appState.clock) {
                Text(periodText)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            InfoRow(label: "Plan", value: plan?.name ?? "Plan", systemImage: "arrow.triangle.2.circlepath")
            if let price = membership.price(plan: plan) {
                HStack {
                    Text("Price")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: Theme.Spacing.md)
                    MoneyText(cents: price, currencyCode: appState.currencyCode)
                    if let billing = membership.billingText(plan: plan) {
                        Text(billing)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            InfoRow(label: "Vehicle", value: vehicle?.displayName ?? "All vehicles", systemImage: "car")
            if let startedAt = membership.startedAt {
                InfoRow(label: "Started", value: appState.clock.shortDayText(startedAt), systemImage: "calendar")
            }
            if let cancelledAt = membership.cancelledAt {
                InfoRow(label: "Cancelled", value: appState.clock.shortDayText(cancelledAt), systemImage: "xmark.circle")
            }
            if showsUsage {
                Divider().overlay(Theme.border)
                MoneyMembershipUsageRow(membershipID: membership.id)
            }
        }
        .cardStyle()
    }

    /// Visits are counted for a plan that includes services, while the
    /// membership is billing.
    private var showsUsage: Bool {
        guard let plan, !plan.includedServiceIDs.isEmpty else { return false }
        return membership.status == .active || membership.status == .pastDue
    }

    @ViewBuilder
    private var cancelActions: some View {
        if membership.status == .incomplete && membership.canCancel {
            Button(role: .destructive) {
                confirmation = ConfirmationRequest(
                    title: "Discard this membership?",
                    message: "The customer never started billing. Their checkout link stops working.",
                    confirmTitle: "Discard",
                    isDestructive: true
                ) {
                    await cancel(atPeriodEnd: false)
                }
            } label: {
                Text("Discard membership")
                    .foregroundStyle(Theme.danger)
            }
            .buttonStyle(.themePlain)
        } else if (membership.status == .active || membership.status == .pastDue) && membership.canCancel {
            Button("Cancel at end of period") {
                confirmation = ConfirmationRequest(
                    title: "Cancel at the end of the period?",
                    message: "The customer keeps their benefits until the paid period ends; billing then stops.",
                    confirmTitle: "Cancel at period end"
                ) {
                    await cancel(atPeriodEnd: true)
                }
            }
            .buttonStyle(.themeSecondary)
            Button(role: .destructive) {
                confirmation = ConfirmationRequest(
                    title: "Cancel now?",
                    message: "Billing stops immediately and the membership ends today.",
                    confirmTitle: "Cancel now",
                    isDestructive: true
                ) {
                    await cancel(atPeriodEnd: false)
                }
            } label: {
                Text("Cancel now")
                    .foregroundStyle(Theme.danger)
            }
            .buttonStyle(.themePlain)
        }
    }

    private func cancel(atPeriodEnd: Bool) async {
        errorText = nil
        do {
            let shopID = try appState.requireShopID()
            let result = try await MembershipService.cancel(shopID: shopID, membershipID: membership.id, atPeriodEnd: atPeriodEnd)
            await onChanged()
            toasts.show(result.cancelAtPeriodEnd ? "Membership ends at the end of the period" : "Membership cancelled")
            dismiss()
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }
}

// MARK: - Plan editor

struct MembershipPlanEditorSheet: View {
    let plan: MembershipPlan?
    let onSaved: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var draft = MembershipService.PlanDraft()
    @State private var priceText = ""
    @State private var discountText = ""
    @State private var didSetUp = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            FormScreen {
                ThemedTextField(label: "Name", placeholder: "Plan name", text: $draft.name, kind: .plain)
                FormRow("Description (optional)") {
                    TextField("What members get", text: $draft.planDescription, axis: .vertical)
                        .lineLimit(2...6)
                        .inputFieldStyle()
                }
                ThemedTextField(label: "Price", placeholder: "0.00", text: $priceText, kind: .money)
                FormRow("Billing") {
                    Picker("Billing", selection: $draft.interval) {
                        ForEach(MembershipPlanInterval.allCases) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .onChange(of: draft.interval) {
                    let range = draft.interval.planCountRange
                    draft.intervalCount = min(max(draft.intervalCount, range.lowerBound), range.upperBound)
                }
                if draft.interval != .year {
                    Stepper(value: $draft.intervalCount, in: draft.interval.planCountRange) {
                        Text("Bills \(draft.interval.billingText(count: draft.intervalCount))")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                ThemedTextField(
                    label: "Discount on other services (optional)",
                    placeholder: "e.g. 10",
                    text: $discountText,
                    kind: .money,
                    hint: "Percent off services that aren't included in the plan."
                )
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Toggle("Limit included visits", isOn: usesLimitBinding)
                        .font(Theme.Typography.body)
                        .tint(Theme.glacier)
                    if let uses = draft.includedUsesPerPeriod {
                        Stepper(value: usesBinding(default: uses), in: 1...MembershipPlan.maxUsesPerPeriod) {
                            Text("\(uses) visit\(uses == 1 ? "" : "s") per \(draft.interval.periodText(count: draft.intervalCount))")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                    Text(draft.includedUsesPerPeriod == nil
                        ? "Included services can be used any number of times."
                        : "After that, included services are charged at catalog prices until the next billing period.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FormRow("Terms (optional)", hint: "Shown to customers when they join online.") {
                    TextField("Cancellation, what's included…", text: $draft.terms, axis: .vertical)
                        .lineLimit(2...8)
                        .inputFieldStyle()
                }
                Toggle("Available for new members", isOn: $draft.active)
                    .font(Theme.Typography.body)
                    .tint(Theme.glacier)
                Toggle("Offer on the online join page", isOn: $draft.onlineJoinable)
                    .font(Theme.Typography.body)
                    .tint(Theme.glacier)
                    .disabled(!draft.active)
                if plan != nil {
                    InlineMessage(
                        text: "Changing the price or billing period applies to new sign-ups; current members keep what they signed up for.",
                        kind: .info
                    )
                }
                if let errorText {
                    InlineMessage(text: errorText)
                }
                AsyncButton(plan == nil ? "Create plan" : "Save plan") {
                    await save()
                }
            }
            .navigationTitle(plan == nil ? "New plan" : "Edit plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: setUp)
        }
    }

    private var usesLimitBinding: Binding<Bool> {
        Binding(
            get: { draft.includedUsesPerPeriod != nil },
            set: { isOn in
                draft.includedUsesPerPeriod = isOn ? (draft.includedUsesPerPeriod ?? 1) : nil
            }
        )
    }

    private func usesBinding(default value: Int) -> Binding<Int> {
        Binding(
            get: { draft.includedUsesPerPeriod ?? value },
            set: { draft.includedUsesPerPeriod = $0 }
        )
    }

    private func setUp() {
        guard !didSetUp else { return }
        didSetUp = true
        if let plan {
            draft = MembershipService.PlanDraft(plan: plan)
            priceText = Money.editableString(cents: plan.priceCents, currencyCode: appState.currencyCode)
            discountText = plan.discountBps > 0
                ? MoneyPercentFormat.text(basisPoints: plan.discountBps).replacingOccurrences(of: "%", with: "")
                : ""
        }
    }

    private func save() async {
        errorText = nil
        guard let price = Money.parseCents(priceText, currencyCode: appState.currencyCode), price > 0 else {
            errorText = "Enter the plan price."
            return
        }
        var discount = 0
        if discountText.trimmedNonEmpty != nil {
            guard let bps = MoneyPercentFormat.basisPoints(from: discountText) else {
                errorText = "Enter the discount as a percent from 0 to 100."
                return
            }
            discount = bps
        }
        if draft.terms.count > MembershipService.maxTermsLength {
            errorText = "Keep the terms under 5,000 characters."
            return
        }
        var toSave = draft
        toSave.priceCents = price
        toSave.discountBps = discount
        // A plan that isn't available can't be joined online either.
        if !toSave.active {
            toSave.onlineJoinable = false
        }
        do {
            let shopID = try appState.requireShopID()
            try await MembershipService.savePlan(shopID: shopID, draft: toSave)
            await onSaved()
            toasts.show(plan == nil ? "Plan created" : "Plan saved")
            dismiss()
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }
}
