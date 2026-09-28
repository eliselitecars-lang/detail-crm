//
//  InvoiceDetailView.swift
//  DetailCRM
//
//  One invoice: balance, collect actions (card via Stripe PaymentSheet or
//  in person, saved card, gift card / store credit, cash/check), lines
//  (per job on a grouped invoice), the server's totals, payments (method,
//  card brand/last4, tip, refunds, bank payments still settling), send /
//  share the pay link or a PDF, automatic reminders, void. Payments update
//  live (realtime) so a settling bank or in-person payment shows up.
//  Actions are gated by role (SPEC §3) and enforced again by the server:
//  technicians only reach this for an assigned job's invoice when the shop
//  lets them collect payments.
//

import SwiftUI
import DetailCore

/// What the signed-in member may do here (UI only; the server decides).
struct InvoicePermissions: Hashable {
    var canManage: Bool
    var canCollect: Bool
    var canRefund: Bool
    var canVoid: Bool
    var canUseSavedCards: Bool
}

enum InvoiceDetailSheet: Identifiable {
    case collectCard
    case recordManual
    case chargeSavedCard
    case redeemGiftCard
    case send
    case void
    case refund(Payment)

    var id: String {
        switch self {
        case .collectCard: return "collectCard"
        case .recordManual: return "recordManual"
        case .chargeSavedCard: return "chargeSavedCard"
        case .redeemGiftCard: return "redeemGiftCard"
        case .send: return "send"
        case .void: return "void"
        case .refund(let payment): return "refund-\(payment.id.uuidString)"
        }
    }
}

struct InvoiceDetailView: View {
    let invoiceID: UUID

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(JobsRealtimeHub.self) private var realtime

    @State private var state: LoadState<InvoiceService.DetailData> = .idle
    @State private var activeSheet: InvoiceDetailSheet?

    var body: some View {
        LoadStateView(state, loadingLabel: "Loading invoice…", retry: { await load() }) { data in
            InvoiceDetailContent(
                data: data,
                permissions: permissions,
                currencyCode: appState.currencyCode,
                clock: appState.clock,
                present: { sheet in activeSheet = sheet }
            )
        }
        .screenBackground()
        .navigationTitle(state.value?.invoice.title ?? "Invoice")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        // A payment changed somewhere (webhook settled a card, bank payment
        // cleared or failed, someone else collected): re-read the invoice.
        .onChange(of: realtime.revision(.payments)) {
            guard activeSheet == nil else { return }
            Task { await load() }
        }
        .sheet(item: $activeSheet, onDismiss: {
            Task { await load() }
        }, content: { sheet in
            sheetContent(sheet)
        })
    }

    private var permissions: InvoicePermissions {
        InvoicePermissions(
            canManage: appState.can(.manageInvoices),
            canCollect: appState.can(.collectPaymentOnAssignedJob),
            canRefund: appState.can(.refundPayments),
            canVoid: appState.can(.voidInvoices),
            canUseSavedCards: appState.can(.useSavedCards)
        )
    }

    @ViewBuilder
    private func sheetContent(_ sheet: InvoiceDetailSheet) -> some View {
        if let data = state.value {
            switch sheet {
            case .collectCard:
                InvoiceCollectCardSheet(invoice: data.invoice) {
                    await load()
                }
            case .recordManual:
                InvoiceManualPaymentSheet(
                    invoice: data.invoice,
                    hasOpenCardAttempt: InvoiceService.hasOpenCardAttempt(data.payments),
                    processingCents: InvoiceService.processingCents(data.payments)
                ) {
                    await load()
                }
            case .redeemGiftCard:
                MoneyGiftCardRedeemSheet(
                    invoice: data.invoice,
                    canUseStoreCredit: permissions.canManage,
                    inFlightCents: Payment.inFlightCents(data.payments, at: Date())
                ) {
                    await load()
                }
            case .chargeSavedCard:
                InvoiceChargeSavedCardSheet(
                    invoice: data.invoice,
                    linkToken: data.linkToken,
                    cards: data.savedCards,
                    canMessage: permissions.canManage
                ) {
                    await load()
                }
            case .send:
                InvoiceSendSheet(invoice: data.invoice, customer: data.customer) {
                    await load()
                }
            case .void:
                InvoiceVoidSheet(
                    invoice: data.invoice,
                    hasOpenCardAttempt: InvoiceService.hasOpenCardAttempt(data.payments)
                ) {
                    await load()
                }
            case .refund(let payment):
                InvoiceRefundSheet(payment: payment) {
                    await load()
                }
            }
        }
    }

