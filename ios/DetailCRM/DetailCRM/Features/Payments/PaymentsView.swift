//
//  PaymentsView.swift
//  DetailCRM
//
//  Payments ledger (owner/admin/manager): received payments in a date
//  range (shop time zone) with a method filter, and the server's totals
//  for the same range (`report_payments`: collected, net, tips, refunds).
//  Bank debits and pay-later payments still clearing (`processing`) are
//  listed on their own: they count once Stripe confirms them.
//
//  Each row says what the money pays: an invoice or job (tap to open), a
//  membership, or nothing yet ("Unapplied": money kept on the customer,
//  with the server's note on why). Managers and above can put unapplied
//  money on one of the customer's open invoices ("Apply to invoice…");
//  owners and admins can refund any received payment, membership and
//  unapplied ones included ("Refund…"). "Unapplied only" matches the web
//  ledger's `?unapplied=1`.
//

import SwiftUI
import DetailCore

/// Date ranges for the ledger, resolved in the shop's time zone.
enum PaymentsRangePreset: String, CaseIterable, Identifiable, Hashable {
    case today
    case thisWeek
    case thisMonth
    case last30Days
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .thisWeek: return "This week"
        case .thisMonth: return "This month"
        case .last30Days: return "Last 30 days"
        case .custom: return "Custom"
        }
    }
}

/// A resolved [start, end) range plus its inclusive shop-local days.
struct PaymentsLedgerRange: Hashable {
    var start: Date
    var end: Date
    var fromDay: String
    var toDay: String

    static func resolve(
        _ preset: PaymentsRangePreset,
        customFrom: Date,
        customTo: Date,
        clock: ShopClock,
        now: Date = Date()
    ) -> PaymentsLedgerRange {
        let interval: DateInterval
        switch preset {
        case .today:
            interval = clock.dayInterval(containing: now)
        case .thisWeek:
            interval = clock.totalsWeekInterval(containing: now)
        case .thisMonth:
            interval = clock.monthInterval(containing: now)
        case .last30Days:
            let end = clock.addingDays(1, to: clock.startOfDay(now))
            interval = DateInterval(start: clock.addingDays(-30, to: end), end: end)
        case .custom:
            let from = clock.startOfDay(min(customFrom, customTo))
            let to = clock.addingDays(1, to: clock.startOfDay(max(customFrom, customTo)))
            interval = DateInterval(start: from, end: to)
        }
        let lastDay = clock.addingDays(-1, to: interval.end)
        return PaymentsLedgerRange(
            start: interval.start,
            end: interval.end,
            fromDay: clock.dateString(interval.start),
            toDay: clock.dateString(max(lastDay, interval.start))
        )
    }
}

struct PaymentsQueryKey: Hashable {
    var range: PaymentsLedgerRange
    var method: PaymentMethod?
    var unappliedOnly = false
}

/// Row actions of the ledger.
enum PaymentsSheet: Identifiable {
    case apply(Payment)
    case refund(Payment)

    var id: String {
        switch self {
        case .apply(let payment): return "apply-" + payment.id.uuidString
        case .refund(let payment): return "refund-" + payment.id.uuidString
        }
    }
}

