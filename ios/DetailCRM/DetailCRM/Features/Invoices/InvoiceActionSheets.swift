//
//  InvoiceActionSheets.swift
//  DetailCRM
//
//  Invoice sheets: record a cash/check/other payment, charge a saved card,
//  send the invoice (mark sent + invoice_sent message), void, and refund a
//  payment. Every amount is validated again by the server.
//

import SwiftUI
import DetailCore

// MARK: - Manual payment

struct InvoiceManualPaymentSheet: View {
    let invoice: Invoice
    /// An unfinished card attempt is pending; it's cancelled first.
    let hasOpenCardAttempt: Bool
    /// Bank / pay-later money still clearing (counts against the balance).
    var processingCents: Int = 0
    let onFinished: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var method: PaymentMethod = .cash
    @State private var amountText = ""
    @State private var tipText = ""
    @State private var note = ""
    @State private var didSetUp = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            FormScreen {
                FormRow("Method") {
                    Picker("Method", selection: $method) {
                        ForEach(PaymentMethod.manualMethods, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .inputFieldStyle()
                }
                ThemedTextField(
                    label: "Amount",
                    placeholder: "0.00",
                    text: $amountText,
                    kind: .money,
                    hint: "Balance due: \(Money.format(cents: invoice.balanceCents, currencyCode: currencyCode))"
                )
                ThemedTextField(
                    label: "Tip (optional)",
                    placeholder: "0.00",
                    text: $tipText,
                    kind: .money,
                    hint: "Tips never change the balance."
                )
                FormRow("Note (optional)") {
                    TextField("Check number, reference…", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                        .inputFieldStyle()
                }
                if hasOpenCardAttempt {
                    InlineMessage(
                        text: "A card payment was started on this invoice but not finished. Recording this payment cancels it.",
                        kind: .info
                    )
                }
                if processingCents > 0 {
                    InlineMessage(
                        text: "\(Money.format(cents: processingCents, currencyCode: currencyCode)) is still clearing by bank or pay-later payment, so at most \(Money.format(cents: max(0, invoice.balanceCents - processingCents), currencyCode: currencyCode)) can be recorded now.",
                        kind: .info
                    )
                }
                if let errorText {
                    InlineMessage(text: errorText)
                }
                AsyncButton("Record payment", style: .themeMoney) {
                    await submit()
                }
            }
            .navigationTitle("Record payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if !didSetUp {
                    didSetUp = true
                    amountText = Money.editableString(cents: max(invoice.balanceCents, 0), currencyCode: currencyCode)
                }
            }
        }
    }

    private var currencyCode: String { appState.currencyCode }

    private func submit() async {
        errorText = nil
        guard let amount = Money.parseCents(amountText, currencyCode: currencyCode), amount > 0 else {
            errorText = "Enter the amount received."
            return
        }
        guard amount <= invoice.balanceCents else {
            errorText = "The amount can't be more than the balance due. Record extra as a tip."
            return
        }
        var tip = 0
        if tipText.trimmedNonEmpty != nil {
            guard let parsed = Money.parseCents(tipText, currencyCode: currencyCode) else {
                errorText = "Enter the tip as an amount, e.g. 10.00."
                return
            }
            tip = parsed
        }
        do {
            let shopID = try appState.requireShopID()
            if hasOpenCardAttempt {
                // The pending card attempt counts against the balance until
                // released (record_manual_payment would refuse the amount).
                try await PaymentService.cancelOpenPayments(shopID: shopID, invoiceID: invoice.id)
            }
            // An open pay link / deposit page (not shown here) is released
            // and the payment tried once more (0109 checkout_open).
            _ = try await PaymentService.releasingOpenCheckouts(shopID: shopID, invoiceID: invoice.id) {
                try await PaymentService.recordManualPayment(
                    invoiceID: invoice.id,
                    amountCents: amount,
                    method: method,
                    tipCents: tip,
                    note: note
                )
            }
            await onFinished()
            toasts.show("\(method.displayName) payment recorded")
            dismiss()
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }
}

// MARK: - Charge saved card

struct InvoiceChargeSavedCardSheet: View {
    let invoice: Invoice
    /// The customer's pay-link token (managers+; nil hides "Share pay link").
    let linkToken: UUID?
    let cards: [SavedCard]
    /// May text the pay link when the bank asks for authentication.
    let canMessage: Bool
    let onFinished: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var selectedCardID: UUID?
    @State private var amountText = ""
    @State private var didSetUp = false
    @State private var errorText: String?
    @State private var needsCustomer = false
    @State private var nonce = MoneyEdge.newNonce()
    /// One pay-link text per sheet (a retry never texts twice).
    @State private var textNonce = MoneyEdge.newNonce()
    /// Cards Stripe no longer has (removed by the server while charging);
    /// hidden until the invoice screen reloads its list.
    @State private var removedCardIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            FormScreen {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Card on file")
                        .font(Theme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    ForEach(availableCards) { card in
                        InvoiceSavedCardRow(card: card, isSelected: card.id == selectedCardID) {
                            selectedCardID = card.id
                        }
                    }
                    if availableCards.isEmpty {
                        Text("No saved cards left for this customer.")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                ThemedTextField(
                    label: "Amount",
                    placeholder: "0.00",
                    text: $amountText,
                    kind: .money,
                    hint: "Balance due: \(Money.format(cents: invoice.balanceCents, currencyCode: currencyCode))"
                )
                Text("The card is charged right away without the customer present, as they agreed when saving it.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let errorText {
                    InlineMessage(text: errorText)
                }
                if needsCustomer {
                    customerConfirmationActions
                } else {
                    AsyncButton(chargeTitle, style: .themeMoney) {
                        await charge()
                    }
                    .disabled(selectedCardID == nil)
                }
            }
            .navigationTitle("Charge card on file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                if !didSetUp {
                    didSetUp = true
                    selectedCardID = cards.first(where: { $0.isDefault })?.id ?? cards.first?.id
                    amountText = Money.editableString(cents: max(invoice.balanceCents, 0), currencyCode: currencyCode)
                }
            }
        }
    }

