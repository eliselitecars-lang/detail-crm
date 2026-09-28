//
//  MoneyGiftCardRedeemSheet.swift
//  DetailCRM
//
//  Pay an invoice with a gift card or store credit (P-13). A gift card is
//  found by its code (checked first so staff see the balance); store credit
//  the customer owns (referral rewards, refunds) is picked from a list, no
//  code needed. The server applies at most the card balance and the invoice
//  balance and records a "Gift card" payment. Wrong codes are counted — too
//  many in an hour and lookups pause for a while.
//

import SwiftUI
import DetailCore

struct MoneyGiftCardRedeemSheet: View {
    let invoice: Invoice
    /// Store credit can be listed (owners, admins and managers).
    let canUseStoreCredit: Bool
    /// Payments the server still counts as on their way (a card attempt
    /// or a clearing bank / pay-later payment, `Payment.inFlightCents`): the
    /// server applies at most the balance less these.
    var inFlightCents: Int = 0
    let onFinished: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    /// Gift card code vs the customer's store credit.
    enum Mode: String, CaseIterable, Identifiable {
        case giftCard
        case storeCredit

        var id: String { rawValue }

        var title: String {
            switch self {
            case .giftCard: return "Gift card"
            case .storeCredit: return "Store credit"
            }
        }
    }

