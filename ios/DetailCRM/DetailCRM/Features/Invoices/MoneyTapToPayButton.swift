//
//  MoneyTapToPayButton.swift
//  DetailCRM
//
//  "Tap to Pay on iPhone" on the card payment sheet (P-6). Shown only when
//  Config.plist turns it on (TAP_TO_PAY_ENABLED — after Apple grants the
//  entitlement) and the SDK says this iPhone supports it; otherwise it
//  explains why it isn't offered. The first use shows how it works. The
//  payment itself runs in MoneyTapToPayModel; this shows its progress.
//  When the payment ends (paid, declined / failed, canceled) VoiceOver
//  says so at once and focus moves to the result, because Apple's card
//  screen has just closed and the operator can't see the change.
//

import SwiftUI
import UIKit
import DetailCore

struct MoneyTapToPayButton: View {
    let invoice: Invoice
    /// The amount typed on the sheet (nil when it isn't a valid amount).
    let amountCents: Int?
    let tipCents: Int
    /// A problem with the sheet's entries (e.g. an unreadable tip).
    var entryProblem: String? = nil
    /// Reloads the invoice (after a payment, or a released attempt).
    let onFinished: () async -> Void
    /// Closes the card payment sheet after a successful payment.
    let onDone: () -> Void

    @Environment(AppState.self) private var appState

    private var model: MoneyTapToPayModel { .shared }

    @State private var showingEducation = false
    @State private var startAfterEducation = false
    @State private var activeRequest: MoneyTapToPayModel.Request?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if !model.hasCheckedTapToPay {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().tint(Theme.glacier)
                    Text("Checking Tap to Pay…")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if let reason = model.tapToPayUnavailableReason {
                InlineMessage(text: "Tap to Pay isn't available: \(reason)", kind: .info)
            } else {
                Button {
                    begin()
                } label: {
                    Label("Tap to Pay on iPhone", systemImage: "wave.3.right.circle")
                }
                .buttonStyle(.themeMoney)
                .disabled(validationProblem != nil)
                .accessibilityHint("Takes the card on this iPhone")
                if let validationProblem {
                    Text(validationProblem)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                Button("How Tap to Pay works") {
                    startAfterEducation = false
                    showingEducation = true
                }
                .buttonStyle(.themePlain)
            }
        }
        .task {
            guard let shopID = try? appState.requireShopID() else { return }
            model.checkTapToPaySupport(shopID: shopID)
        }
        .sheet(isPresented: $showingEducation) {
            MoneyTapToPayEducationView {
                if startAfterEducation {
                    startAfterEducation = false
                    start()
                }
            }
        }
        .sheet(item: $activeRequest) { request in
            MoneyTapToPayButton.ProgressSheet(
                request: request,
                currencyCode: appState.currencyCode,
                onFinished: onFinished,
                onDone: onDone
            )
        }
    }

    /// Why the typed amount can't be collected, or nil.
    private var validationProblem: String? {
        if let entryProblem { return entryProblem }
        guard let amountCents, amountCents > 0 else { return "Enter the amount to collect first." }
        guard amountCents <= invoice.balanceCents else { return "The amount can't be more than the balance due." }
        return nil
    }

    private func begin() {
        guard validationProblem == nil else { return }
        if MoneyTapToPayEducationView.hasBeenSeen {
            start()
        } else {
            startAfterEducation = true
            showingEducation = true
        }
    }

    private func start() {
        guard validationProblem == nil, let amountCents, let shopID = try? appState.requireShopID() else { return }
        model.reset()
        activeRequest = MoneyTapToPayModel.Request(
            shopID: shopID,
            invoiceID: invoice.id,
            amountCents: amountCents == invoice.balanceCents ? nil : amountCents,
            tipCents: tipCents,
            merchantName: appState.shop?.name ?? "Payment",
            mode: .tapToPay
        )
    }

    // MARK: - Progress

    /// Runs one in-person payment and shows how it goes.
    struct ProgressSheet: View {
        let request: MoneyTapToPayModel.Request
        let currencyCode: String
        let onFinished: () async -> Void
        let onDone: () -> Void

        @Environment(\.dismiss) private var dismiss
        @Environment(ToastCenter.self) private var toasts

        private var model: MoneyTapToPayModel { .shared }

