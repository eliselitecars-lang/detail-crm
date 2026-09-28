//
//  JobCatalogSelection.swift
//  DetailCRM
//
//  Multi-select catalog list (grouped by category, add-ons offered with the
//  chosen services) with each row's server price for the vehicle. Used by
//  the job's line editor and the New Job flow.
//

import SwiftUI
import DetailCore

struct JobCatalogSelectionList: View {
    let catalog: JobCatalog
    let pricing: JobPricedCatalog
    @Binding var selected: Set<UUID>
    let currencyCode: String

    private var offeredAddons: [JobCatalogEntry] {
        let primaryIDs = Set(catalog.primaryEntries.map(\.id)).intersection(selected)
        return catalog.addonsOffered(with: primaryIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            if catalog.primaryEntries.isEmpty {
                JobEmptyLine(text: "The catalog has no active services yet.", systemImage: "list.bullet.rectangle")
            }
            ForEach(catalog.groupedPrimaryEntries) { group in
                groupCard(title: group.name, entries: group.entries)
            }
            if !offeredAddons.isEmpty {
                groupCard(title: "Add-ons", entries: offeredAddons)
            }
        }
    }

    private func groupCard(title: String, entries: [JobCatalogEntry]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: title)
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    JobCatalogRow(
                        entry: entry,
                        priced: pricing.price(for: entry.id),
                        isSelected: selected.contains(entry.id),
                        currencyCode: currencyCode
                    ) {
                        toggle(entry)
                    }
                    if entry.id != entries.last?.id {
                        JobDivider()
                    }
                }
            }
            .cardStyle(padding: Theme.Spacing.sm)
        }
    }

    private func toggle(_ entry: JobCatalogEntry) {
        if selected.contains(entry.id) {
            selected.remove(entry.id)
            // Drop add-ons no longer offered with what's left.
            if entry.kind != .addon {
                let primaryIDs = Set(catalog.primaryEntries.map(\.id)).intersection(selected)
                let offered = Set(catalog.addonsOffered(with: primaryIDs).map(\.id))
                let addonIDs = Set(catalog.addons.map(\.id))
                selected = selected.filter { !addonIDs.contains($0) || offered.contains($0) }
            }
        } else {
            selected.insert(entry.id)
        }
    }
}

struct JobCatalogRow: View {
    let entry: JobCatalogEntry
    let priced: PricedService?
    let isSelected: Bool
    let currencyCode: String
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(Theme.Typography.title.weight(.regular))
                    .foregroundStyle(isSelected ? Theme.glacier : Theme.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(entry.name)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(priced?.membershipIncluded == true ? Theme.successInk : Theme.textSecondary)
                }
                Spacer(minLength: Theme.Spacing.sm)
                priceView
            }
            .padding(.vertical, Theme.Spacing.sm)
            .padding(.horizontal, Theme.Spacing.xs)
            .frame(minHeight: Theme.Size.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var priceView: some View {
        if let unit = priced?.unitPriceCents {
            MoneyText(cents: unit, currencyCode: currencyCode, size: .small)
        } else if priced != nil {
            Text("No price")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var detail: String {
        if let note = priced?.note?.trimmedNonEmpty { return note }
        var parts: [String] = [entry.kind.displayName]
        let minutes = priced?.durationMinutes ?? entry.durationMinutes
        if minutes > 0 { parts.append(ShopClock.durationText(minutes: minutes)) }
        return parts.joined(separator: " · ")
    }
}

/// Manager+: add catalog services to an existing job.
struct JobCatalogPickerView: View {
    let model: JobDetailModel
    /// Called after lines were added, with the member discount the server
    /// suggests (basis points, 0 for none).
    let onAdded: (Int) -> Void

    @Environment(AppState.self) private var appState
    @State private var state: LoadState<JobCatalogPickerData> = .idle
    @State private var selected: Set<UUID> = []
    @State private var errorMessage: String?

    var body: some View {
        LoadStateView(state, loadingLabel: "Pricing the catalog…", retry: { await load() }) { data in
            content(data)
        }
        .screenBackground()
        .navigationTitle("Add services")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func content(_ data: JobCatalogPickerData) -> AnyView {
        AnyView(
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    if let vehicleNote = data.vehicleNote {
                        InlineMessage(text: vehicleNote, kind: .info)
                    }
                    if !data.pricing.memberships.isEmpty {
                        InlineMessage(
                            text: "Member: " + data.pricing.memberships.map(\.planName).joined(separator: ", "),
                            kind: .success
                        )
                    }
                    if let errorMessage {
                        InlineMessage(text: errorMessage, kind: .error)
                    }
                    JobCatalogSelectionList(
                        catalog: data.catalog,
                        pricing: data.pricing,
                        selected: $selected,
                        currencyCode: appState.currencyCode
                    )
                    AsyncButton(style: .themePrimary) {
                        await add(data)
                    } label: {
                        Text(selected.isEmpty ? "Choose services" : "Add \(selected.count) to job")
                    }
                    .disabled(selected.isEmpty)
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.vertical, Theme.Spacing.lg)
            }
        )
    }

    private func load() async {
        guard let shopID = try? appState.requireShopID(), let snapshot = model.snapshot else {
            state = .failed("The job isn't loaded yet.")
            return
        }
        state.beginLoading()
        let job = snapshot.job
        let categoryID = snapshot.vehicle?.categoryID
        let result = await LoadState<JobCatalogPickerData>.result {
            let catalog = try await PricingService.catalog(shopID: shopID)
            let pricing = try await PricingService.priceCatalog(
                shopID: shopID,
                catalog: catalog,
                customerID: job.customerID,
                vehicleCategoryID: nil,
                vehicleID: job.vehicleID
            )
            let note: String? = job.vehicleID == nil
                ? "No vehicle on this job, so base prices are shown."
                : (categoryID == nil ? "The vehicle has no size category, so base prices are shown." : nil)
            return JobCatalogPickerData(catalog: catalog, pricing: pricing, vehicleNote: note)
        }
        state.apply(result)
    }

    private func add(_ data: JobCatalogPickerData) async {
        errorMessage = nil
        // Catalog order: services first, then add-ons.
        let ordered = (data.catalog.primaryEntries + data.catalog.addons)
            .map(\.id)
            .filter { selected.contains($0) }
        do {
            let drafts = try data.pricing.lineDrafts(
                for: ordered,
                vehicleID: model.job?.vehicleID,
                firstSort: model.nextLineSort
            )
            try await model.addLines(drafts)
            onAdded(data.pricing.suggestedDiscountBps)
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

/// Catalog + prices for the picker.
struct JobCatalogPickerData {
    var catalog: JobCatalog
    var pricing: JobPricedCatalog
    var vehicleNote: String?
}
