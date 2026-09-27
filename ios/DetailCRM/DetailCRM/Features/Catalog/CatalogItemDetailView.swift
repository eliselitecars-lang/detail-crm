//
//  CatalogItemDetailView.swift
//  DetailCRM
//
//  One catalog item: details, prices per vehicle category (base price =
//  no category) and, for managers and above, two simple editors — the
//  item's basics and its prices. Prices are entered by staff and stored
//  as integer cents; the server prices jobs from these rows.
//

import SwiftUI
import DetailCore

struct CatalogItemDetailView: View {
    let itemID: UUID
    let onChanged: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var state: LoadState<CatalogSnapshot>
    @State private var editingBasics = false
    @State private var editingPrices = false

    init(itemID: UUID, snapshot: CatalogSnapshot?, onChanged: @escaping () async -> Void) {
        self.itemID = itemID
        self.onChanged = onChanged
        if let snapshot {
            _state = State(initialValue: .loaded(snapshot))
        } else {
            _state = State(initialValue: .idle)
        }
    }

    var body: some View {
        LoadStateView(state, retry: { await load() }) { snapshot in
            if let item = snapshot.items.first(where: { $0.id == itemID }) {
                CatalogItemDetailList(
                    item: item,
                    snapshot: snapshot,
                    currencyCode: appState.currencyCode,
                    canEdit: appState.can(.editCatalog),
                    editBasics: { editingBasics = true },
                    editPrices: { editingPrices = true }
                )
                .sheet(isPresented: $editingBasics) {
                    CatalogItemEditSheet(item: item) {
                        await refresh()
                    }
                }
                .sheet(isPresented: $editingPrices) {
                    CatalogPriceEditSheet(item: item, snapshot: snapshot, currencyCode: appState.currencyCode) {
                        await refresh()
                    }
                }
            } else {
                EmptyStateView(
                    systemImage: "questionmark.folder",
                    title: "Not found",
                    message: "This item was removed from the catalog."
                )
            }
        }
        .screenBackground()
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if state.value == nil { await load() }
        }
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

    private func refresh() async {
        await load()
        await onChanged()
    }
}

