//
//  InvoiceCardPaymentSheet.swift
//  DetailCRM
//
//  Collect a card payment on the shop's connected Stripe account:
//  1. choose the amount (default: the balance; partial allowed) and a tip,
//  2. the `payments` edge function (`payment_sheet`) creates the
//     PaymentIntent server-side (amount validated against the balance),
//     records it as a pending payment and returns the publishable key and
//     connected account id (plus the Stripe customer and ephemeral key for
//     manager+ only — a technician's sheet takes a new card),
//  3. Stripe's PaymentSheet collects the card (card data never touches the
//     app or our servers),
//  4. the webhook records the payment; the sheet polls briefly so the
//     invoice shows it.
//  Leaving without paying calls `cancel_open_payments`, so the pending
//  attempt doesn't block a cash payment or a void until the sweep.
//
//  In person (P-6, only when Config.plist turns it on): Tap to Pay on
//  iPhone (MoneyTapToPayButton) or a Bluetooth card reader
//  (MoneyReaderPickerView) take the same amount and tip.
//

import SwiftUI
import StripePaymentSheet
import DetailCore

/// Builds a PaymentSheet for the connected account exactly as the server
/// returned it (direct charge on the shop's Stripe account).
enum InvoiceStripeSheetFactory {
    @MainActor
    static func make(params: PaymentSheetParams, merchantName: String) -> PaymentSheet {
        STPAPIClient.shared.publishableKey = params.publishableKey
        STPAPIClient.shared.stripeAccount = params.stripeAccountID
        var configuration = PaymentSheet.Configuration()
        configuration.merchantDisplayName = merchantName
        // Only manager+ get the customer (saved cards); technicians don't.
        if let credentials = params.customerCredentials {
            configuration.customer = PaymentSheet.CustomerConfiguration(
                id: credentials.customerID,
                ephemeralKeySecret: credentials.ephemeralKeySecret
            )
        }
        return PaymentSheet(paymentIntentClientSecret: params.clientSecret, configuration: configuration)
    }
}

struct InvoiceCollectCardSheet: View {
    let invoice: Invoice
    let onFinished: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var tipPreset: MoneyTipPreset = .none
    @State private var customTipText = ""
    @State private var params: PaymentSheetParams?
    @State private var paymentSheet: PaymentSheet?
    @State private var isConfirming = false
    /// The server holds a pending, unconfirmed PaymentIntent for this
    /// invoice (created by `prepare`); released on the way out.
    @State private var hasOpenAttempt = false
    @State private var isReleasing = false
    @State private var errorText: String?
    @State private var didSetUp = false
    @State private var nonce = MoneyEdge.newNonce()
    @State private var showingReaderPicker = false