struct PaymentsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var state: LoadState<PaymentService.LedgerData> = .idle
    @State private var preset: PaymentsRangePreset = .thisMonth
    @State private var customFrom = Date()
    @State private var customTo = Date()
    @State private var method: PaymentMethod?
    @State private var unappliedOnly = false
    @State private var sheet: PaymentsSheet?

    var body: some View {
        Group {
            if appState.can(.managePayments) {
                ledgerScreen
            } else {
                EmptyStateView(
                    systemImage: "lock",
                    title: "Payments aren't available",
                    message: "Owners, admins and managers can see the payments ledger."
                )
            }
        }
        .screenBackground()
        .navigationTitle("Payments")
        .sheet(item: $sheet) { item in
            sheetContent(item)
        }
    }

    @ViewBuilder
    private func sheetContent(_ item: PaymentsSheet) -> some View {
        switch item {
        case .apply(let payment):
            PaymentApplySheet(payment: payment, customerName: customerName(payment)) {
                await load()
            }
        case .refund(let payment):
            InvoiceRefundSheet(payment: payment) {
                await load()
            }
        }
    }

    private func customerName(_ payment: Payment) -> String {
        state.value?.customers[payment.customerID]?.displayName ?? "Customer"
    }

    private var queryKey: PaymentsQueryKey {
        PaymentsQueryKey(range: range, method: method, unappliedOnly: unappliedOnly)
    }

    private var range: PaymentsLedgerRange {
        PaymentsLedgerRange.resolve(preset, customFrom: customFrom, customTo: customTo, clock: appState.clock)
    }

    private var ledgerScreen: some View {
        VStack(spacing: 0) {
            PaymentsFilterBar(
                preset: $preset,
                customFrom: $customFrom,
                customTo: $customTo,
                method: $method,
                unappliedOnly: $unappliedOnly,
                timeZone: appState.clock.timeZone
            )
            LoadStateView(state, loadingLabel: "Loading payments…", retry: { await load() }) { data in
                PaymentsLedgerContent(
                    data: data,
                    rangeText: rangeText,
                    currencyCode: appState.currencyCode,
                    clock: appState.clock,
                    unappliedOnly: unappliedOnly,
                    actions: PaymentsRowActions(
                        canApply: appState.can(.manageInvoices),
                        canRefund: appState.can(.refundPayments),
                        apply: { payment in sheet = .apply(payment) },
                        refund: { payment in sheet = .refund(payment) }
                    ),
                    onLoadMore: { await loadMore() }
                )
            }
        }
        .refreshable { await load() }
        .task(id: queryKey) {
            await load()
        }
    }

    private var rangeText: String {
        let clock = appState.clock
        let current = range
        let lastDay = clock.addingDays(-1, to: current.end)
        if clock.isSameDay(current.start, lastDay) {
            return clock.shortDayText(current.start)
        }
        return "\(clock.shortDayText(current.start)) – \(clock.shortDayText(lastDay))"
    }

    private func load() async {
        guard let shopID = try? appState.requireShopID() else { return }
        state.beginLoading()
        let current = range
        let selectedMethod = method
        let onlyUnapplied = unappliedOnly
        let result = await LoadState<PaymentService.LedgerData>.result {
            try await PaymentService.ledger(
                shopID: shopID,
                start: current.start,
                end: current.end,
                fromDay: current.fromDay,
                toDay: current.toDay,
                method: selectedMethod,
                unappliedOnly: onlyUnapplied
            )
        }
        if let message = result.errorMessage, state.value != nil {
            toasts.show(message, style: .error)
        }
        state.apply(result)
    }

    /// Appends the next page of older payments in the same range.
    private func loadMore() async {
        guard let shopID = try? appState.requireShopID(), let current = state.value, current.hasMore else { return }
        let key = queryKey
        do {
            let page = try await PaymentService.ledgerPage(
                shopID: shopID,
                start: key.range.start,
                end: key.range.end,
                method: key.method,
                unappliedOnly: key.unappliedOnly,
                offset: current.payments.count
            )
            // Ignore a page for a range or filter that changed meanwhile.
            guard key == queryKey, let latest = state.value else { return }
            state = .loaded(latest.appending(page))
        } catch {
            toasts.show(ErrorText.message(for: error), style: .error)
        }
    }
}

// MARK: - Filters

