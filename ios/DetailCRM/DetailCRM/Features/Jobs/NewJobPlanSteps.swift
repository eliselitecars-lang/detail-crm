//
//  NewJobPlanSteps.swift
//  DetailCRM
//
//  Steps 3–5 of the New Job flow: services (priced by the server for the
//  vehicle), schedule (shop time zone, location, bay/van, team) and the
//  review with the server's price preview and Create.
//

import SwiftUI
import DetailCore

// MARK: - Step 3: services

struct NewJobServicesStep: View {
    @Bindable var model: NewJobModel

    @Environment(AppState.self) private var appState

    var body: some View {
        LoadStateView(model.services, loadingLabel: "Pricing services…", retry: { await model.loadServices() }) { data in
            content(data)
        }
        .task(id: model.pricingKey) {
            await model.loadServices()
        }
    }

    private func content(_ data: NewJobServicesData) -> AnyView {
        AnyView(
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    pricingNote(data)
                    JobCatalogSelectionList(
                        catalog: data.catalog,
                        pricing: data.pricing,
                        selected: $model.selectedServiceIDs,
                        currencyCode: appState.currencyCode
                    )
                    footer
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.vertical, Theme.Spacing.lg)
            }
        )
    }

    @ViewBuilder
    private func pricingNote(_ data: NewJobServicesData) -> some View {
        if !data.pricing.memberships.isEmpty {
            InlineMessage(
                text: "Member: " + data.pricing.memberships.map(\.planName).joined(separator: ", ") + ". Included services show at no charge.",
                kind: .success
            )
        }
        if model.vehicle != nil && model.vehicle?.categoryID == nil {
            InlineMessage(text: "This vehicle has no size category, so base prices are shown.", kind: .info)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if model.suggestedDiscountBps > 0 {
                Toggle(isOn: $model.applyMemberDiscount) {
                    Text("Apply member discount (\(JobsFormatting.percent(bps: model.suggestedDiscountBps)))")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                }
                .tint(Theme.glacier)
            }
            Button {
                model.continueFromServices()
            } label: {
                Text(continueTitle)
            }
            .buttonStyle(.themePrimary)
            Button("Skip — add services later") {
                model.selectedServiceIDs = []
                model.continueFromServices()
            }
            .buttonStyle(.themePlain)
        }
    }

    private var continueTitle: String {
        let count = model.selectedServiceIDs.count
        guard count > 0 else { return "Continue" }
        let minutes = model.selectedDurationMinutes
        let base = count == 1 ? "Continue with 1 service" : "Continue with \(count) services"
        return minutes > 0 ? base + " · " + ShopClock.durationText(minutes: minutes) : base
    }
}

// MARK: - Step 4: schedule