    var body: some View {
        NavigationStack {
            FormScreen {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(invoice.title)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("Balance due")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        MoneyText(cents: invoice.balanceCents, currencyCode: currencyCode, emphasis: .attention)
                    }
                }
                if let params, let paymentSheet {
                    readyView(params: params, paymentSheet: paymentSheet)
                } else {
                    entryView
                }
                if let errorText {
                    InlineMessage(text: errorText)
                }
            }
            .navigationTitle("Card payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isReleasing {
                        ProgressView()
                            .accessibilityLabel("Cancelling the card payment")
                    } else {
                        Button("Cancel") {
                            Task { await close() }
                        }
                        .disabled(isConfirming)
                    }
                }
            }
            // With an open attempt, leave through Cancel so it is released.
            .interactiveDismissDisabled(isConfirming || isReleasing || hasOpenAttempt)
            .onAppear(perform: setUp)
            .sheet(isPresented: $showingReaderPicker) {
                MoneyReaderPickerView(
                    invoice: invoice,
                    amountCents: amountCents,
                    tipCents: tipCents,
                    entryProblem: tipProblem,
                    onFinished: onFinished,
                    onDone: { dismiss() }
                )
            }
        }
    }

    private var currencyCode: String { appState.currencyCode }

    // MARK: Entry

    private var entryView: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            ThemedTextField(
                label: "Amount",
                placeholder: "0.00",
                text: $amountText,
                kind: .money,
                hint: "Defaults to the balance. You can collect part of it."
            )
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Tip")
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(MoneyTipPreset.standard) { preset in
                            MoneyFilterChip(title: preset.title, isSelected: tipPreset == preset) {
                                tipPreset = preset
                            }
                        }
                    }
                }
                if tipPreset == .custom {
                    ThemedTextField(label: "Tip amount", placeholder: "0.00", text: $customTipText, kind: .money)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                MoneyAmountRow(label: "Payment", cents: amountCents ?? 0, currencyCode: currencyCode)
                MoneyAmountRow(label: "Tip", cents: tipCents, currencyCode: currencyCode)
                Divider().overlay(Theme.border)
                MoneyAmountRow(label: "Card charge", cents: (amountCents ?? 0) + tipCents, currencyCode: currencyCode, isStrong: true)
                Text("Tips go to the shop and never change the invoice balance.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .cardStyle()
            AsyncButton(style: .themeMoney) {
                await prepare()
            } label: {
                Label("Continue to card entry", systemImage: "creditcard")
            }
            if AppConfig.tapToPayEnabled || AppConfig.terminalBluetoothEnabled {
                inPersonOptions
            }
        }
    }

    /// Tap to Pay on iPhone / a Bluetooth reader (switched on in Config.plist).
    private var inPersonOptions: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Or take the card in person")
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            if AppConfig.tapToPayEnabled {
                MoneyTapToPayButton(
                    invoice: invoice,
                    amountCents: amountCents,
                    tipCents: tipCents,
                    entryProblem: tipProblem,
                    onFinished: onFinished,
                    onDone: { dismiss() }
                )
            }
            if AppConfig.terminalBluetoothEnabled {
                Button {
                    showingReaderPicker = true
                } label: {
                    Label("Use a card reader", systemImage: "creditcard.viewfinder")
                }
                .buttonStyle(.themeSecondary)
            }
        }
    }

    /// A custom tip that isn't a readable amount.
    private var tipProblem: String? {
        tipPreset == .custom && customTipCents == nil ? "Enter the tip as an amount, e.g. 10.00." : nil
    }

    // MARK: Ready

    private func readyView(params: PaymentSheetParams, paymentSheet: PaymentSheet) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Card charge")
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                MoneyText(cents: params.chargeCents, currencyCode: params.currency, size: .large, emphasis: .attention)
                if params.tipCents > 0 {
                    Text("Includes a \(Money.format(cents: params.tipCents, currencyCode: params.currency)) tip")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .cardStyle()
            if isConfirming {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView()
                        .tint(Theme.glacier)
                    Text("Confirming the payment with Stripe…")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                PaymentSheet.PaymentButton(
                    paymentSheet: paymentSheet,
                    onCompletion: { result in handle(result) }
                ) {
                    InvoicePayButtonLabel(title: "Enter card details")
                }
                Button("Change amount or tip") {
                    self.params = nil
                    self.paymentSheet = nil
                    nonce = MoneyEdge.newNonce()
                }
                .buttonStyle(.themePlain)
            }
        }
    }

    // MARK: Values

    private var amountCents: Int? {
        Money.parseCents(amountText, currencyCode: currencyCode)
    }

    private var customTipCents: Int? {
        customTipText.trimmedNonEmpty == nil ? 0 : Money.parseCents(customTipText, currencyCode: currencyCode)
    }

    private var tipCents: Int {
        tipPreset.tipCents(amountCents: amountCents ?? 0, customCents: customTipCents)
    }

    // MARK: Actions

    private func setUp() {
        guard !didSetUp else { return }
        didSetUp = true
        amountText = Money.editableString(cents: max(invoice.balanceCents, 0), currencyCode: currencyCode)
    }

    private func prepare() async {
        errorText = nil
        guard let amount = amountCents, amount > 0 else {
            errorText = "Enter the amount to collect."
            return
        }
        guard amount <= invoice.balanceCents else {
            errorText = "The amount can't be more than the balance due."
            return
        }
        if tipPreset == .custom && customTipCents == nil {
            errorText = "Enter the tip as an amount, e.g. 10.00."
            return
        }
        do {
            let shopID = try appState.requireShopID()
            let result = try await PaymentService.paymentSheet(
                shopID: shopID,
                invoiceID: invoice.id,
                amountCents: amount == invoice.balanceCents ? nil : amount,
                tipCents: tipCents,
                nonce: nonce,
                ephemeralKeyAPIVersion: STPAPIClient.apiVersion
            )
            hasOpenAttempt = true
            paymentSheet = InvoiceStripeSheetFactory.make(
                params: result,
                merchantName: appState.shop?.name ?? "Payment"
            )
            params = result
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }

    private func handle(_ result: PaymentSheetResult) {
        switch result {
        case .completed:
            // Confirmed with Stripe: never cancel it from here on.
            hasOpenAttempt = false
            Task { await confirm() }
        case .canceled:
            break
        case .failed(let error):
            errorText = ErrorText.message(for: error)
        }
    }

    /// Cancel: releases an unconfirmed attempt (`cancel_open_payments`) so
    /// the invoice can take cash or be voided right away, then closes.
    private func close() async {
        guard hasOpenAttempt, let shopID = try? appState.requireShopID() else {
            dismiss()
            return
        }
        isReleasing = true
        errorText = nil
        do {
            let release = try await PaymentService.cancelOpenPayments(shopID: shopID, invoiceID: invoice.id)
            hasOpenAttempt = false
            await onFinished()
            isReleasing = false
            if release.succeeded > 0 {
                toasts.show("The card payment went through before it could be cancelled.", style: .info)
            } else if release.inProgress > 0 {
                toasts.show("A card payment is still processing. It shows on the invoice once Stripe confirms it.", style: .info)
            }
            dismiss()
        } catch {
            isReleasing = false
            // Leave anyway: the server abandons unconfirmed attempts on its own.
            hasOpenAttempt = false
            toasts.show(
                "The unfinished card payment couldn't be cancelled right now, so it may block cash payments for up to 30 minutes. \(ErrorText.message(for: error))",
                style: .error,
                duration: .seconds(6)
            )
            dismiss()
        }
    }

    private func confirm() async {
        guard let params, let shopID = try? appState.requireShopID() else { return }
        isConfirming = true
        errorText = nil
        let status = await PaymentService.awaitSettlement(shopID: shopID, paymentIntentID: params.paymentIntentID)
        await onFinished()
        isConfirming = false
        if status == .succeeded {
            toasts.show("Payment received")
        } else if status == .failed || status == .cancelled {
            toasts.show("The card payment didn't go through. Try again or use another method.", style: .error)
        } else {
            toasts.show("Payment submitted — it shows on the invoice once Stripe confirms it.", style: .info)
        }
        dismiss()
    }
}

/// Amber, full-width label for money buttons that aren't SwiftUI Buttons
/// (Stripe's PaymentButton).
struct InvoicePayButtonLabel: View {
    let title: String

    var body: some View {
        Label(title, systemImage: "creditcard")
            .font(Theme.Typography.button)
            .foregroundStyle(Theme.onAmber)
            .frame(maxWidth: .infinity)
            .frame(minHeight: Theme.Size.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.amber)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}