    private func load() async {
        guard let shopID = try? appState.requireShopID() else { return }
        state.beginLoading()
        let id = invoiceID
        let includeCards = appState.can(.useSavedCards)
        let includeLink = appState.can(.manageInvoices)
        let result = await LoadState<InvoiceService.DetailData>.result {
            try await InvoiceService.detail(
                shopID: shopID,
                invoiceID: id,
                includeSavedCards: includeCards,
                includeLinkToken: includeLink
            )
        }
        if let message = result.errorMessage, state.value != nil {
            toasts.show(message, style: .error)
        }
        state.apply(result)
    }
}

// MARK: - Content

private struct InvoiceDetailContent: View {
    let data: InvoiceService.DetailData
    let permissions: InvoicePermissions
    let currencyCode: String
    let clock: ShopClock
    let present: (InvoiceDetailSheet) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                AnyView(InvoiceHeaderSection(data: data, canOpenCustomer: permissions.canManage, clock: clock))
                AnyView(InvoiceBalanceSection(
                    data: data,
                    permissions: permissions,
                    currencyCode: currencyCode,
                    present: present
                ))
                AnyView(MoneyInvoiceGroupedLinesSection(
                    lines: data.lines,
                    jobs: data.billedJobs,
                    vehicles: data.vehicles,
                    currencyCode: currencyCode,
                    clock: clock,
                    canOpenJobs: permissions.canManage,
                    hasDocumentDiscount: data.invoice.discountKind != .none
                ))
                AnyView(InvoiceTotalsSection(invoice: data.invoice, currencyCode: currencyCode))
                AnyView(InvoicePaymentsSection(
                    payments: data.payments,
                    canRefund: permissions.canRefund,
                    currencyCode: currencyCode,
                    clock: clock,
                    onRefund: { payment in present(.refund(payment)) }
                ))
                if permissions.canManage && InvoiceDetailContent.showsFollowups(data.invoice) {
                    AnyView(MoneyFollowupStatusRow(
                        kind: .invoice,
                        documentID: data.invoice.id,
                        refreshKey: data.invoice.updatedAt
                    ))
                }
                AnyView(InvoiceManageSection(
                    invoice: data.invoice,
                    linkToken: data.linkToken,
                    permissions: permissions,
                    present: present
                ))
                AnyView(InvoiceNotesSection(invoice: data.invoice, showInternal: permissions.canManage))
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.lg)
        }
    }

    /// Reminders / overdue notices apply to a sent invoice with a balance.
    static func showsFollowups(_ invoice: Invoice) -> Bool {
        invoice.sentAt != nil && invoice.status.acceptsPayment && invoice.balanceCents > 0
    }
}

private struct InvoiceHeaderSection: View {
    let data: InvoiceService.DetailData
    let canOpenCustomer: Bool
    let clock: ShopClock