        var body: some View {
            NavigationStack {
                MoneyTapToPayButton.ProgressContent(
                    wholeBalance: request.amountCents == nil,
                    currencyCode: currencyCode,
                    onRetry: { Task { await run() } },
                    onClose: { Task { await close() } }
                )
                .navigationTitle(request.mode == .tapToPay ? "Tap to Pay" : "Card reader")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if model.phase.isBusy {
                            Button("Cancel") { model.cancel() }
                                .disabled(model.phase == .processing)
                        } else {
                            Button("Close") { Task { await close() } }
                        }
                    }
                }
            }
            .interactiveDismissDisabled(model.phase.isBusy)
            .task { await run() }
        }

        private func run() async {
            await model.collect(request)
            if case .succeeded = model.phase {
                await onFinished()
            }
        }

        private func close() async {
            let succeeded: Bool
            if case .succeeded(let message) = model.phase {
                toasts.show(message)
                succeeded = true
            } else {
                succeeded = false
                // A released attempt changes what the invoice shows.
                await onFinished()
            }
            model.reset()
            dismiss()
            if succeeded {
                onDone()
            }
        }
    }

    /// The model's phase as a screen: the amount the server set up, status
    /// icon, message, actions.
    struct ProgressContent: View {
        /// The whole balance was asked for (the server charges the balance
        /// less payments still in flight).
        let wholeBalance: Bool
        let currencyCode: String
        let onRetry: () -> Void
        let onClose: () -> Void

        private var model: MoneyTapToPayModel { .shared }

        /// Focus goes to the result when the payment ends.
        @AccessibilityFocusState private var resultFocused: Bool
        @State private var announceTask: Task<Void, Never>?

        var body: some View {
            FormScreen {
                VStack(spacing: Theme.Spacing.lg) {
                    amount
                    icon
                        .frame(height: 72)
                    Text(message)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.updatesFrequently)
                        .accessibilityFocused($resultFocused)
                }
                .frame(maxWidth: .infinity)
                .cardStyle()
                actions
            }
            .onChange(of: model.phase) { _, phase in
                announceOutcome(phase)
            }
            .onDisappear { announceTask?.cancel() }
        }

        /// The end of a payment, for VoiceOver (nil while it's under way).
        static func outcome(of phase: MoneyTapToPayModel.Phase) -> PaymentOutcomeSpeech.Outcome? {
            switch phase {
            case .succeeded(let text): return .succeeded(text)
            case .failed(let text): return .failed(text)
            case .canceled: return .canceled
            case .idle, .preparing, .collecting, .processing: return nil
            }
        }

        /// Says the result and moves focus to it, after Apple's card screen
        /// has closed (an announcement made while it closes is cut off).
        private func announceOutcome(_ phase: MoneyTapToPayModel.Phase) {
            announceTask?.cancel()
            guard let outcome = Self.outcome(of: phase) else { return }
            let text = PaymentOutcomeSpeech.announcement(for: outcome)
            announceTask = Task { @MainActor in
                try? await Task.sleep(for: PaymentOutcomeSpeech.announcementDelay)
                guard !Task.isCancelled, Self.outcome(of: model.phase) == outcome else { return }
                resultFocused = true
                let announcement = NSAttributedString(
                    string: text,
                    attributes: [.accessibilitySpeechQueueAnnouncement: true]
                )
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }

        /// Only the server's figure is shown: before it answers the amount
        /// isn't known (it can be less than the balance while another
        /// payment is still being processed).
        @ViewBuilder
        private var amount: some View {
            if let cents = model.chargeCents {
                VStack(spacing: Theme.Spacing.xs) {
                    MoneyText(cents: cents, currencyCode: currencyCode, size: .large, emphasis: .attention)
                    if wholeBalance {
                        Text("The balance due, less any payment still being processed.")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                Text(amountPlaceholder)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }

        private var amountPlaceholder: String {
            switch model.phase {
            case .idle, .preparing, .collecting, .processing, .succeeded:
                return "Setting up the amount…"
            case .failed, .canceled:
                return "Nothing was charged."
            }
        }

        @ViewBuilder
        private var icon: some View {
            switch model.phase {
            case .idle, .preparing, .processing:
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.glacier)
            case .collecting:
                Image(systemName: "wave.3.right.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.glacier)
                    .accessibilityHidden(true)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.successInk)
                    .accessibilityHidden(true)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.dangerInk)
                    .accessibilityHidden(true)
            case .canceled:
                Image(systemName: "xmark.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
        }

        private var message: String {
            switch model.phase {
            case .idle: return "Getting ready…"
            case .preparing(let text): return text
            case .collecting(let text): return text
            case .processing: return "Confirming the payment with Stripe…"
            case .succeeded(let text): return text
            case .failed(let text): return text
            case .canceled: return "The payment was canceled. Nothing was charged."
            }
        }

        @ViewBuilder
        private var actions: some View {
            switch model.phase {
            case .succeeded:
                Button("Done", action: onClose)
                    .buttonStyle(.themePrimary)
            case .failed, .canceled:
                Button("Try again", action: onRetry)
                    .buttonStyle(.themeMoney)
                Button("Close", action: onClose)
                    .buttonStyle(.themeSecondary)
            case .idle, .preparing, .collecting, .processing:
                EmptyView()
            }
        }
    }
}

extension MoneyTapToPayModel.Request: Identifiable {
    var id: String { "\(invoiceID.uuidString)-\(mode == .tapToPay ? "tap" : "reader")-\(amountCents ?? -1)-\(tipCents)" }
}
