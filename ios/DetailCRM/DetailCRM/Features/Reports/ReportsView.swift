//
//  ReportsView.swift
//  DetailCRM
//
//  Reports for a shop-timezone date range. Owners, admins and managers
//  see revenue (chart + table), payments by method, sales by service,
//  team, outstanding invoices (aging) and customers. Technicians see only
//  their own team row (hours, jobs, commission) — the server returns
//  nothing else to them.
//
//  Every amount comes from the report RPCs; the app only formats them.
//  Each card loads independently so one failure doesn't hide the rest.
//

import SwiftUI
import DetailCore

/// Per-card load states for one range.
struct ReportsSnapshot {
    var revenue: LoadState<[ReportRevenueRow]> = .idle
    var payments: LoadState<[ReportPaymentRow]> = .idle
    var services: LoadState<[ReportServiceRow]> = .idle
    var team: LoadState<[ReportTeamRow]> = .idle
    var outstanding: LoadState<ReportOutstanding> = .idle
    var customers: LoadState<ReportCustomers> = .idle
}

enum ReportsLoader {

    /// Loads every card the caller may see, in parallel.
    static func load(shopID: UUID, range: ReportDateRange, clock: ShopClock, includeShopReports: Bool) async -> ReportsSnapshot {
        let from = range.fromString(clock)
        let to = range.toString(clock)
        let bucket = range.bucket(clock)
        var snapshot = ReportsSnapshot()
        if includeShopReports {
            async let revenue = LoadState<[ReportRevenueRow]>.result {
                try await ReportService.revenue(shopID: shopID, from: from, to: to, bucket: bucket)
            }
            async let payments = LoadState<[ReportPaymentRow]>.result {
                try await ReportService.payments(shopID: shopID, from: from, to: to)
            }
            async let services = LoadState<[ReportServiceRow]>.result {
                try await ReportService.salesByService(shopID: shopID, from: from, to: to)
            }
            async let team = LoadState<[ReportTeamRow]>.result {
                try await ReportService.team(shopID: shopID, from: from, to: to)
            }
            async let outstanding = LoadState<ReportOutstanding>.result {
                try await ReportService.outstanding(shopID: shopID)
            }
            async let customers = LoadState<ReportCustomers>.result {
                try await ReportService.customers(shopID: shopID, from: from, to: to)
            }
            snapshot.revenue = await revenue
            snapshot.payments = await payments
            snapshot.services = await services
            snapshot.team = await team
            snapshot.outstanding = await outstanding
            snapshot.customers = await customers
        } else {
            snapshot.team = await LoadState<[ReportTeamRow]>.result {
                try await ReportService.team(shopID: shopID, from: from, to: to)
            }
        }
        return snapshot
    }
}

struct ReportsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var preset: ReportRangePreset = .thisMonth
    @State private var snapshot = ReportsSnapshot()
    @State private var loadedRange: ReportDateRange?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                ReportsRangeHeader(preset: $preset, range: currentRange, clock: appState.clock)
                cards
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.vertical, Theme.Spacing.lg)
        }
        .screenBackground()
        .navigationTitle("Reports")
        .task(id: preset) { await load() }
        .refreshable { await load() }
    }

    private var includeShopReports: Bool { appState.can(.viewAllReports) }

    private var currentRange: ReportDateRange {
        preset.range(clock: appState.clock)
    }

    /// Cards behind AnyView seams (keeps the composed view type shallow).
    @ViewBuilder
    private var cards: some View {
        let clock = appState.clock
        let currency = appState.currencyCode
        let range = loadedRange ?? currentRange
        if includeShopReports {
            AnyView(ReportsRevenueCard(state: snapshot.revenue, range: range, clock: clock, currencyCode: currency, retry: { await load() }))
            AnyView(ReportsPaymentsCard(state: snapshot.payments, currencyCode: currency, retry: { await load() }))
            AnyView(ReportsServicesCard(state: snapshot.services, currencyCode: currency, retry: { await load() }))
            AnyView(ReportsTeamCard(state: snapshot.team, currencyCode: currency, ownOnly: false, retry: { await load() }))
            AnyView(ReportsOutstandingCard(state: snapshot.outstanding, clock: clock, currencyCode: currency, retry: { await load() }))
            AnyView(ReportsCustomersCard(state: snapshot.customers, clock: clock, currencyCode: currency, retry: { await load() }))
        } else {
            AnyView(ReportsTeamCard(state: snapshot.team, currencyCode: currency, ownOnly: true, retry: { await load() }))
        }
    }

    private func load() async {
        guard let shopID = appState.shop?.id else {
            snapshot.team = .failed(AppError.noShopSelected.errorDescription ?? "Choose a shop first.")
            return
        }
        let clock = appState.clock
        let range = preset.range(clock: clock)
        let rangeChanged = loadedRange != range
        var next = rangeChanged ? ReportsSnapshot() : snapshot
        // Show spinners for a new range; keep content while refreshing.
        if rangeChanged {
            next.revenue = .loading
            next.payments = .loading
            next.services = .loading
            next.team = .loading
            next.outstanding = .loading
            next.customers = .loading
            snapshot = next
        }
        let fresh = await ReportsLoader.load(shopID: shopID, range: range, clock: clock, includeShopReports: includeShopReports)
        if Task.isCancelled { return }
        var merged = rangeChanged ? ReportsSnapshot() : snapshot
        merged.revenue.apply(fresh.revenue)
        merged.payments.apply(fresh.payments)
        merged.services.apply(fresh.services)
        merged.team.apply(fresh.team)
        merged.outstanding.apply(fresh.outstanding)
        merged.customers.apply(fresh.customers)
        if !rangeChanged, let message = firstError(fresh) {
            toasts.show(message, style: .error)
        }
        snapshot = merged
        loadedRange = range
    }

    private func firstError(_ fresh: ReportsSnapshot) -> String? {
        fresh.revenue.errorMessage ?? fresh.payments.errorMessage ?? fresh.services.errorMessage
            ?? fresh.team.errorMessage ?? fresh.outstanding.errorMessage ?? fresh.customers.errorMessage
    }
}