    var body: some View {
        let invoice = data.invoice
        let badge = invoice.badge()
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                Text(invoice.title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Theme.Spacing.sm)
                StatusBadge(text: badge.text, tone: badge.tone)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                customerRow
                if data.isGrouped {
                    InfoRow(
                        label: "Jobs",
                        value: data.billedJobs.map { "#\($0.number)" }.joined(separator: ", "),
                        systemImage: "square.stack.3d.up"
                    )
                } else if let jobID = invoice.jobID {
                    NavigationLink(value: AppRoute.job(jobID)) {
                        HStack {
                            InfoRow(label: "Job", value: "Open job", systemImage: "wrench.and.screwdriver")
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Theme.textTertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let issuedAt = invoice.issuedAt {
                    InfoRow(label: "Issued", value: clock.shortDayText(issuedAt), systemImage: "calendar")
                }
                if let dueAt = invoice.dueAt, invoice.status != .void {
                    InfoRow(label: "Due", value: clock.shortDayText(dueAt), systemImage: "clock")
                }
                if let sentAt = invoice.sentAt {
                    InfoRow(label: "Last sent", value: clock.dateTimeText(sentAt), systemImage: "paperplane")
                }
                if invoice.status == .void {
                    InfoRow(
                        label: "Voided",
                        value: invoice.voidReason?.trimmedNonEmpty ?? (invoice.voidedAt.map { clock.shortDayText($0) } ?? ""),
                        systemImage: "xmark.circle"
                    )
                }
            }
            .cardStyle()
        }
    }

    @ViewBuilder
    private var customerRow: some View {
        let name = data.customer?.displayName ?? "Customer"
        if canOpenCustomer, let customer = data.customer {
            NavigationLink(value: AppRoute.customer(customer.id)) {
                HStack(spacing: Theme.Spacing.md) {
                    AvatarView(name: name, size: Theme.Size.avatarSmall)
                    Text(name)
                        .font(Theme.Typography.bodyEmphasis)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the customer")
        } else {
            HStack(spacing: Theme.Spacing.md) {
                AvatarView(name: name, size: Theme.Size.avatarSmall)
                Text(name)
                    .font(Theme.Typography.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }
}

private struct InvoiceBalanceSection: View {
    let data: InvoiceService.DetailData
    let permissions: InvoicePermissions
    let currencyCode: String
    let present: (InvoiceDetailSheet) -> Void

    var body: some View {
        let invoice = data.invoice
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(balanceTitle)
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                MoneyText(
                    cents: max(invoice.balanceCents, 0),
                    currencyCode: currencyCode,
                    size: .large,
                    emphasis: invoice.canCollect ? .attention : .normal
                )
                if invoice.balanceCents < 0 {
                    Text("Customer credit: \(Money.format(cents: -invoice.balanceCents, currencyCode: currencyCode))")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                if hasPendingPayment {
                    InlineMessage(text: "A card payment is processing. It shows here once Stripe confirms it.", kind: .info)
                }
                if processingCents > 0 {
                    InlineMessage(
                        text: "\(Money.format(cents: processingCents, currencyCode: currencyCode)) is on its way by bank or pay-later payment. It counts once it clears (usually a few business days); until then the balance can't be collected twice.",
                        kind: .info
                    )
                }
                if invoice.status == .draft {
                    InlineMessage(text: "Send the invoice to issue it before collecting payment.", kind: .info)
                }
            }
            if permissions.canCollect && invoice.canCollect {
                collectButtons
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private var collectButtons: some View {
        Button {
            present(.collectCard)
        } label: {
            Label("Collect card payment", systemImage: "creditcard")
        }
        .buttonStyle(.themeMoney)
        if permissions.canUseSavedCards && !data.savedCards.isEmpty {
            Button {
                present(.chargeSavedCard)
            } label: {
                Label("Charge card on file", systemImage: "creditcard.and.123")
            }
            .buttonStyle(.themeSecondary)
        }
        Button {
            present(.redeemGiftCard)
        } label: {
            Label(permissions.canManage ? "Gift card or store credit" : "Gift card", systemImage: "giftcard")
        }
        .buttonStyle(.themeSecondary)
        Button {
            present(.recordManual)
        } label: {
            Label("Record cash, check or other", systemImage: "banknote")
        }
        .buttonStyle(.themeSecondary)
    }

    private var processingCents: Int {
        InvoiceService.processingCents(data.payments)
    }

    private var balanceTitle: String {
        switch data.invoice.status {
        case .paid: return "Paid in full"
        case .void: return "Void"
        case .draft: return "Balance (not issued yet)"
        case .open, .partiallyPaid: return "Balance due"
        }
    }

    private var hasPendingPayment: Bool {
        data.payments.contains { $0.status == .pending }
    }
}

private struct InvoiceTotalsSection: View {
    let invoice: Invoice
    let currencyCode: String

    var body: some View {
        MoneySectionCard("Totals") {
            MoneyTotalsView(
                subtotalCents: invoice.subtotalCents,
                discountCents: invoice.discountCents,
                taxCents: invoice.taxCents,
                taxRateBps: invoice.taxRateBps,
                totalCents: invoice.totalCents,
                currencyCode: currencyCode
            )
            MoneyAmountRow(label: "Paid", cents: invoice.amountPaidCents, currencyCode: currencyCode)
            if invoice.tipCents > 0 {
                MoneyAmountRow(label: "Tips (not part of the balance)", cents: invoice.tipCents, currencyCode: currencyCode, emphasis: .secondary)
            }
            MoneyAmountRow(
                label: "Balance",
                cents: invoice.balanceCents,
                currencyCode: currencyCode,
                emphasis: invoice.canCollect ? .attention : .normal,
                isStrong: true
            )
        }
    }
}

private struct InvoicePaymentsSection: View {
    let payments: [Payment]
    let canRefund: Bool
    let currencyCode: String
    let clock: ShopClock
    let onRefund: (Payment) -> Void

    var body: some View {
        MoneySectionCard("Payments") {
            if payments.isEmpty {
                Text("No payments yet.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(payments) { payment in
                    InvoicePaymentRow(
                        payment: payment,
                        canRefund: canRefund,
                        currencyCode: currencyCode,
                        clock: clock,
                        onRefund: { onRefund(payment) }
                    )
                    if payment.id != payments.last?.id {
                        Divider().overlay(Theme.border)
                    }
                }
            }
        }
    }
}

struct InvoicePaymentRow: View {
    let payment: Payment
    let canRefund: Bool
    let currencyCode: String
    let clock: ShopClock
    let onRefund: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(payment.methodLabel)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    if let note = payment.note?.trimmedNonEmpty {
                        Text(note)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let processing = payment.processingNote {
                        Text(processing)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Spacing.sm)
                VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                    MoneyText(cents: payment.amountCents, currencyCode: currencyCode)
                    if payment.tipCents > 0 {
                        Text("+ \(Money.format(cents: payment.tipCents, currencyCode: currencyCode)) tip")
                            .font(Theme.Typography.moneySmall)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if payment.refundedCents > 0 {
                        Text("− \(Money.format(cents: payment.refundedCents, currencyCode: currencyCode)) refunded")
                            .font(Theme.Typography.moneySmall)
                            .foregroundStyle(Theme.danger)
                    }
                    StatusBadge(payment.status)
                }
            }
            if canRefund && payment.isRefundable {
                Button("Refund…", action: onRefund)
                    .buttonStyle(.themeSecondaryCompact)
                    .accessibilityLabel("Refund \(payment.methodLabel) payment")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var subtitle: String {
        var parts: [String] = []
        if payment.kind != .payment { parts.append(payment.kind.displayName) }
        parts.append(clock.dateTimeText(payment.displayDate))
        return parts.joined(separator: " · ")
    }
}

private struct InvoiceManageSection: View {
    let invoice: Invoice
    /// The customer's pay-link token; loaded for managers+ only.
    let linkToken: UUID?
    let permissions: InvoicePermissions
    let present: (InvoiceDetailSheet) -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if permissions.canManage || (permissions.canCollect && invoice.status != .draft) {
                MoneyPDFShareButton(kind: .invoice, documentID: invoice.id, number: invoice.number)
            }
            if permissions.canManage && invoice.status != .void {
                Button {
                    present(.send)
                } label: {
                    Label(invoice.sentAt == nil ? "Send invoice" : "Resend invoice", systemImage: "paperplane")
                }
                .buttonStyle(.themePrimary)
            }
            if permissions.canManage, let linkToken, invoice.status != .draft && invoice.status != .void {
                if let url = MoneyLinks.invoice(token: linkToken) {
                    ShareLink(item: url) {
                        Label("Share pay link", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.themeSecondary)
                } else {
                    InlineMessage(text: "Pay links need WEB_APP_URL in the app configuration.", kind: .info)
                }
            }
            if permissions.canVoid && invoice.status != .void {
                Button(role: .destructive) {
                    present(.void)
                } label: {
                    Text("Void invoice")
                        .foregroundStyle(Theme.danger)
                }
                .buttonStyle(.themePlain)
            }
        }
    }
}

private struct InvoiceNotesSection: View {
    let invoice: Invoice
    let showInternal: Bool

    var body: some View {
        let notes = invoice.notes?.trimmedNonEmpty
        let terms = invoice.terms?.trimmedNonEmpty
        let internalNotes = showInternal ? invoice.internalNotes?.trimmedNonEmpty : nil
        if notes != nil || terms != nil || internalNotes != nil {
            MoneySectionCard("Notes & terms") {
                if let notes {
                    MoneyTextBlock(title: "Notes for the customer", text: notes)
                }
                if let terms {
                    MoneyTextBlock(title: "Terms", text: terms)
                }
                if let internalNotes {
                    MoneyTextBlock(title: "Internal notes (staff only)", text: internalNotes)
                }
            }
        }
    }
}
