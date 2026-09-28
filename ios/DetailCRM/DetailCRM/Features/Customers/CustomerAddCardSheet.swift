//
//  CustomerAddCardSheet.swift
//  DetailCRM
//
//  Save a customer's card on file without charging it (managers and
//  above), for later off-session charges (invoices, memberships):
//  1. the `payments` edge function (`setup_card`) creates an off-session
//     SetupIntent on the shop's connected account and returns the Stripe
//     customer, its ephemeral key and the publishable key,
//  2. Stripe's PaymentSheet in setup mode collects the card on this phone
//     (card data never touches the app or our servers),
//  3. the webhook (`setup_intent.succeeded`) stores brand / last4 / expiry
//     on the customer; the sheet polls briefly so the card shows here.
//  Leaving before the card is entered needs no clean-up: an unconfirmed
//  SetupIntent charges nothing and saves nothing.
//

import SwiftUI
import StripePaymentSheet
import DetailCore

struct CustomerAddCardSheet: View {
    let customerID: UUID
    let customerName: String
    /// Stripe payment method ids already on file (to spot the new one).
    let knownCards: Set<String>
    let onFinished: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var paymentSheet: PaymentSheet?
    @State private var isConfirming = false
    @State private var errorText: String?
    /// One per attempt: a retry of the same attempt reuses the SetupIntent.
    @State private var nonce = MoneyEdge.newNonce()

    var body: some View {
        NavigationStack {
            FormScreen {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(customerName)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Hand the phone to the customer to enter their card. Nothing is charged now. Stripe keeps the card, and the shop can charge it later for an invoice or a membership.")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let paymentSheet {
                    readyView(paymentSheet)
                } else {
                    AsyncButton("Continue", style: .themePrimary) {
                        await prepare()
                    }
                }
                if let errorText {
                    InlineMessage(text: errorText, kind: .error)
                }
            }
            .navigationTitle("Save a card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isConfirming)
                }
            }
            .interactiveDismissDisabled(isConfirming)
        }
    }

    @ViewBuilder
    private func readyView(_ paymentSheet: PaymentSheet) -> some View {
        if isConfirming {
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                    .tint(Theme.glacier)
                Text("Saving the card with Stripe…")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            PaymentSheet.PaymentButton(
                paymentSheet: paymentSheet,
                onCompletion: { result in handle(result) }
            ) {
                InvoicePayButtonLabel(title: "Enter card details")
            }
        }
    }

    private func prepare() async {
        errorText = nil
        do {
            let shopID = try appState.requireShopID()
            let params = try await PaymentService.setupCard(
                shopID: shopID,
                customerID: customerID,
                nonce: nonce,
                ephemeralKeyAPIVersion: STPAPIClient.apiVersion
            )
            STPAPIClient.shared.publishableKey = params.publishableKey
            STPAPIClient.shared.stripeAccount = params.stripeAccountID
            var configuration = PaymentSheet.Configuration()
            configuration.merchantDisplayName = appState.shop?.name ?? "Save card"
            configuration.customer = PaymentSheet.CustomerConfiguration(
                id: params.customerID,
                ephemeralKeySecret: params.ephemeralKeySecret
            )
            paymentSheet = PaymentSheet(setupIntentClientSecret: params.clientSecret, configuration: configuration)
        } catch {
            errorText = ErrorText.message(for: error)
        }
    }

    private func handle(_ result: PaymentSheetResult) {
        switch result {
        case .completed:
            Task { await confirm() }
        case .canceled:
            break
        case .failed(let error):
            errorText = ErrorText.message(for: error)
            // A new attempt gets a new SetupIntent.
            paymentSheet = nil
            nonce = MoneyEdge.newNonce()
        }
    }

    private func confirm() async {
        guard let shopID = try? appState.requireShopID() else { return }
        isConfirming = true
        errorText = nil
        let card = await PaymentService.awaitNewSavedCard(shopID: shopID, customerID: customerID, known: knownCards)
        await onFinished()
        isConfirming = false
        if let card {
            toasts.show("\(card.label) saved")
        } else {
            toasts.show("Card submitted. It shows on the customer once Stripe confirms it.", style: .info)
        }
        dismiss()
    }
}