    @State private var mode: Mode = .giftCard
    @State private var code = ""
    @State private var card: MoneyGiftCard?
    /// The code `card` was found with (a new code needs a new check).
    @State private var checkedCode = ""
    @State private var credits: LoadState<[MoneyGiftCard.Credit]> = .idle
    @State private var creditID: UUID?
    @State private var amountText = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            FormScreen {
                header
                if canUseStoreCredit {
                    Picker("Pay with", selection: $mode) {
                        ForEach(Mode.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                switch mode {
                case .giftCard:
                    giftCardContent
                case .storeCredit:
                    storeCreditContent
                }
                if let errorText {
                    InlineMessage(text: errorText)
                }
            }
            .navigationTitle("Gift card or credit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: mode) {
                errorText = nil
                amountText = ""
                if mode == .storeCredit, credits.value == nil {
                    Task { await loadCredits() }
                }
            }
        }
    }

    private var currencyCode: String { appState.currencyCode }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(invoice.title)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: Theme.Spacing.xs) {
                Text("Balance due")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                MoneyText(cents: max(invoice.balanceCents, 0), currencyCode: currencyCode, emphasis: .attention)
            }
            Text("Gift cards and store credit pay the invoice like any other payment; they never discount it.")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if inFlightCents > 0 {
                InlineMessage(
                    text: payableCents > 0
                        ? "\(Money.format(cents: inFlightCents, currencyCode: currencyCode)) is still being processed, so at most \(Money.format(cents: payableCents, currencyCode: currencyCode)) can be applied now."
                        : "\(Money.format(cents: inFlightCents, currencyCode: currencyCode)) is still being processed, which covers the balance. Nothing can be applied until it finishes.",
                    kind: .info
                )
            }
        }
    }

    /// What the invoice can still take now: the balance less payments on
    /// their way (the server's cap).
    private var payableCents: Int {
        max(0, invoice.balanceCents - max(0, inFlightCents))
    }

    // MARK: Gift card

    @ViewBuilder
    private var giftCardContent: some View {
        FormRow("Gift card code", hint: "Letters and numbers, e.g. ABCD-EFGH-JKMN-PQRS. Dashes and spaces are optional.") {
            TextField("Code", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(Theme.Typography.money)
                .inputFieldStyle()
                .onChange(of: code) {
                    if MoneyGiftCard.normalizedCode(code) != checkedCode {
                        card = nil
                    }
                }
        }
        if let card {
            cardSummary(card)
            if card.isRedeemable, payableCents > 0 {
                amountField(maxCents: card.balanceCents)
                AsyncButton(style: .themeMoney) {
                    await redeemGiftCard()
                } label: {
                    Label(applyTitle(maxCents: card.balanceCents), systemImage: "giftcard")
                }
            }
        } else {
            AsyncButton("Check balance", style: .themeSecondary) {
                await lookUp()
            }
            .disabled(!MoneyGiftCard.isPlausibleCode(code))
        }
    }

    private func cardSummary(_ card: MoneyGiftCard) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Label(card.label, systemImage: "giftcard")
                    .font(Theme.Typography.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Theme.Spacing.sm)
                MoneyText(cents: card.balanceCents, currencyCode: currencyCode)
            }
            if let expires = card.expiresAt, card.status != "expired" {
                Text("Expires \(appState.clock.shortDayText(expires))")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let problem = card.problem {
                InlineMessage(text: problem)
            }
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }

    // MARK: Store credit

    @ViewBuilder
    private var storeCreditContent: some View {
        switch credits {
        case .idle, .loading:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView().tint(Theme.glacier)
                Text("Looking for store credit…")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                InlineMessage(text: message)
                AsyncButton("Try again", style: .themeSecondaryCompact) {
                    await loadCredits()
                }
            }
        case .loaded(let list):
            if list.isEmpty {
                EmptyStateView(
                    systemImage: "creditcard.and.123",
                    title: "No store credit",
                    message: "This customer has no store credit to use. Referral rewards and credited refunds show up here."
                )
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(list) { credit in
                        creditRow(credit)
                    }
                }
                if let selected = list.first(where: { $0.id == creditID }), payableCents > 0 {
                    amountField(maxCents: selected.balanceCents)
                    AsyncButton(style: .themeMoney) {
                        await redeemCredit(selected)
                    } label: {
                        Label(applyTitle(maxCents: selected.balanceCents), systemImage: "creditcard.and.123")
                    }
                }
            }
        }
    }

    private func creditRow(_ credit: MoneyGiftCard.Credit) -> some View {
        let isSelected = credit.id == creditID
        return Button {
            creditID = credit.id
            amountText = Money.editableString(cents: defaultAmount(maxCents: credit.balanceCents), currencyCode: currencyCode)
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Theme.glacier : Theme.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Store credit …\(credit.codeLast4)")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                    Text(creditDetail(credit))
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: Theme.Spacing.sm)
                MoneyText(cents: credit.balanceCents, currencyCode: currencyCode, size: .small)
            }
            .padding(Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.surfaceMuted)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(isSelected ? Theme.glacier : Theme.border, lineWidth: Theme.Size.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func creditDetail(_ credit: MoneyGiftCard.Credit) -> String {
        var parts = [credit.sourceText]
        if let expires = credit.expiresAt {
            parts.append("expires \(appState.clock.shortDayText(expires))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Amount

    private func amountField(maxCents: Int) -> some View {
        ThemedTextField(
            label: "Amount to apply",
            placeholder: "0.00",
            text: $amountText,
            kind: .money,
            hint: inFlightCents > 0
                ? "Up to \(Money.format(cents: defaultAmount(maxCents: maxCents), currencyCode: currencyCode)) (the smaller of what can be applied now and what's on the card)."
                : "Up to \(Money.format(cents: defaultAmount(maxCents: maxCents), currencyCode: currencyCode)) (the smaller of the balance due and what's on the card)."
        )
    }

    /// As much as both the card and the invoice allow (the server's limit:
    /// the balance less payments still in flight).
    private func defaultAmount(maxCents: Int) -> Int {
        max(0, min(maxCents, payableCents))
    }

    private func applyTitle(maxCents: Int) -> String {
        let cents = Money.parseCents(amountText, currencyCode: currencyCode) ?? defaultAmount(maxCents: maxCents)
        return "Apply \(Money.format(cents: cents, currencyCode: currencyCode))"
    }

    /// The typed amount, checked against the card and the balance; nil
    /// (with `errorText` set) when it isn't usable.
    private func validatedAmount(maxCents: Int) -> Int? {
        let limit = defaultAmount(maxCents: maxCents)
        guard let amount = Money.parseCents(amountText, currencyCode: currencyCode), amount > 0 else {
            errorText = "Enter the amount to apply."
            return nil
        }
        guard amount <= limit else {
            errorText = "You can apply at most \(Money.format(cents: limit, currencyCode: currencyCode))."
            return nil
        }
        return amount
    }

    // MARK: Actions

    private func lookUp() async {
        errorText = nil
        do {
            let shopID = try appState.requireShopID()
            let normalized = MoneyGiftCard.normalizedCode(code)
            guard let found = try await MoneyGiftCardService.lookup(shopID: shopID, code: normalized) else {
                errorText = "No gift card has that code. Check it and try again."
                return
            }
            if found.isStoreCredit && !canUseStoreCredit {
                errorText = "That code is store credit. Ask a manager to apply it."
                return
            }
            checkedCode = normalized
            card = found
            amountText = Money.editableString(cents: defaultAmount(maxCents: found.balanceCents), currencyCode: currencyCode)
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }

    private func redeemGiftCard() async {
        errorText = nil
        guard let card, let amount = validatedAmount(maxCents: card.balanceCents) else { return }
        do {
            let applied = try await MoneyGiftCardService.redeem(invoiceID: invoice.id, code: checkedCode, amountCents: amount)
            await finish(applied: applied, source: card.label)
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }

    private func loadCredits() async {
        credits.beginLoading()
        let customerID = invoice.customerID
        guard let shopID = try? appState.requireShopID() else { return }
        let result = await LoadState<[MoneyGiftCard.Credit]>.result {
            try await MoneyGiftCardService.credits(shopID: shopID, customerID: customerID)
        }
        credits.apply(result)
        if let first = credits.value?.first, creditID == nil {
            creditID = first.id
            amountText = Money.editableString(cents: defaultAmount(maxCents: first.balanceCents), currencyCode: currencyCode)
        }
    }

    private func redeemCredit(_ credit: MoneyGiftCard.Credit) async {
        errorText = nil
        guard let amount = validatedAmount(maxCents: credit.balanceCents) else { return }
        do {
            let applied = try await MoneyGiftCardService.redeemCredit(
                invoiceID: invoice.id,
                giftCardID: credit.id,
                amountCents: amount
            )
            await finish(applied: applied, source: "store credit …\(credit.codeLast4)")
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }

    private func finish(applied: Int, source: String) async {
        await onFinished()
        toasts.show("Applied \(Money.format(cents: applied, currencyCode: currencyCode)) from \(source)")
        dismiss()
    }
}
