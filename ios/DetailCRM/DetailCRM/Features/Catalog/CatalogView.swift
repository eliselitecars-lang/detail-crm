//
//  CatalogView.swift
//  DetailCRM
//
//  The shop's services, packages, add-ons and products by category, with
//  prices per vehicle category. Everyone reads the catalog; managers and
//  above can make simple edits (name, duration, active, online booking,
//  prices). Creating services, package contents, add-on links and
//  checklists are edited in the web app.
//

import SwiftUI
import DetailCore

struct CatalogView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var state: LoadState<CatalogSnapshot> = .idle
    @State private var kind: CatalogServiceKind = .service
    @State private var search = ""

    var body: some View {
        LoadStateView(state, loadingLabel: "Loading catalog…", retry: { await load() }) { snapshot in
            CatalogList(
                snapshot: snapshot,
                kind: $kind,
                search: search,
                currencyCode: appState.currencyCode,
                canEdit: appState.can(.editCatalog)
            )
        }
        .screenBackground()
        .navigationTitle("Catalog")
        .searchable(text: $search, prompt: "Search services")
        .navigationDestination(for: CatalogItem.self) { item in
            CatalogItemDetailView(itemID: item.id, snapshot: state.value) {
                await load()
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let shopID = appState.shop?.id else {
            state = .failed(AppError.noShopSelected.errorDescription ?? "Choose a shop first.")
            return
        }
        state.beginLoading()
        let result = await LoadState<CatalogSnapshot>.result {
            try await CatalogService.snapshot(shopID: shopID)
        }
        if let message = result.errorMessage, state.value != nil {
            toasts.show(message, style: .error)
        }
        state.apply(result)
    }
}

private struct CatalogList: View {
    let snapshot: CatalogSnapshot
    @Binding var kind: CatalogServiceKind
    let search: String
    let currencyCode: String
    let canEdit: Bool

    var body: some View {
        List {
            Section {
                Picker("Type", selection: $kind) {
                    ForEach(CatalogServiceKind.allCases) { option in
                        Text(option.pluralName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            let groups = filteredGroups
            if groups.isEmpty {
                Section {
                    EmptyStateView(
                        systemImage: kind.systemImage,
                        title: search.trimmedNonEmpty == nil ? "No \(kind.pluralName.lowercased()) yet" : "No matches",
                        message: search.trimmedNonEmpty == nil
                            ? "Add \(kind.pluralName.lowercased()) in the web app's catalog."
                            : "Nothing matches \u{201C}\(search)\u{201D}."
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in
                            NavigationLink(value: item) {
                                CatalogItemRow(item: item, priceRange: snapshot.priceRange(for: item.id), currencyCode: currencyCode)
                            }
                            .themedRow()
                        }
                    }
                }
            }
            if kind == .service && search.trimmedNonEmpty == nil && !snapshot.checklists.isEmpty {
                CatalogChecklistsSection(snapshot: snapshot)
            }
            Section {
                CatalogWebNote(canEdit: canEdit)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var filteredGroups: [CatalogGroup] {
        let groups = snapshot.groups(kind: kind)
        guard let term = search.trimmedNonEmpty else { return groups }
        return groups.compactMap { group in
            let items = group.items.filter { item in
                item.name.localizedCaseInsensitiveContains(term)
                    || (item.description ?? "").localizedCaseInsensitiveContains(term)
            }
            return items.isEmpty ? nil : CatalogGroup(id: group.id, title: group.title, items: items)
        }
    }
}

private struct CatalogItemRow: View {
    let item: CatalogItem
    let priceRange: ClosedRange<Int>?
    let currencyCode: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(item.name)
                    .font(Theme.Typography.bodyEmphasis)
                    .foregroundStyle(item.active ? Theme.textPrimary : Theme.textSecondary)
                HStack(spacing: Theme.Spacing.xs) {
                    Text(ShopClock.durationText(minutes: item.durationMinutes))
                    if item.onlineBookable {
                        Text("· Online booking")
                    }
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                CatalogPriceRangeText(range: priceRange, currencyCode: currencyCode)
                if !item.active {
                    StatusBadge(text: "Inactive", tone: .neutral)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

/// "$120.00" or "$120.00 – $220.00", or "No price".
struct CatalogPriceRangeText: View {
    let range: ClosedRange<Int>?
    let currencyCode: String

    var body: some View {
        if let range {
            if range.lowerBound == range.upperBound {
                MoneyText(cents: range.lowerBound, currencyCode: currencyCode, size: .small)
            } else {
                Text("\(Money.format(cents: range.lowerBound, currencyCode: currencyCode)) – \(Money.format(cents: range.upperBound, currencyCode: currencyCode))")
                    .font(Theme.Typography.moneySmall)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        } else {
            Text("No price")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

/// Read-only checklist templates (edited on the web).
private struct CatalogChecklistsSection: View {
    let snapshot: CatalogSnapshot

    var body: some View {
        Section {
            ForEach(snapshot.checklists) { template in
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(template.name)
                        .font(Theme.Typography.bodyEmphasis)
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail(template))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .themedRow()
            }
        } header: {
            Text("Checklists")
        }
    }

    private func detail(_ template: ChecklistTemplate) -> String {
        var text = "\(template.items.count) item\(template.items.count == 1 ? "" : "s")"
        if let name = snapshot.itemName(template.serviceID) {
            text += " · added automatically for \(name)"
        }
        return text
    }
}

/// Explains what's editable here vs. on the web.
struct CatalogWebNote: View {
    let canEdit: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            InlineMessage(
                text: canEdit
                    ? "On the phone you can rename services and change duration, prices, active and online booking. Create services, set up packages and add-ons, and edit checklists in the web app."
                    : "The catalog is managed by your shop's managers.",
                kind: .info
            )
            if canEdit, let url = ShopSettingsWebLinks.catalog {
                Link(destination: url) {
                    Label("Open the catalog on the web", systemImage: "safari")
                        .font(Theme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(Theme.glacier)
                }
            }
        }
    }
}
