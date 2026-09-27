//
//  PaymentsView.swift
//  DetailCRM
//
//  Payments ledger (owner/admin/manager): received payments in a date
//  range (shop time zone) with a method filter, and the server's totals
//  for the same range (`report_payments`: collected, net, tips, refunds).
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
            interval = clock.weekInterval(containing: now)
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
}

struct PaymentsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var state: LoadState<PaymentService.LedgerData> = .idle
    @State private var preset: PaymentsRangePreset = .thisMonth
    @State private var customFrom = Date()
    @State private var customTo = Date()
    @State private var method: PaymentMethod?

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
                timeZone: appState.clock.timeZone
            )
            LoadStateView(state, loadingLabel: "Loading payments…", retry: { await load() }) { data in
                PaymentsLedgerContent(
                    data: data,
                    rangeText: rangeText,
                    currencyCode: appState.currencyCode,
                    clock: appState.clock,
                    onLoadMore: { await loadMore() }
                )
            }
        }
        .refreshable { await load() }
        .task(id: PaymentsQueryKey(range: range, method: method)) {
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
        let result = await LoadState<PaymentService.LedgerData>.result {
            try await PaymentService.ledger(
                shopID: shopID,
                start: current.start,
                end: current.end,
                fromDay: current.fromDay,
                toDay: current.toDay,
                method: selectedMethod
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
        let key = PaymentsQueryKey(range: range, method: method)
        do {
            let page = try await PaymentService.ledgerPage(
                shopID: shopID,
                start: key.range.start,
                end: key.range.end,
                method: key.method,
                offset: current.payments.count
            )
            // Ignore a page for a range or filter that changed meanwhile.
            guard key == PaymentsQueryKey(range: range, method: method), let latest = state.value else { return }
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
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.background)
    }
}

// MARK: - Content

private struct PaymentsLedgerContent: View {
    let data: PaymentService.LedgerData
    let rangeText: String
    let currencyCode: String
    let clock: ShopClock
    let onLoadMore: () async -> Void

    var body: some View {
        List {
            Section {
                PaymentsSummaryCard(summary: data.summary, rangeText: rangeText, currencyCode: currencyCode)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                if data.payments.isEmpty {
                    Text("No payments received in this range.")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .themedRow()
                } else {
                    ForEach(data.payments) { payment in
                        PaymentsLedgerRow(
                            payment: payment,
                            customerName: data.customers[payment.customerID]?.displayName ?? "Customer",
                            currencyCode: currencyCode,
                            clock: clock
                        )
                        .themedRow()
                    }
                    if data.hasMore {
                        MoneyLoadMoreRow(shownCount: data.payments.count, noun: "payments", action: onLoadMore)
                            .themedRow()
                    }
                }
            } header: {
                Text("Received")
            } footer: {
                Text("Pending and failed card attempts show on each invoice. Refunds are counted against the payment they came from.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
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

    var body: some View {
        rowContent
    }

    @ViewBuilder
    private var rowContent: some View {
        if let invoiceID = payment.invoiceID {
            NavigationLink(value: AppRoute.invoice(invoiceID)) {
                rowBody
            }
        } else if let jobID = payment.jobID {
            NavigationLink(value: AppRoute.job(jobID)) {
                rowBody
            }
        } else {
            rowBody
        }
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
                if payment.status != .succeeded {
                    StatusBadge(payment.status)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}
