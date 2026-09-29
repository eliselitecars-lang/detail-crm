//
//  PaymentApplySheet.swift
//  DetailCRM
//
//  Manager+: puts an unapplied payment (money kept on the customer that
//  pays no invoice, job or membership) on one of the same customer's open
//  invoices, so they don't pay it twice (the web's ApplyPaymentDialog).
//  `apply_payment_to_invoice` moves the whole payment row (its tip and
//  refunds stay with it), refuses a target it would overpay, and waits for
//  the invoice's open card pay pages (PaymentService releases those and
//  tries again). Tips never count toward an invoice.
//

import SwiftUI
import DetailCore

struct PaymentApplySheet: View {
    let payment: Payment
    let customerName: String
    let onFinished: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var invoices: LoadState<[PaymentApplicableInvoice]> = .idle
    @State private var chosenID: UUID?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            LoadStateView(invoices, loadingLabel: "Loading invoices…", retry: { await load() }) { list in
                content(list)
            }
            .screenBackground()
            .navigationTitle("Apply to an invoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private var currencyCode: String { appState.currencyCode }

    private var amount: Int { payment.applicableCents }

    @ViewBuilder
    private func content(_ list: [PaymentApplicableInvoice]) -> some View {
        if list.isEmpty {
            EmptyStateView(
                systemImage: "doc.plaintext",
                title: "No open invoices for \(customerName)",
                message: "Create or send an invoice for them first, or refund the payment."
            )
        } else {
            FormScreen {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(customerName)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(payment.methodLabel) · \(appState.clock.shortDayText(payment.displayDate))")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    MoneyAmountRow(label: "Amount to apply", cents: amount, currencyCode: currencyCode, isStrong: true)
                    Text("Tips never count toward an invoice.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                .cardStyle()
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Invoice")
                        .font(Theme.Typography.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    ForEach(list) { invoice in
                        PaymentApplyInvoiceRow(
                            invoice: invoice,
                            isChosen: chosenID == invoice.id,
                            fits: invoice.balanceCents >= amount,
                            currencyCode: currencyCode
                        ) {
                            chosenID = invoice.id
                            errorText = nil
                        }
                    }
                }
                if let chosen = list.first(where: { $0.id == chosenID }), chosen.balanceCents < amount {
                    InlineMessage(text: tooSmallText(chosen))
                }
                if let errorText {
                    InlineMessage(text: errorText)
                }
                AsyncButton(style: .themeMoney) {
                    await apply(list)
                } label: {
                    Text("Apply \(Money.format(cents: amount, currencyCode: currencyCode))")
                }
                .disabled(!canSubmit(list))
            }
        }
    }

    private func canSubmit(_ list: [PaymentApplicableInvoice]) -> Bool {
        guard let chosen = list.first(where: { $0.id == chosenID }) else { return false }
        return amount > 0 && chosen.balanceCents >= amount
    }

    private func tooSmallText(_ invoice: PaymentApplicableInvoice) -> String {
        "\(invoice.title) has \(Money.format(cents: invoice.balanceCents, currencyCode: currencyCode)) due, less than this payment. Choose another invoice or refund the payment."
    }

    private func load() async {
        guard let shopID = try? appState.requireShopID() else { return }
        invoices.beginLoading()
        let customerID = payment.customerID
        let result = await LoadState<[PaymentApplicableInvoice]>.result {
            try await PaymentService.applicableInvoices(shopID: shopID, customerID: customerID)
        }
        invoices.apply(result)
        // Preselect the only invoice that fits.
        if chosenID == nil, let list = invoices.value {
            let fitting = list.filter { $0.balanceCents >= amount }
            if fitting.count == 1 { chosenID = fitting.first?.id }
        }
    }

    private func apply(_ list: [PaymentApplicableInvoice]) async {
        errorText = nil
        guard let chosen = list.first(where: { $0.id == chosenID }) else {
            errorText = "Choose an invoice."
            return
        }
        do {
            let shopID = try appState.requireShopID()
            _ = try await PaymentService.applyToInvoice(shopID: shopID, paymentID: payment.id, invoiceID: chosen.id)
            await onFinished()
            toasts.show("\(Money.format(cents: amount, currencyCode: currencyCode)) applied to \(chosen.title.lowercased())")
            dismiss()
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }
}

/// One selectable invoice with its balance.
private struct PaymentApplyInvoiceRow: View {
    let invoice: PaymentApplicableInvoice
    let isChosen: Bool
    let fits: Bool
    let currencyCode: String
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChosen ? Theme.glacierInk : Theme.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(invoice.title)
                        .font(Theme.Typography.bodyEmphasis)
                        .foregroundStyle(Theme.textPrimary)
                    Text(fits ? "\(Money.format(cents: invoice.balanceCents, currencyCode: currencyCode)) due" : "\(Money.format(cents: invoice.balanceCents, currencyCode: currencyCode)) due · less than this payment")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(fits ? Theme.textSecondary : Theme.warningInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.sm)
                StatusBadge(invoice.status)
            }
            .padding(Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isChosen ? Theme.fill(for: .info) : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .stroke(isChosen ? Theme.glacier : Theme.border, lineWidth: Theme.Size.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? [.isSelected] : [])
    }
}