private struct PaymentsFilterBar: View {
    @Binding var preset: PaymentsRangePreset
    @Binding var customFrom: Date
    @Binding var customTo: Date
    @Binding var method: PaymentMethod?
    @Binding var unappliedOnly: Bool
    let timeZone: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(PaymentsRangePreset.allCases) { option in
                        MoneyFilterChip(title: option.title, isSelected: preset == option) {
                            preset = option
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.xxs)
            }
            if preset == .custom {
                HStack(spacing: Theme.Spacing.md) {
                    DatePicker("From", selection: $customFrom, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityLabel("From")
                    Text("to")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    DatePicker("To", selection: $customTo, displayedComponents: .date)
                        .labelsHidden()
                        .accessibilityLabel("To")
                    Spacer(minLength: 0)
                }
                .environment(\.timeZone, timeZone)
            }
            // Side by side when they fit; stacked at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.md) {
                    methodMenu
                    Spacer(minLength: 0)
                    unappliedChip
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    methodMenu
                    unappliedChip
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.background)
    }

    private var unappliedChip: some View {
        MoneyFilterChip(title: "Unapplied only", isSelected: unappliedOnly) {
            unappliedOnly.toggle()
        }
        .accessibilityHint("Shows only received money that pays no invoice, job or membership")
    }

    private var methodMenu: some View {
        Menu {
            Button("All methods") { method = nil }
            ForEach(PaymentMethod.allCases, id: \.self) { option in
                Button(option.displayName) { method = option }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .accessibilityHidden(true)
                Text(method?.displayName ?? "All methods")
                    .font(Theme.Typography.subheadline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(Theme.Typography.caption)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.glacier)
        }
        .accessibilityLabel("Payment method: \(method?.displayName ?? "All methods")")
    }
}

/// Who may do what on a ledger row, and how the screen opens it.
struct PaymentsRowActions {
    /// Managers+: put unapplied money on an invoice.
    var canApply = false
    /// Owners/admins: refund received money.
    var canRefund = false
    var apply: (Payment) -> Void = { _ in }
    var refund: (Payment) -> Void = { _ in }
}

// MARK: - Content

private struct PaymentsLedgerContent: View {
    let data: PaymentService.LedgerData
    let rangeText: String
    let currencyCode: String
    let clock: ShopClock
    let unappliedOnly: Bool
    let actions: PaymentsRowActions
    let onLoadMore: () async -> Void

