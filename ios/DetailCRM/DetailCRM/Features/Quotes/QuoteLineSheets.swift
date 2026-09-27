//
//  QuoteLineSheets.swift
//  DetailCRM
//
//  Quote builder sheets: edit one line (custom or catalog-priced) and pick
//  catalog services to add (prices come from `price_services`).
//

import SwiftUI
import DetailCore

// MARK: - Line editor

struct QuoteLineEditorSheet: View {
    let line: QuoteDraftLine
    let isNew: Bool
    let currencyCode: String
    let onSave: (QuoteDraftLine) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var details = ""
    @State private var quantityText = "1"
    @State private var priceText = ""
    @State private var discountText = ""
    @State private var taxable = true
    @State private var isOptional = false
    @State private var didSetUp = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .font(Theme.Typography.body)
                        .themedRow()
                    TextField("Description (optional)", text: $details, axis: .vertical)
                        .lineLimit(1...5)
                        .themedRow()
                } header: {
                    Text("Item")
                }
                Section {
                    QuoteLineNumberRow(label: "Quantity", placeholder: "1", text: $quantityText)
                    QuoteLineNumberRow(label: "Unit price", placeholder: "0.00", text: $priceText)
                    QuoteLineNumberRow(label: "Line discount", placeholder: "0.00", text: $discountText)
                } header: {
                    Text("Price")
                } footer: {
                    if line.serviceID != nil {
                        Text("Priced from your catalog; change it here for this quote only.")
                    }
                }
                Section {
                    Toggle("Taxable", isOn: $taxable)
                        .tint(Theme.glacier)
                        .themedRow()
                    Toggle("Optional upsell", isOn: $isOptional)
                        .tint(Theme.glacier)
                        .themedRow()
                } footer: {
                    Text("Optional items aren't in the total until the customer picks them when approving.")
                }
                if let errorText {
                    Section {
                        InlineMessage(text: errorText)
                            .themedRow()
                    }
                }
            }
            .screenBackground()
            .navigationTitle(isNew ? "Add item" : "Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Done") { submit() }
                }
            }
            .onAppear(perform: setUp)
        }
    }

    private func setUp() {
        guard !didSetUp else { return }
        didSetUp = true
        name = line.name
        details = line.lineDescription ?? ""
        quantityText = MoneyQuantityFormat.text(line.quantity)
        priceText = isNew && line.unitPriceCents == 0
            ? ""
            : Money.editableString(cents: line.unitPriceCents, currencyCode: currencyCode)
        discountText = line.discountCents > 0
            ? Money.editableString(cents: line.discountCents, currencyCode: currencyCode)
            : ""
        taxable = line.taxable
        isOptional = line.isOptional
    }

    private func submit() {
        errorText = nil
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 200 else {
            errorText = "Enter a name (up to 200 characters)."
            return
        }
        guard let quantity = MoneyQuantityFormat.parse(quantityText) else {
            errorText = "Enter a quantity greater than 0 (up to 2 decimals)."
            return
        }
        guard let price = Money.parseCents(priceText, currencyCode: currencyCode) else {
            errorText = "Enter the unit price, e.g. 149.00."
            return
        }
        var discount = 0
        if discountText.trimmedNonEmpty != nil {
            guard let parsed = Money.parseCents(discountText, currencyCode: currencyCode) else {
                errorText = "Enter the line discount as an amount, e.g. 10.00."
                return
            }
            discount = parsed
        }
        var updated = line
        updated.name = trimmedName
        updated.lineDescription = details.trimmedNonEmpty
        updated.quantity = quantity
        updated.unitPriceCents = price
        updated.discountCents = discount
        updated.taxable = taxable
        if updated.isOptional != isOptional {
            // A line that becomes optional starts unpicked.
            updated.isSelected = false
        }
        updated.isOptional = isOptional
        if price != line.unitPriceCents {
            // A price typed by staff replaces the catalog note.
            updated.pricingNote = nil
        }
        onSave(updated)
        dismiss()
    }
}

/// "Label ........ [ 12.50 ]" row with a decimal keypad.
private struct QuoteLineNumberRow: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(label)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Theme.Spacing.md)
            TextField(placeholder, text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(Theme.Typography.money)
                .frame(maxWidth: 160)
                .accessibilityLabel(label)
        }
        .themedRow()
    }
}

// MARK: - Catalog picker

struct QuoteServicePickerSheet: View {
    let onAdd: ([QuoteServiceOption]) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var state: LoadState<[QuoteServiceOption]> = .idle
    @State private var search = ""
    @State private var selectedIDs: [UUID] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SearchBar(text: $search, prompt: "Search services")
                    .padding(.horizontal, Theme.Spacing.gutter)
                    .padding(.vertical, Theme.Spacing.sm)
                LoadStateView(state, loadingLabel: "Loading catalog…", retry: { await load() }) { services in
                    QuoteServiceList(
                        services: filtered(services),
                        hasAny: !services.isEmpty,
                        selectedIDs: selectedIDs,
                        onToggle: toggle
                    )
                }
            }
            .screenBackground()
            .navigationTitle("Add from catalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selectedIDs.isEmpty ? "Add" : "Add (\(selectedIDs.count))") {
                        submit()
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
            .task { await load() }
        }
    }

    private func filtered(_ services: [QuoteServiceOption]) -> [QuoteServiceOption] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return services }
        return services.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    private func toggle(_ service: QuoteServiceOption) {
        if let index = selectedIDs.firstIndex(of: service.id) {
            selectedIDs.remove(at: index)
        } else {
            selectedIDs.append(service.id)
        }
    }

    private func submit() {
        guard let services = state.value else { return }
        // Keep the order in which they were picked.
        let picked = selectedIDs.compactMap { id in services.first(where: { $0.id == id }) }
        onAdd(picked)
        dismiss()
    }

    private func load() async {
        guard let shopID = try? appState.requireShopID() else { return }
        state.beginLoading()
        let result = await LoadState<[QuoteServiceOption]>.result {
            try await QuoteService.services(shopID: shopID)
        }
        state.apply(result)
    }
}

private struct QuoteServiceList: View {
    let services: [QuoteServiceOption]
    let hasAny: Bool
    let selectedIDs: [UUID]
    let onToggle: (QuoteServiceOption) -> Void

    var body: some View {
        if services.isEmpty {
            EmptyStateView(
                systemImage: "list.bullet.rectangle",
                title: hasAny ? "No matching services" : "Your catalog is empty",
                message: hasAny
                    ? "Try a different search."
                    : "Add services in Catalog, or add a custom item to this quote."
            )
        } else {
            List {
                ForEach(services) { service in
                    Button {
                        onToggle(service)
                    } label: {
                        QuoteServiceRow(service: service, isSelected: selectedIDs.contains(service.id))
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct QuoteServiceRow: View {
    let service: QuoteServiceOption
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(isSelected ? Theme.glacier : Theme.textTertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(service.name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(service.kindLabel) · \(ShopClock.durationText(minutes: service.durationMinutes))")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