private struct CatalogItemDetailList: View {
    let item: CatalogItem
    let snapshot: CatalogSnapshot
    let currencyCode: String
    let canEdit: Bool
    let editBasics: () -> Void
    let editPrices: () -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(item.name)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: Theme.Spacing.xs) {
                        StatusBadge(text: item.kind.displayName, tone: .info)
                        StatusBadge(text: item.active ? "Active" : "Inactive", tone: item.active ? .success : .neutral)
                        if item.onlineBookable {
                            StatusBadge(text: "Online booking", tone: .info)
                        }
                    }
                    if let description = item.description?.trimmedNonEmpty {
                        Text(description)
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, Theme.Spacing.xs)
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
                .themedRow()
            }
            Section {
                InfoRow(label: "Category", value: snapshot.categoryName(item.categoryID) ?? "Uncategorized")
                    .themedRow()
                InfoRow(label: "Duration", value: ShopClock.durationText(minutes: item.durationMinutes))
                    .themedRow()
                InfoRow(label: "Taxable", value: item.taxable ? "Yes" : "No")
                    .themedRow()
                if canEdit {
                    Button("Edit details") { editBasics() }
                        .foregroundStyle(Theme.glacier)
                        .themedRow()
                }
            } header: {
                Text("Details")
            }
            CatalogPricesSection(item: item, snapshot: snapshot, currencyCode: currencyCode, canEdit: canEdit, editPrices: editPrices)
            Section {
                CatalogWebNote(canEdit: canEdit)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct CatalogPricesSection: View {
    let item: CatalogItem
    let snapshot: CatalogSnapshot
    let currencyCode: String
    let canEdit: Bool
    let editPrices: () -> Void

    var body: some View {
        Section {
            priceRow(title: "Base price", price: snapshot.basePrice(for: item.id))
            ForEach(snapshot.sortedVehicleCategories) { category in
                priceRow(title: category.name, price: snapshot.price(for: item.id, vehicleCategoryID: category.id))
            }
            if canEdit {
                Button("Edit prices") { editPrices() }
                    .foregroundStyle(Theme.glacier)
                    .themedRow()
            }
        } header: {
            Text("Prices")
        } footer: {
            Text("A vehicle category without its own price uses the base price.")
        }
    }

    private func priceRow(title: String, price: ServicePrice?) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Theme.Spacing.sm)
            if let price {
                VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                    MoneyText(cents: price.priceCents, currencyCode: currencyCode)
                    if let minutes = price.durationMinutes {
                        Text(ShopClock.durationText(minutes: minutes))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            } else {
                Text("Not set")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .themedRow()
    }
}

/// Manager sheet: name, duration, active, online bookable.
private struct CatalogItemEditSheet: View {
    let item: CatalogItem
    let onSaved: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var durationMinutes: Int
    @State private var active: Bool
    @State private var onlineBookable: Bool
    @State private var errorMessage: String?

    init(item: CatalogItem, onSaved: @escaping () async -> Void) {
        self.item = item
        self.onSaved = onSaved
        _name = State(initialValue: item.name)
        _durationMinutes = State(initialValue: item.durationMinutes)
        _active = State(initialValue: item.active)
        _onlineBookable = State(initialValue: item.onlineBookable)
    }

    private var nameProblem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a name." }
        if trimmed.count > 120 { return "Use 120 characters or fewer." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    if let nameProblem {
                        InlineMessage(text: nameProblem, kind: .error)
                    }
                } header: {
                    Text("Name")
                }
                Section {
                    Stepper(value: $durationMinutes, in: 0...1440, step: 15) {
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text(ShopClock.durationText(minutes: durationMinutes))
                                .foregroundStyle(Theme.textSecondary)
                                .monospacedDigit()
                        }
                    }
                    .accessibilityValue(ShopClock.durationText(minutes: durationMinutes))
                } header: {
                    Text("Time")
                } footer: {
                    Text("Used to block the calendar when this is booked.")
                }
                Section {
                    Toggle("Active", isOn: $active)
                    Toggle("Bookable online", isOn: $onlineBookable)
                } footer: {
                    Text("Inactive items can't be added to new jobs. Online items appear on your booking page when it's turned on.")
                }
                if let errorMessage {
                    Section {
                        InlineMessage(text: errorMessage, kind: .error)
                    }
                }
            }
            .screenBackground()
            .navigationTitle("Edit \(item.kind.displayName.lowercased())")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    CatalogSaveButton(disabled: nameProblem != nil) {
                        await save()
                    }
                }
            }
        }
    }

    private func save() async {
        errorMessage = nil
        guard nameProblem == nil else { return }
        do {
            let shopID = try appState.requireShopID()
            let update = CatalogItemUpdate(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                durationMinutes: durationMinutes,
                active: active,
                onlineBookable: onlineBookable
            )
            _ = try await CatalogService.updateItem(shopID: shopID, itemID: item.id, update: update)
            toasts.show("Saved.")
            await onSaved()
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

/// Toolbar "Save" that shows a spinner while running.
struct CatalogSaveButton: View {
    let disabled: Bool
    let action: () async -> Void
    @State private var running = false

    var body: some View {
        Button {
            guard !running else { return }
            running = true
            Task { @MainActor in
                await action()
                running = false
            }
        } label: {
            ZStack {
                Text("Save").opacity(running ? 0 : 1)
                ProgressView().opacity(running ? 1 : 0)
            }
        }
        .disabled(disabled || running)
    }
}

/// Manager sheet: base price + one price per vehicle category.
private struct CatalogPriceEditSheet: View {
    let item: CatalogItem
    let snapshot: CatalogSnapshot
    let currencyCode: String
    let onSaved: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    /// Text per cell; key "base" for the base price, else the category id.
    @State private var texts: [String: String]
    @State private var errorMessage: String?

    init(item: CatalogItem, snapshot: CatalogSnapshot, currencyCode: String, onSaved: @escaping () async -> Void) {
        self.item = item
        self.snapshot = snapshot
        self.currencyCode = currencyCode
        self.onSaved = onSaved
        var initial: [String: String] = [:]
        for price in snapshot.prices(for: item.id) {
            let key = price.vehicleCategoryID?.uuidString ?? "base"
            initial[key] = Money.editableString(cents: price.priceCents, currencyCode: currencyCode)
        }
        _texts = State(initialValue: initial)
    }

    private var cells: [CatalogPriceCell] {
        var result = [CatalogPriceCell(id: "base", title: "Base price", categoryID: nil)]
        for category in snapshot.sortedVehicleCategories {
            result.append(CatalogPriceCell(id: category.id.uuidString, title: category.name, categoryID: category.id))
        }
        return result
    }

    private var invalidKeys: [String] {
        cells.compactMap { cell in
            guard let text = texts[cell.id]?.trimmedNonEmpty else { return nil }
            return Money.parseCents(text, currencyCode: currencyCode) == nil ? cell.id : nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(cells) { cell in
                        CatalogPriceField(
                            title: cell.title,
                            text: binding(for: cell.id),
                            invalid: invalidKeys.contains(cell.id)
                        )
                    }
                } header: {
                    Text(item.name)
                } footer: {
                    Text("Leave a category empty to use the base price. Clearing a price removes it.")
                }
                if let errorMessage {
                    Section {
                        InlineMessage(text: errorMessage, kind: .error)
                    }
                }
            }
            .screenBackground()
            .navigationTitle("Edit prices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    CatalogSaveButton(disabled: !invalidKeys.isEmpty) {
                        await save()
                    }
                }
            }
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { texts[key] ?? "" },
            set: { texts[key] = $0 }
        )
    }

    private func save() async {
        errorMessage = nil
        guard invalidKeys.isEmpty else { return }
        var edited: [(vehicleCategoryID: UUID?, priceCents: Int?)] = []
        for cell in cells {
            if let text = texts[cell.id]?.trimmedNonEmpty {
                edited.append((vehicleCategoryID: cell.categoryID, priceCents: Money.parseCents(text, currencyCode: currencyCode)))
            } else {
                edited.append((vehicleCategoryID: cell.categoryID, priceCents: nil))
            }
        }
        let changes = CatalogPriceChange.changes(existing: snapshot.prices(for: item.id), edited: edited)
        guard !changes.isEmpty else {
            dismiss()
            return
        }
        do {
            let shopID = try appState.requireShopID()
            try await CatalogService.applyPriceChanges(shopID: shopID, serviceID: item.id, changes: changes)
            toasts.show("Prices saved.")
            await onSaved()
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
            await onSaved()
        }
    }
}

/// One editable price cell ("base" or a vehicle category id).
struct CatalogPriceCell: Identifiable, Hashable {
    let id: String
    let title: String
    let categoryID: UUID?
}

private struct CatalogPriceField: View {
    let title: String
    @Binding var text: String
    let invalid: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(title)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Theme.Spacing.sm)
                TextField("Not set", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(Theme.Typography.money)
                    .frame(maxWidth: 140)
                    .accessibilityLabel("\(title) price")
            }
            if invalid {
                InlineMessage(text: "Enter an amount like 149.99.", kind: .error)
            }
        }
    }
}