    var body: some View {
        List {
            Section {
                PaymentsSummaryCard(summary: data.summary, rangeText: rangeText, currencyCode: currencyCode)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if !data.processing.isEmpty {
                Section {
                    ForEach(data.processing) { payment in
                        row(payment)
                    }
                } header: {
                    Text("Still clearing")
                } footer: {
                    Text("Bank debits and pay-later payments take a few business days. They count toward invoices and these totals once Stripe confirms them; a bank can still return one.")
                }
            }
            Section {
                if data.payments.isEmpty {
                    Text(unappliedOnly ? "No unapplied money in this range." : "No payments received in this range.")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .themedRow()
                } else {
                    ForEach(data.payments) { payment in
                        row(payment)
                    }
                    if data.hasMore {
                        MoneyLoadMoreRow(shownCount: data.payments.count, noun: "payments", action: onLoadMore)
                            .themedRow()
                    }
                }
            } header: {
                Text(unappliedOnly ? "Unapplied money" : "Received")
            } footer: {
                Text(unappliedOnly
                     ? "Received money that pays no invoice, job or membership. Apply it to one of the customer's invoices or refund it. The totals above cover every payment in the range."
                     : "Pending and failed card attempts show on each invoice. Refunds are counted against the payment they came from.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func row(_ payment: Payment) -> some View {
        PaymentsLedgerRow(
            payment: payment,
            customerName: data.customers[payment.customerID]?.displayName ?? "Customer",
            currencyCode: currencyCode,
            clock: clock,
            actions: actions
        )
        .themedRow()
    }
}

private struct PaymentsSummaryCard: View {
    let summary: PaymentsLedgerSummary
    let rangeText: String
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Collected · \(rangeText)")
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                MoneyText(cents: summary.collectedCents, currencyCode: currencyCode, size: .large, emphasis: .attention)
                Text("\(summary.count) payment\(summary.count == 1 ? "" : "s"), net of refunds, tips included")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            Divider().overlay(Theme.border)
            MoneyAmountRow(label: "Payments (net)", cents: summary.netCents, currencyCode: currencyCode)
            MoneyAmountRow(label: "Tips (net)", cents: summary.tipsCents, currencyCode: currencyCode)
            MoneyAmountRow(label: "Refunded", cents: summary.refundsCents, currencyCode: currencyCode, emphasis: .secondary)
        }
        .cardStyle()
    }
}

private struct PaymentsLedgerRow: View {
    let payment: Payment
    let customerName: String
    let currencyCode: String
    let clock: ShopClock
    let actions: PaymentsRowActions

    private var showsApply: Bool { actions.canApply && payment.canApplyToInvoice }
    private var showsRefund: Bool { actions.canRefund && payment.isRefundable }

    var body: some View {
        if showsApply || showsRefund {
            // The actions sit under the summary as their own buttons, so the
            // summary is a plain link (a whole-row link would swallow them).
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                linkedSummary
                AdaptiveButtonRow(spacing: Theme.Spacing.sm) {
                    if showsApply {
                        Button {
                            actions.apply(payment)
                        } label: {
                            Label("Apply to invoice…", systemImage: "arrow.right.doc.on.clipboard")
                        }
                        .buttonStyle(.themeSecondaryCompact)
                        .accessibilityLabel("Apply \(Money.format(cents: payment.applicableCents, currencyCode: currencyCode)) from \(customerName) to an invoice")
                    }
                    if showsRefund {
                        Button {
                            actions.refund(payment)
                        } label: {
                            Label("Refund…", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.themeSecondaryCompact)
                        .accessibilityLabel("Refund \(payment.methodLabel) payment of \(Money.format(cents: payment.amountCents, currencyCode: currencyCode)) from \(customerName)")
                    }
                }
            }
        } else {
            rowContent
        }
    }

    /// The whole row opens the invoice or job it pays.
    @ViewBuilder
    private var rowContent: some View {
        switch payment.target {
        case .invoice(let invoiceID):
            NavigationLink(value: AppRoute.invoice(invoiceID)) {
                rowBody
            }
        case .job(let jobID):
            NavigationLink(value: AppRoute.job(jobID)) {
                rowBody
            }
        case .membership, .unapplied:
            rowBody
        }
    }

    /// The summary as its own link above the actions. The List draws the
    /// link's disclosure chevron itself (a chevron of our own made two).
    @ViewBuilder
    private var linkedSummary: some View {
        switch payment.target {
        case .invoice(let invoiceID):
            NavigationLink(value: AppRoute.invoice(invoiceID)) {
                linkBody
            }
            .buttonStyle(.plain)
        case .job(let jobID):
            NavigationLink(value: AppRoute.job(jobID)) {
                linkBody
            }
            .buttonStyle(.plain)
        case .membership, .unapplied:
            rowBody
        }
    }

    private var linkBody: some View {
        rowBody
            .contentShape(Rectangle())
    }

    private var rowBody: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(customerName)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(payment.methodLabel) · \(payment.kind.displayName)")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                Text(clock.dateTimeText(payment.displayDate))
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                targetLine
                if let note = payment.note?.trimmedNonEmpty {
                    Text(note)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(4)
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
                        .foregroundStyle(Theme.dangerInk)
                }
                if payment.status != .succeeded {
                    StatusBadge(payment.status)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    /// Money that pays no invoice, job or membership is flagged; a
    /// membership payment says so (invoice and job rows open theirs).
    @ViewBuilder
    private var targetLine: some View {
        switch payment.target {
        case .unapplied:
            StatusBadge(text: "Unapplied", tone: .warning)
        case .membership:
            Label("Membership", systemImage: "arrow.triangle.2.circlepath")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
        case .invoice, .job:
            EmptyView()
        }
    }
}
