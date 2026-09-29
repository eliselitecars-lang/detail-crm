//
//  MoneyComponents.swift
//  DetailCRM
//
//  Small building blocks shared by the Quotes, Invoices, Payments and
//  Memberships screens: section cards, amount rows, totals, filter chips,
//  a status timeline and the customer / vehicle pickers.
//

import SwiftUI
import DetailCore

// MARK: - Section card

/// Eyebrow title above a themed card.
struct MoneySectionCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: title)
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                content
            }
            .cardStyle()
        }
    }
}

// MARK: - Amount rows

/// Label on the left, a money amount on the right.
struct MoneyAmountRow: View {
    let label: String
    let cents: Int
    let currencyCode: String
    var emphasis: MoneyText.Emphasis = .normal
    var size: MoneyText.Size = .regular
    var isStrong: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text(label)
                .font(isStrong ? Theme.Typography.bodyEmphasis : Theme.Typography.subheadline)
                .foregroundStyle(isStrong ? Theme.textPrimary : Theme.textSecondary)
            Spacer(minLength: Theme.Spacing.md)
            MoneyText(cents: cents, currencyCode: currencyCode, size: size, emphasis: emphasis)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Subtotal / discount / tax / total, as computed by the server (or a
/// clearly-labelled preview when `caption` says so).
struct MoneyTotalsView: View {
    let subtotalCents: Int
    let discountCents: Int
    let taxCents: Int
    let taxRateBps: Int
    let totalCents: Int
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            MoneyAmountRow(label: "Subtotal", cents: subtotalCents, currencyCode: currencyCode)
            if discountCents > 0 {
                MoneyAmountRow(label: "Discount", cents: -discountCents, currencyCode: currencyCode)
            }
            MoneyAmountRow(label: taxLabel, cents: taxCents, currencyCode: currencyCode)
            Divider().overlay(Theme.border)
            MoneyAmountRow(label: "Total", cents: totalCents, currencyCode: currencyCode, isStrong: true)
        }
    }

    private var taxLabel: String {
        taxRateBps > 0 ? "Tax (\(MoneyPercentFormat.text(basisPoints: taxRateBps)))" : "Tax"
    }
}

// MARK: - Filter chips

struct MoneyFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.buttonCompact)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Theme.onAccent : Theme.textPrimary)
                .padding(.horizontal, Theme.Spacing.md)
                .frame(minHeight: Theme.Size.compactControlHeight)
                .background(
                    Capsule().fill(isSelected ? Theme.glacierSolid : Theme.surfaceMuted)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A search bar over a horizontally scrolling row of chips.
struct MoneyListHeader<Chips: View>: View {
    @Binding var search: String
    let prompt: String
    let chips: Chips

    init(search: Binding<String>, prompt: String, @ViewBuilder chips: () -> Chips) {
        self._search = search
        self.prompt = prompt
        self.chips = chips()
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            SearchBar(text: $search, prompt: prompt)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    chips
                }
                .padding(.vertical, Theme.Spacing.xxs)
            }
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.background)
    }
}

// MARK: - Timeline