    private var currencyCode: String { appState.currencyCode }

    private var availableCards: [SavedCard] {
        cards.filter { !removedCardIDs.contains($0.id) }
    }

    private var chargeTitle: String {
        if let amount = Money.parseCents(amountText, currencyCode: currencyCode), amount > 0 {
            return "Charge \(Money.format(cents: amount, currencyCode: currencyCode))"
        }
        return "Charge card"
    }

    @ViewBuilder
    private var customerConfirmationActions: some View {
        if canMessage {
            AsyncButton("Text the pay link") {
                await textPayLink()
            }
        }
        if let linkToken, let url = MoneyLinks.invoice(token: linkToken) {
            ShareLink(item: url) {
                Label("Share pay link", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.themeSecondary)
        }
    }

    private func charge() async {
        errorText = nil
        guard let card = availableCards.first(where: { $0.id == selectedCardID }) else {
            errorText = "Choose a card."
            return
        }
        guard let amount = Money.parseCents(amountText, currencyCode: currencyCode), amount > 0 else {
            errorText = "Enter the amount to charge."
            return
        }
        guard amount <= invoice.balanceCents else {
            errorText = "The amount can't be more than the balance due."
            return
        }
        do {
            let shopID = try appState.requireShopID()
            let result = try await PaymentService.chargeSavedCard(
                shopID: shopID,
                invoiceID: invoice.id,
                paymentMethodID: card.stripePaymentMethodID,
                amountCents: amount == invoice.balanceCents ? nil : amount,
                nonce: nonce
            )
            await onFinished()
            if result.succeeded {
                toasts.show("Charged \(card.label)")
            } else {
                toasts.show("Charge is processing — it shows once Stripe confirms it.", style: .info)
            }
            dismiss()
        } catch let edgeError as EdgeFunctionError where edgeError.needsCustomerAuthentication {
            needsCustomer = true
            errorText = edgeError.message
        } catch let edgeError as EdgeFunctionError where edgeError.reason == "saved_card_removed" {
            // Stripe no longer has that card; the server removed it. Show
            // why, drop it here and reload the invoice's cards.
            errorText = edgeError.message
            removedCardIDs.insert(card.id)
            selectedCardID = availableCards.first(where: { $0.isDefault })?.id ?? availableCards.first?.id
            nonce = MoneyEdge.newNonce()
            await onFinished()
        } catch {
            errorText = ErrorText.message(for: error)
            // A declined card (any 4xx) is final for this attempt: a new tap
            // is a new charge. No answer or a 5xx may mean Stripe charged
            // anyway: keep the nonce so a new tap is a retry of this charge
            // and never charges twice (RequestAttempt).
            if let edgeError = error as? EdgeFunctionError,
               RequestAttempt.isDefinitiveFailure(status: edgeError.status) {
                nonce = MoneyEdge.newNonce()
            }
        }
    }

    private func textPayLink() async {
        do {
            let shopID = try appState.requireShopID()
            let result = try await InvoiceService.sendInvoiceMessage(
                shopID: shopID,
                invoice: invoice,
                channel: .sms,
                nonce: textNonce
            )
            if result.failed {
                errorText = result.error?.trimmedNonEmpty ?? "The text could not be delivered."
                return
            }
            toasts.show("Pay link texted to the customer")
            dismiss()
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }
}

private struct InvoiceSavedCardRow: View {
    let card: SavedCard
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Theme.glacier : Theme.textTertiary)
                    .accessibilityHidden(true)
                Text(card.label)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                if card.isDefault {
                    StatusBadge(text: "Default", tone: .neutral)
                }
                Spacer(minLength: 0)
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Send

struct InvoiceSendSheet: View {
    let invoice: Invoice
    let customer: QuoteCustomerRef?
    let onSent: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var notifyCustomer = true
    @State private var channel: MoneyMessageChannel = .sms
    @State private var errorText: String?
    /// One per compose (reused when Send is tapped again after a failure,
    /// so the server never queues the message twice); new per channel.
    @State private var nonce = MoneyEdge.newNonce()

    var body: some View {
        NavigationStack {
            FormScreen {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(invoice.sentAt == nil ? "Send \(invoice.title)" : "Resend \(invoice.title)")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.textPrimary)
                    Text(explanation)
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Toggle("Message the customer", isOn: $notifyCustomer)
                        .font(Theme.Typography.body)
                        .tint(Theme.glacier)
                    Picker("Send by", selection: $channel) {
                        ForEach(MoneyMessageChannel.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!notifyCustomer)
                    .opacity(notifyCustomer ? 1 : 0.45)
                    if notifyCustomer {
                        MoneyDocumentMessagePreviewView(
                            request: MoneyDocumentMessage.Request(kind: .invoiceSent, id: invoice.id, channel: channel)
                        )
                    } else {
                        Text("No message is sent. Share the pay link yourself from the invoice.")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .cardStyle()
                .onChange(of: channel) {
                    nonce = MoneyEdge.newNonce()
                }
                if let errorText {
                    InlineMessage(text: errorText)
                }
                AsyncButton(invoice.sentAt == nil ? "Send invoice" : "Resend invoice", style: .themeMoney) {
                    await send()
                }
            }
            .navigationTitle("Send invoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var explanation: String {
        invoice.status == .draft
            ? "Sending issues the invoice (it gets its due date) so the customer can pay it online."
            : "The customer gets the invoice again with the current balance and pay link."
    }

    private func send() async {
        errorText = nil
        let issued: Invoice
        do {
            issued = try await InvoiceService.markSent(invoiceID: invoice.id)
        } catch {
            errorText = ErrorText.message(for: error)
            return
        }
        var messageProblem: String?
        if notifyCustomer {
            do {
                let shopID = try appState.requireShopID()
                let result = try await InvoiceService.sendInvoiceMessage(
                    shopID: shopID,
                    invoice: issued,
                    channel: channel,
                    nonce: nonce
                )
                if result.failed {
                    messageProblem = result.error?.trimmedNonEmpty ?? "The message could not be delivered."
                }
            } catch {
                messageProblem = ErrorText.message(for: error)
            }
        }
        await onSent()
        if let messageProblem {
            toasts.show("Invoice marked as sent, but the message wasn't sent: \(messageProblem)", style: .error, duration: .seconds(6))
        } else {
            toasts.show(notifyCustomer ? "Invoice sent" : "Invoice marked as sent")
        }
        dismiss()
    }
}

// MARK: - Void

struct InvoiceVoidSheet: View {
    let invoice: Invoice
    /// An unfinished card attempt is pending; it's cancelled first.
    let hasOpenCardAttempt: Bool
    let onFinished: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var reason = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            FormScreen {
                Text("Voiding cancels \(invoice.title) for good. Payments tied to its job move back to the job so a new invoice picks them up. Refund any other money first.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                FormRow("Reason (optional)") {
                    TextField("Why it's being voided", text: $reason, axis: .vertical)
                        .lineLimit(1...4)
                        .inputFieldStyle()
                }
                if hasOpenCardAttempt {
                    InlineMessage(
                        text: "A card payment was started on this invoice but not finished. Voiding cancels it.",
                        kind: .info
                    )
                }
                if let errorText {
                    InlineMessage(text: errorText)
                }
                AsyncButton("Void invoice", role: .destructive, style: .themeDestructive) {
                    await submit()
                }
            }
            .navigationTitle("Void invoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func submit() async {
        errorText = nil
        do {
            let shopID = try appState.requireShopID()
            if hasOpenCardAttempt {
                // void_invoice refuses while a card attempt is in flight.
                try await PaymentService.cancelOpenPayments(shopID: shopID, invoiceID: invoice.id)
            }
            // It also refuses (0116: 55000 HINT checkout_open) while a card
            // payment page of the invoice or its job can still be paid: the
            // pages are released and the void tried once more; a page that
            // is already processing keeps it refused with the server's text.
            _ = try await PaymentService.releasingOpenCheckouts(shopID: shopID, invoiceID: invoice.id) {
                try await InvoiceService.void(invoiceID: invoice.id, reason: reason)
            }
            await onFinished()
            toasts.show("\(invoice.title) voided")
            dismiss()
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }
}

// MARK: - Refund

struct InvoiceRefundSheet: View {
    let payment: Payment
    let onFinished: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var didSetUp = false
    @State private var errorText: String?
    /// One nonce per Stripe refund attempt: kept when the server may have
    /// refunded without answering (a tap again is a retry and never refunds
    /// twice), replaced after a definitive answer so a deliberate second
    /// refund of the same amount goes through.
    @State private var attempt = RequestAttempt()

    var body: some View {
        NavigationStack {
            FormScreen {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(payment.methodLabel)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.textPrimary)
                    MoneyAmountRow(label: "Paid", cents: payment.amountCents, currencyCode: currencyCode)
                    if payment.tipCents > 0 {
                        MoneyAmountRow(label: "Tip", cents: payment.tipCents, currencyCode: currencyCode)
                    }
                    if payment.refundedCents > 0 {
                        MoneyAmountRow(label: "Already refunded", cents: payment.refundedCents, currencyCode: currencyCode)
                    }
                    MoneyAmountRow(label: "Refundable", cents: payment.refundableCents, currencyCode: currencyCode, isStrong: true)
                }
                .cardStyle()
                ThemedTextField(
                    label: "Refund amount",
                    placeholder: "0.00",
                    text: $amountText,
                    kind: .money,
                    hint: refundHint
                )
                if let errorText {
                    InlineMessage(text: errorText)
                }
                AsyncButton("Refund", role: .destructive, style: .themeDestructive) {
                    await submit()
                }
            }
            .navigationTitle("Refund payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if !didSetUp {
                    didSetUp = true
                    amountText = Money.editableString(cents: payment.refundableCents, currencyCode: currencyCode)
                }
            }
        }
    }

    private var currencyCode: String { appState.currencyCode }

    private var refundHint: String {
        switch payment.method {
        case .card, .cardPresent:
            return "Stripe returns it to the customer's card. The amount is refunded first, then the tip."
        case .achDebit:
            return "Stripe returns it to the customer's bank account (this can take several business days)."
        case .bnpl:
            return "Stripe returns it through the customer's pay-later provider."
        case .giftCard:
            return "The amount goes back onto the gift card or store credit it was paid with."
        case .cash, .check, .bankTransfer, .other:
            return "Records money you handed back. Nothing is sent to the customer's bank."
        }
    }

    private func submit() async {
        errorText = nil
        guard let amount = Money.parseCents(amountText, currencyCode: currencyCode), amount > 0 else {
            errorText = "Enter the amount to refund."
            return
        }
        guard amount <= payment.refundableCents else {
            errorText = "The refund can't be more than the refundable amount."
            return
        }
        do {
            if payment.isStripeBacked {
                let shopID = try appState.requireShopID()
                _ = try await PaymentService.refundCardPayment(
                    shopID: shopID,
                    paymentID: payment.id,
                    amountCents: amount == payment.refundableCents ? nil : amount,
                    nonce: attempt.nonce
                )
                attempt.succeeded()
            } else {
                _ = try await PaymentService.refundManualPayment(paymentID: payment.id, amountCents: amount)
            }
            await onFinished()
            toasts.show("Refunded \(Money.format(cents: amount, currencyCode: currencyCode))")
            dismiss()
        } catch let edgeError as EdgeFunctionError {
            attempt.failed(status: edgeError.status)
            errorText = edgeError.message
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }
}