struct NewJobScheduleStep: View {
    @Bindable var model: NewJobModel

    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                whenCard
                whereCard
                if !model.resources.isEmpty {
                    resourceCard
                }
                if !model.team.isEmpty {
                    teamCard
                }
                notesCard
                if let problem = model.scheduleProblem {
                    InlineMessage(text: problem, kind: .error)
                }
                Button("Review") {
                    model.continueFromSchedule()
                }
                .buttonStyle(.themePrimary)
                .disabled(model.scheduleProblem != nil)
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.lg)
        }
    }

    private var whenCard: some View {
        JobSectionCard("When") {
            Toggle("Schedule later (request)", isOn: $model.scheduleLater)
                .tint(Theme.glacier)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textPrimary)
            if !model.scheduleLater {
                DatePicker("Starts", selection: $model.start, displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, model.clock.timeZone)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                Stepper(value: durationBinding, in: 15...(31 * 24 * 60), step: 15) {
                    HStack {
                        Text("Length")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(ShopClock.durationText(minutes: model.durationMinutes))
                            .font(Theme.Typography.body.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Text("Ends " + model.clock.dateTimeText(model.end) + " · shop time (" + model.clock.timeZone.identifier + ")")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text("The job is saved as a request without a time. Schedule it from the job later.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var durationBinding: Binding<Int> {
        Binding(
            get: { model.durationMinutes },
            set: { model.setDuration($0) }
        )
    }

    private var whereCard: some View {
        JobSectionCard("Where") {
            Picker("Location", selection: $model.locationType) {
                ForEach(JobLocationType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            if model.locationType == .mobile {
                if model.customer?.addressSummary != nil {
                    Button("Use the customer's address") {
                        model.useCustomerAddress()
                    }
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.glacier)
                }
                ThemedTextField(label: "Street address", placeholder: "123 Main St", text: $model.addressLine1)
                ThemedTextField(label: "Apt, suite (optional)", placeholder: "", text: $model.addressLine2)
                HStack(spacing: Theme.Spacing.sm) {
                    ThemedTextField(label: "City", placeholder: "City", text: $model.city)
                    ThemedTextField(label: "State", placeholder: "State", text: $model.region)
                }
                ThemedTextField(label: "ZIP / postal code", placeholder: "", text: $model.postalCode)
            }
        }
    }

    private var resourceCard: some View {
        JobSectionCard("Bay / van") {
            Picker("Bay / van", selection: $model.resourceID) {
                Text("None").tag(UUID?.none)
                ForEach(model.resources) { resource in
                    Text(resource.name).tag(UUID?.some(resource.id))
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.glacier)
        }
    }

    private var teamCard: some View {
        JobSectionCard("Assign") {
            VStack(spacing: 0) {
                ForEach(model.team) { member in
                    memberRow(member)
                }
            }
        }
    }

    private func memberRow(_ member: JobTeamMember) -> some View {
        let isOn = model.assigneeIDs.contains(member.memberID)
        return Button {
            if isOn {
                model.assigneeIDs.remove(member.memberID)
            } else {
                model.assigneeIDs.insert(member.memberID)
            }
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                AvatarView(name: member.displayName, size: Theme.Size.avatarSmall, colorHex: member.calendarColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text(member.displayName)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                    Text(member.role.displayName)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isOn ? Theme.glacier : Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Theme.Size.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(member.displayName)
        .accessibilityValue(isOn ? "Assigned" : "Not assigned")
    }

    private var notesCard: some View {
        JobSectionCard("Notes") {
            FormRow("For the customer") {
                TextField("Shown on their booking", text: $model.notes, axis: .vertical)
                    .lineLimit(2...6)
                    .inputFieldStyle()
            }
            FormRow("Internal") {
                TextField("Only your team sees these", text: $model.internalNotes, axis: .vertical)
                    .lineLimit(2...6)
                    .inputFieldStyle()
            }
        }
    }
}

// MARK: - Step 5: review

struct NewJobReviewStep: View {
    let model: NewJobModel
    let onCreate: () async -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                summaryCard
                servicesCard
                createArea
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.lg)
        }
        .task {
            await model.loadReviewPricingIfNeeded()
        }
    }

    private var summaryCard: some View {
        JobSectionCard("Job") {
            InfoRow(label: "Customer", value: model.customer?.displayName ?? "—", systemImage: "person")
            InfoRow(label: "Vehicle", value: model.vehicle?.label ?? "No vehicle", systemImage: "car")
            InfoRow(label: "When", value: whenText, systemImage: "calendar")
            InfoRow(label: "Where", value: whereText, systemImage: model.locationType.systemImage)
            if let resourceID = model.resourceID, let resource = model.resources.first(where: { $0.id == resourceID }) {
                InfoRow(label: "Bay / van", value: resource.name, systemImage: "square.grid.2x2")
            }
            InfoRow(label: "Team", value: teamText, systemImage: "person.2")
        }
    }

    private var whenText: String {
        if model.scheduleLater { return "Request — not scheduled" }
        return JobsFormatting.scheduleText(start: model.start, end: model.end, clock: model.clock)
    }

    private var whereText: String {
        if model.locationType == .mobile {
            return model.serviceAddressSummary ?? "Mobile"
        }
        return JobLocationType.shop.displayName
    }

    private var teamText: String {
        let names = model.team.filter { model.assigneeIDs.contains($0.memberID) }.map(\.displayName)
        return names.isEmpty ? "Nobody yet" : names.joined(separator: ", ")
    }

    private var servicesCard: some View {
        JobSectionCard("Services") {
            if model.selectedServiceIDs.isEmpty {
                JobEmptyLine(text: "No services — add them on the job later.", systemImage: "list.bullet.rectangle")
            } else {
                JobSectionStateView(model.reviewPricing, loadingLabel: "Getting prices…", retry: { await model.loadReviewPricing() }) { pricing in
                    NewJobPricingPreview(
                        pricing: pricing,
                        applyDiscount: model.applyMemberDiscount,
                        currencyCode: appState.currencyCode
                    )
                }
            }
        }
    }

    private var createArea: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let error = model.createError {
                InlineMessage(text: error, kind: .error)
            }
            AsyncButton(style: .themePrimary) {
                await onCreate()
            } label: {
                Text(model.hasStartedCreating ? "Retry" : "Create job")
            }
            .disabled(model.customer == nil)
        }
    }
}

/// The server's price preview for the chosen services. Clearly an
/// estimate: the job's real totals are computed when it's saved.
struct NewJobPricingPreview: View {
    let pricing: JobPricing
    let applyDiscount: Bool
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(pricing.lines) { line in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(line.name)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.textPrimary)
                        if let note = line.note?.trimmedNonEmpty {
                            Text(note)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.success)
                        }
                    }
                    Spacer(minLength: Theme.Spacing.sm)
                    if let unit = line.unitPriceCents {
                        MoneyText(cents: unit, currencyCode: currencyCode, size: .small)
                    } else {
                        Text("No price")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.danger)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !pricing.unpricedLines.isEmpty {
                InlineMessage(
                    text: "Some services have no price for this vehicle. Go back and remove them, then add them on the job as custom lines.",
                    kind: .error
                )
            }
            if let totals = pricing.totals {
                JobDivider()
                if applyDiscount || totals.discountCents == 0 {
                    JobMoneyRow(label: "Subtotal", cents: totals.subtotalCents, currencyCode: currencyCode)
                    if totals.discountCents > 0 {
                        JobMoneyRow(label: "Member discount", cents: -totals.discountCents, currencyCode: currencyCode)
                    }
                    JobMoneyRow(label: "Tax", cents: totals.taxCents, currencyCode: currencyCode)
                    JobMoneyRow(label: "Estimated total", cents: totals.totalCents, currencyCode: currencyCode, isTotal: true)
                } else {
                    JobMoneyRow(label: "Subtotal", cents: totals.subtotalCents, currencyCode: currencyCode, isTotal: true)
                    Text("Tax is added when the job is saved.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                Text("Estimate from current prices. The job's total is calculated by the server when it's saved.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