/// Last row of a paged money list: how many rows are shown and a button
/// that loads the next (older) page.
struct MoneyLoadMoreRow: View {
    let shownCount: Int
    let noun: String
    let action: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Showing the newest \(shownCount) \(noun).")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
            AsyncButton("Load more", style: .themeSecondaryCompact) {
                await action()
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

struct MoneyTimelineEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let date: Date
    var detail: String? = nil
}

struct MoneyTimelineView: View {
    let entries: [MoneyTimelineEntry]
    let clock: ShopClock

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    Circle()
                        .fill(Theme.glacier)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(entry.title)
                            .font(Theme.Typography.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(clock.dateTimeText(entry.date))
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                        if let detail = entry.detail {
                            Text(detail)
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Text block

/// A titled block of free text (notes, terms), hidden when empty.
struct MoneyTextBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Line row (quotes and invoices)

struct MoneyLineRow: View {
    let name: String
    let detail: String?
    let quantity: Decimal
    let unitPriceCents: Int
    let discountCents: Int
    let totalCents: Int?
    let currencyCode: String
    var badge: String? = nil
    var note: String? = nil
    var noteIsWarning: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(name)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let badge {
                        StatusBadge(text: badge, tone: .info)
                    }
                }
                Text(quantityText)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                if let detail = detail?.trimmedNonEmpty {
                    Text(detail)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note {
                    Text(note)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(noteIsWarning ? Theme.warningInk : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            if let totalCents {
                MoneyText(cents: totalCents, currencyCode: currencyCode)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var quantityText: String {
        var text = "\(MoneyQuantityFormat.text(quantity)) × \(Money.format(cents: unitPriceCents, currencyCode: currencyCode))"
        if discountCents > 0 {
            text += " − \(Money.format(cents: discountCents, currencyCode: currencyCode))"
        }
        return text
    }
}

// MARK: - Customer picker

/// Searchable customer list in its own sheet.
struct QuoteCustomerPickerSheet: View {
    let onPick: (QuoteCustomerRef) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var state: LoadState<[QuoteCustomerRef]> = .idle

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SearchBar(text: $search, prompt: "Name, email or phone")
                    .padding(.horizontal, Theme.Spacing.gutter)
                    .padding(.vertical, Theme.Spacing.sm)
                LoadStateView(state, loadingLabel: "Finding customers…", retry: { await load() }) { customers in
                    QuoteCustomerResults(customers: customers) { customer in
                        onPick(customer)
                        dismiss()
                    }
                }
            }
            .screenBackground()
            .navigationTitle("Choose customer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: search) {
                if !search.isEmpty {
                    try? await Task.sleep(for: .milliseconds(300))
                    if Task.isCancelled { return }
                }
                await load()
            }
        }
    }

    private func load() async {
        guard let shopID = try? appState.requireShopID() else { return }
        state.beginLoading()
        let term = search
        let result = await LoadState<[QuoteCustomerRef]>.result {
            try await QuoteService.searchCustomers(shopID: shopID, term: term)
        }
        state.apply(result)
    }
}

private struct QuoteCustomerResults: View {
    let customers: [QuoteCustomerRef]
    let onPick: (QuoteCustomerRef) -> Void

    var body: some View {
        if customers.isEmpty {
            EmptyStateView(
                systemImage: "person.crop.circle.badge.questionmark",
                title: "No customers found",
                message: "Try a different name, email or phone number. Add new customers from the Customers tab."
            )
        } else {
            List {
                ForEach(customers) { customer in
                    Button {
                        onPick(customer)
                    } label: {
                        QuoteCustomerRow(customer: customer)
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

struct QuoteCustomerRow: View {
    let customer: QuoteCustomerRef

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            AvatarView(name: customer.displayName, size: Theme.Size.avatarSmall)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(customer.displayName)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                if let detail = customer.detailLine {
                    Text(detail)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Picker field

/// A tappable "field" showing the current choice (customer, vehicle, plan).
struct MoneyPickerField: View {
    let label: String
    let value: String?
    let placeholder: String
    var systemImage: String = "chevron.right"
    let action: () -> Void

    var body: some View {
        FormRow(label) {
            Button(action: action) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(value ?? placeholder)
                        .font(Theme.Typography.body)
                        .foregroundStyle(value == nil ? Theme.textTertiary : Theme.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: Theme.Spacing.sm)
                    Image(systemName: systemImage)
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                }
                .inputFieldStyle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label): \(value ?? placeholder)")
        }
    }
}

// MARK: - Tip presets

/// Suggested tip percentages (whole percent) for the collect sheets.
enum MoneyTipPreset: Hashable, Identifiable {
    case none
    case percent(Int)
    case custom

    var id: String {
        switch self {
        case .none: return "none"
        case .percent(let value): return "p\(value)"
        case .custom: return "custom"
        }
    }

    static let standard: [MoneyTipPreset] = [.none, .percent(15), .percent(20), .percent(25), .custom]

    var title: String {
        switch self {
        case .none: return "No tip"
        case .percent(let value): return "\(value)%"
        case .custom: return "Custom"
        }
    }

    /// Requested tip in cents for `amountCents` (the server bounds it).
    func tipCents(amountCents: Int, customCents: Int?) -> Int {
        switch self {
        case .none:
            return 0
        case .percent(let value):
            // Round half up to whole cents.
            return (amountCents * value + 50) / 100
        case .custom:
            return max(0, customCents ?? 0)
        }
    }
}