/// Range picker + the resolved dates in the shop time zone.
private struct ReportsRangeHeader: View {
    @Binding var preset: ReportRangePreset
    let range: ReportDateRange
    let clock: ShopClock

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Picker("Date range", selection: $preset) {
                ForEach(ReportRangePreset.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Date range")
            Text(range.label(clock))
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Text("Dates follow the shop's time zone (\(clock.timeZone.identifier)).")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

// MARK: - Shared card chrome

/// Title + load-state handling for a report card.
struct ReportsCard<Value, Content: View>: View {
    let title: String
    let subtitle: String?
    let state: LoadState<Value>
    let retry: () async -> Void
    let content: (Value) -> Content

    init(
        _ title: String,
        subtitle: String? = nil,
        state: LoadState<Value>,
        retry: @escaping () async -> Void,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.retry = retry
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: title)
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                stateBody
            }
            .cardStyle()
        }
    }

    @ViewBuilder
    private var stateBody: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                Text("Loading…")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                InlineMessage(text: message, kind: .error)
                AsyncButton("Try again", style: .themeSecondaryCompact) {
                    await retry()
                }
            }
        case .loaded(let value):
            content(value)
        }
    }
}

/// Small "label … value" line used inside report cards.
struct ReportsMetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.Spacing.sm)
            Text(value)
                .font(Theme.Typography.subheadline.monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "label … $1,234.00" line (server cents).
struct ReportsMoneyRow: View {
    let label: String
    let cents: Int
    let currencyCode: String
    var emphasis: MoneyText.Emphasis = .normal

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.Spacing.sm)
            MoneyText(cents: cents, currencyCode: currencyCode, size: .small, emphasis: emphasis)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Empty message inside a card.
struct ReportsEmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typography.subheadline)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum ReportsFormatting {

    /// Label of a revenue bucket in the shop time zone.
    static func bucketLabel(_ bucketStart: String, bucket: ReportBucket, clock: ShopClock) -> String {
        guard let date = clock.date(fromDateString: bucketStart) else { return bucketStart }
        switch bucket {
        case .day:
            return clock.shortDayText(date)
        case .week:
            return "Week of \(clock.shortDayText(date))"
        case .month:
            let formatter = DateFormatter()
            formatter.locale = clock.locale
            formatter.timeZone = clock.timeZone
            formatter.setLocalizedDateFormatFromTemplate("MMMyyyy")
            return formatter.string(from: date)
        }
    }

    /// Short axis label for a bucket ("9/3", "Sep").
    static func axisLabel(_ bucketStart: String, bucket: ReportBucket, clock: ShopClock) -> String {
        guard let date = clock.date(fromDateString: bucketStart) else { return bucketStart }
        let formatter = DateFormatter()
        formatter.locale = clock.locale
        formatter.timeZone = clock.timeZone
        formatter.setLocalizedDateFormatFromTemplate(bucket == .month ? "MMM" : "Md")
        return formatter.string(from: date)
    }

    /// "12.5 h".
    static func hours(_ value: Double) -> String {
        String(format: "%.1f h", value)
    }

    /// "12.5%" from basis points.
    static func percent(bps: Int) -> String {
        ShopSettingsPercent.display(bps)
    }
}
