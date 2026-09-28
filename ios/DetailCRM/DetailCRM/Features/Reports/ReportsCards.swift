//
//  ReportsCards.swift
//  DetailCRM
//
//  One card per report RPC. Amounts are server cents shown with
//  MoneyText; the chart plots the same server values (major units).
//

import SwiftUI
import Charts
import DetailCore

// MARK: - Revenue

/// One bar of the revenue chart.
struct ReportsRevenuePoint: Identifiable {
    let id: String
    let axisLabel: String
    let amount: Double
}

struct ReportsRevenueCard: View {
    let state: LoadState<[ReportRevenueRow]>
    /// Totals for the whole range from the server (`report_revenue_totals`).
    let totals: LoadState<ReportRevenueTotals>
    let range: ReportDateRange
    let clock: ShopClock
    let currencyCode: String
    let retry: () async -> Void

    var body: some View {
        ReportsCard(
            "Revenue",
            subtitle: "Payments received, net of refunds (tips excluded).",
            state: state,
            retry: retry
        ) { rows in
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ReportsRevenueTotalsView(state: totals, currencyCode: currencyCode)
                ReportsRevenueBody(rows: rows, bucket: range.bucket(clock), clock: clock, currencyCode: currencyCode)
            }
        }
    }
}

/// Net / gross / refunds / tips for the range, as the server totals them.
private struct ReportsRevenueTotalsView: View {
    let state: LoadState<ReportRevenueTotals>
    let currencyCode: String

    var body: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                Text("Loading totals…")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .failed(let message):
            InlineMessage(text: message, kind: .error)
        case .loaded(let totals):
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Net revenue")
                        .font(Theme.Typography.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: Theme.Spacing.sm)
                    MoneyText(cents: totals.netCents, currencyCode: currencyCode, size: .large, emphasis: .attention)
                }
                .accessibilityElement(children: .combine)
                ReportsMoneyRow(label: "Gross", cents: totals.grossCents, currencyCode: currencyCode, emphasis: .secondary)
                if totals.refundsCents != 0 {
                    ReportsMoneyRow(label: "Refunds", cents: totals.refundsCents, currencyCode: currencyCode, emphasis: .secondary)
                }
                if totals.tipsCents != 0 {
                    ReportsMoneyRow(label: "Tips (not in revenue)", cents: totals.tipsCents, currencyCode: currencyCode, emphasis: .secondary)
                }
                ReportsMetricRow(label: "Payments", value: "\(totals.paymentsCount)")
            }
            Divider()
        }
    }
}

private struct ReportsRevenueBody: View {
    let rows: [ReportRevenueRow]
    let bucket: ReportBucket
    let clock: ShopClock
    let currencyCode: String

    var body: some View {
        let active = rows.filter { $0.paymentsCount > 0 || $0.netCents != 0 || $0.refundsCents != 0 || $0.tipsCents != 0 }
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if active.isEmpty {
                ReportsEmptyLine(text: "No payments were received in this period.")
            } else {
                ReportsRevenueChart(points: points, tickKeys: tickKeys)
                Divider()
                ForEach(active) { row in
                    ReportsRevenueRowView(row: row, label: ReportsFormatting.bucketLabel(row.bucketStart, bucket: bucket, clock: clock), currencyCode: currencyCode)
                }
            }
        }
    }

    private var points: [ReportsRevenuePoint] {
        rows.map { row in
            let major = NSDecimalNumber(decimal: Money.decimal(fromCents: row.netCents, currencyCode: currencyCode)).doubleValue
            return ReportsRevenuePoint(
                id: row.bucketStart,
                axisLabel: ReportsFormatting.axisLabel(row.bucketStart, bucket: bucket, clock: clock),
                amount: major
            )
        }
    }

    /// At most ~6 evenly spaced axis labels.
    private var tickKeys: [String] {
        let keys = rows.map(\.bucketStart)
        guard keys.count > 6 else { return keys }
        let step = Int((Double(keys.count) / 6.0).rounded(.up))
        return keys.enumerated().filter { $0.offset % step == 0 }.map(\.element)
    }
}

private struct ReportsRevenueChart: View {
    let points: [ReportsRevenuePoint]
    let tickKeys: [String]

    var body: some View {
        Chart(points) { point in
            BarMark(
                x: .value("Period", point.id),
                y: .value("Net revenue", point.amount)
            )
            .foregroundStyle(Theme.glacier)
        }
        .chartXAxis {
            AxisMarks(values: tickKeys) { value in
                AxisValueLabel {
                    Text(axisText(value.as(String.self)))
                }
            }
        }
        .frame(height: 200)
        .accessibilityLabel("Net revenue chart")
    }

    private func axisText(_ key: String?) -> String {
        guard let key else { return "" }
        return points.first { $0.id == key }?.axisLabel ?? key
    }
}

private struct ReportsRevenueRowView: View {
    let row: ReportRevenueRow
    let label: String
    let currencyCode: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(label)
                    .font(Theme.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            MoneyText(cents: row.netCents, currencyCode: currencyCode, size: .small)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts = ["\(row.paymentsCount) payment\(row.paymentsCount == 1 ? "" : "s")"]
        if row.refundsCents != 0 {
            parts.append("refunds \(Money.format(cents: row.refundsCents, currencyCode: currencyCode))")
        }
        if row.tipsCents != 0 {
            parts.append("tips \(Money.format(cents: row.tipsCents, currencyCode: currencyCode))")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Payments by method

struct ReportsPaymentsCard: View {
    let state: LoadState<[ReportPaymentRow]>
    let currencyCode: String
    let retry: () async -> Void

    var body: some View {
        ReportsCard("Payments by method", state: state, retry: retry) { rows in
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if rows.isEmpty {
                    ReportsEmptyLine(text: "No payments in this period.")
                } else {
                    ForEach(rows) { row in
                        ReportsPaymentRowView(row: row, currencyCode: currencyCode)
                    }
                }
            }
        }
    }
}

private struct ReportsPaymentRowView: View {
    let row: ReportPaymentRow
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.methodName)
                    .font(Theme.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("· \(row.paymentsCount)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: Theme.Spacing.sm)
                MoneyText(cents: row.netCents, currencyCode: currencyCode, size: .small)
            }
            if row.refundsCents != 0 {
                ReportsMoneyRow(label: "Refunds", cents: row.refundsCents, currencyCode: currencyCode, emphasis: .secondary)
            }
            if row.tipsCents != 0 {
                ReportsMoneyRow(label: "Tips", cents: row.tipsCents, currencyCode: currencyCode, emphasis: .secondary)
            }
            if row.depositsCents != 0 {
                ReportsMoneyRow(label: "Deposits", cents: row.depositsCents, currencyCode: currencyCode, emphasis: .secondary)
            }
            if row.membershipsCents != 0 {
                ReportsMoneyRow(label: "Memberships", cents: row.membershipsCents, currencyCode: currencyCode, emphasis: .secondary)
            }
            if row.disputesLostCents > 0 {
                ReportsMoneyRow(label: "Lost disputes", cents: row.disputesLostCents, currencyCode: currencyCode, emphasis: .secondary)
            }
        }
    }
}

// MARK: - Sales by service

struct ReportsServicesCard: View {
    let state: LoadState<[ReportServiceRow]>
    let currencyCode: String
    let retry: () async -> Void

    var body: some View {
        ReportsCard(
            "Sales by service",
            subtitle: "Completed jobs in this period, before tax.",
            state: state,
            retry: retry
        ) { rows in
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if rows.isEmpty {
                    ReportsEmptyLine(text: "No completed jobs in this period.")
                } else {
                    ForEach(rows) { row in
                        ReportsServiceRowView(row: row, currencyCode: currencyCode)
                    }
                }
            }
        }
    }
}

private struct ReportsServiceRowView: View {
    let row: ReportServiceRow
    let currencyCode: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(row.serviceName)
                    .font(Theme.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            MoneyText(cents: row.netCents, currencyCode: currencyCode, size: .small)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts: [String] = []
        if let category = row.categoryName, !category.isEmpty { parts.append(category) }
        parts.append("Qty \(row.quantityText)")
        parts.append("\(row.jobsCount) job\(row.jobsCount == 1 ? "" : "s")")
        if row.discountCents != 0 {
            parts.append("discounts \(Money.format(cents: row.discountCents, currencyCode: currencyCode))")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Team

struct ReportsTeamCard: View {
    let state: LoadState<[ReportTeamRow]>
    let currencyCode: String
    let ownOnly: Bool
    /// The report range (for the per-job earnings drill-down).
    let range: ReportDateRange
    /// Owners / admins open any member's earnings by job (P-12).
    let canOpenEarnings: Bool
    let retry: () async -> Void

    var body: some View {
        ReportsCard(
            ownOnly ? "My work" : "Team",
            subtitle: ownOnly
                ? "Your hours, completed jobs and commission for this period."
                : "Hours from the time clock; revenue from completed jobs (before tax).",
            state: state,
            retry: retry
        ) { rows in
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if rows.isEmpty {
                    ReportsEmptyLine(text: "No team activity in this period.")
                } else {
                    ForEach(rows) { row in
                        ReportsTeamRowView(row: row, currencyCode: currencyCode, range: range, canOpenEarnings: canOpenEarnings)
                    }
                }
            }
        }
    }
}

private struct ReportsTeamRowView: View {
    let row: ReportTeamRow
    let currencyCode: String
    let range: ReportDateRange
    let canOpenEarnings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.displayName)
                    .font(Theme.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(row.active ? Theme.textPrimary : Theme.textSecondary)
                StatusBadge(row.role)
                Spacer(minLength: Theme.Spacing.sm)
            }
            ReportsMetricRow(label: "Hours worked", value: ReportsFormatting.hours(row.hours))
            ReportsMetricRow(label: "Jobs completed", value: "\(row.jobsCompleted)")
            ReportsMoneyRow(label: "Revenue (before tax)", cents: row.preTaxRevenueCents, currencyCode: currencyCode)
            if let rate = row.hourlyRateCents {
                ReportsMoneyRow(label: "Hourly rate", cents: rate, currencyCode: currencyCode, emphasis: .secondary)
            }
            if let bps = row.commissionBps {
                ReportsMetricRow(label: "Commission rate", value: ReportsFormatting.percent(bps: bps))
            }
            if let commission = row.commissionCents {
                ReportsMoneyRow(label: "Commission", cents: commission, currencyCode: currencyCode)
            }
            if let labor = row.laborCostCents {
                ReportsMoneyRow(label: "Labor cost", cents: labor, currencyCode: currencyCode)
            }
            if let service = row.serviceCommissionCents {
                ReportsMoneyRow(label: "Service commission", cents: service, currencyCode: currencyCode)
            }
            if let sales = row.salesCommissionCents {
                ReportsMoneyRow(label: "Sales commission", cents: sales, currencyCode: currencyCode)
            }
            if let tips = row.tipsCents {
                ReportsMoneyRow(label: "Tips", cents: tips, currencyCode: currencyCode)
            }
            if let total = row.totalEarningsCents {
                ReportsMoneyRow(label: "Total earnings", cents: total, currencyCode: currencyCode)
            }
            if canOpenEarnings {
                NavigationLink {
                    OpsEarningsCard.JobsList(memberID: row.memberID, memberName: row.displayName, range: range)
                } label: {
                    HStack {
                        Text("Earnings by job")
                            .font(Theme.Typography.footnote.weight(.semibold))
                            .foregroundStyle(Theme.glacier)
                        Spacer(minLength: Theme.Spacing.sm)
                        Image(systemName: "chevron.right")
                            .font(Theme.Typography.caption.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: Theme.Size.compactControlHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Earnings by job for \(row.displayName)")
            }
        }
    }
}

// MARK: - Outstanding

struct ReportsOutstandingCard: View {
    let state: LoadState<ReportOutstanding>
    let clock: ShopClock
    let currencyCode: String
    let retry: () async -> Void

    var body: some View {
        ReportsCard(
            "Outstanding invoices",
            subtitle: "Open balances as of now, by days past due.",
            state: state,
            retry: retry
        ) { report in
            ReportsOutstandingBody(report: report, clock: clock, currencyCode: currencyCode)
        }
    }
}

private struct ReportsOutstandingBody: View {
    let report: ReportOutstanding
    let clock: ShopClock
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if report.count == 0 {
                ReportsEmptyLine(text: "No unpaid invoices. Nice.")
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(report.count) open invoice\(report.count == 1 ? "" : "s")")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: Theme.Spacing.sm)
                    MoneyText(cents: report.balanceCents, currencyCode: currencyCode, size: .regular, emphasis: .attention)
                }
                if report.overdueCount > 0 {
                    ReportsMoneyRow(label: "Overdue (\(report.overdueCount))", cents: report.overdueBalanceCents, currencyCode: currencyCode, emphasis: .attention)
                }
                Divider()
                ForEach(report.buckets) { bucket in
                    ReportsMoneyRow(label: "\(bucket.title) · \(bucket.count)", cents: bucket.balanceCents, currencyCode: currencyCode)
                }
                Divider()
                ForEach(Array(report.invoices.prefix(10))) { invoice in
                    NavigationLink(value: AppRoute.invoice(invoice.invoiceID)) {
                        ReportsOutstandingInvoiceRow(invoice: invoice, clock: clock, currencyCode: currencyCode)
                    }
                    .buttonStyle(.plain)
                }
                if report.invoices.count > 10 {
                    Text("Showing the 10 most overdue of \(report.invoices.count).")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}

private struct ReportsOutstandingInvoiceRow: View {
    let invoice: ReportOutstandingInvoice
    let clock: ShopClock
    let currencyCode: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .font(Theme.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(invoice.overdue ? Theme.warning : Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            MoneyText(cents: invoice.balanceCents, currencyCode: currencyCode, size: .small, emphasis: .attention)
            Image(systemName: "chevron.right")
                .font(Theme.Typography.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        let number = invoice.number.map { "#\($0)" } ?? "Invoice"
        if let name = invoice.customerName, !name.isEmpty { return "\(number) · \(name)" }
        return number
    }

    private var detail: String {
        if invoice.overdue {
            return "\(invoice.daysPastDue) day\(invoice.daysPastDue == 1 ? "" : "s") past due"
        }
        if let due = invoice.dueAt {
            return "Due \(clock.shortDayText(due))"
        }
        return "Open"
    }
}

// MARK: - Customers

struct ReportsCustomersCard: View {
    let state: LoadState<ReportCustomers>
    let clock: ShopClock
    let currencyCode: String
    let retry: () async -> Void

    var body: some View {
        ReportsCard(
            "Customers",
            subtitle: "Customers served by completed jobs in this period.",
            state: state,
            retry: retry
        ) { report in
            ReportsCustomersBody(report: report, clock: clock, currencyCode: currencyCode)
        }
    }
}

private struct ReportsCustomersBody: View {
    let report: ReportCustomers
    let clock: ShopClock
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ReportsMetricRow(label: "Customers served", value: "\(report.customersServed)")
            ReportsMetricRow(label: "New", value: "\(report.newCustomers)")
            ReportsMetricRow(label: "Returning", value: "\(report.returningCustomers)")
            ReportsMetricRow(label: "Customers added", value: "\(report.customersCreated)")
            ReportsMetricRow(label: "Completed jobs", value: "\(report.completedJobs)")
            if let average = report.averageTicketCents {
                ReportsMoneyRow(label: "Average ticket", cents: average, currencyCode: currencyCode)
            } else {
                ReportsMetricRow(label: "Average ticket", value: "—")
            }
            if !report.topCustomers.isEmpty {
                Divider()
                Text("TOP CUSTOMERS (LIFETIME)")
                    .font(Theme.Typography.eyebrow)
                    .foregroundStyle(Theme.textSecondary)
                ForEach(report.topCustomers) { customer in
                    NavigationLink(value: AppRoute.customer(customer.customerID)) {
                        ReportsTopCustomerRow(customer: customer, clock: clock, currencyCode: currencyCode)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ReportsTopCustomerRow: View {
    let customer: ReportTopCustomer
    let clock: ShopClock
    let currencyCode: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(customer.name)
                    .font(Theme.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            MoneyText(cents: customer.lifetimeNetCents, currencyCode: currencyCode, size: .small)
            Image(systemName: "chevron.right")
                .font(Theme.Typography.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts = ["\(customer.completedJobs) job\(customer.completedJobs == 1 ? "" : "s")"]
        if let last = customer.lastCompletedAt {
            parts.append("last \(clock.shortDayText(last))")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Lead sources (P-33)

/// Where customers came from in the range, busiest sources first: new
/// customers, open leads, conversions and revenue per source.
struct OpsLeadSourcesCard: View {
    let state: LoadState<[OpsLeadSourceRow]>
    let currencyCode: String
    let retry: () async -> Void

    /// Sources shown before "Show all".
    private static let collapsedCount = 5

    /// Matches the server's definitions (`report_lead_sources`, ops 0078).
    static let subtitle = "Customers added in this period by where they came from. Converted = marked as a customer or has a completed job. Revenue = what they paid by the end of the period, including deposits, less refunds and without tips."

    @State private var showAll = false

    var body: some View {
        ReportsCard(
            "Lead sources",
            subtitle: OpsLeadSourcesCard.subtitle,
            state: state,
            retry: retry
        ) { rows in
            let active = OpsLeadSourceRow.active(rows)
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if active.isEmpty {
                    ReportsEmptyLine(text: "No new customers or leads in this period.")
                } else {
                    let visible = showAll ? active : Array(active.prefix(Self.collapsedCount))
                    ForEach(visible) { row in
                        OpsLeadSourcesCard.Row(row: row, currencyCode: currencyCode)
                        if row.id != visible.last?.id {
                            Divider()
                        }
                    }
                    if active.count > Self.collapsedCount {
                        let toggleTitle: String = showAll ? "Show fewer" : "Show all \(active.count) sources"
                        Button(toggleTitle) {
                            showAll.toggle()
                        }
                        .font(Theme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(Theme.glacier)
                    }
                }
            }
        }
    }
}

extension OpsLeadSourcesCard {
    struct Row: View {
        let row: OpsLeadSourceRow
        let currencyCode: String

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.sourceName)
                        .font(Theme.Typography.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: Theme.Spacing.sm)
                    MoneyText(cents: row.revenueCents, currencyCode: currencyCode, size: .small)
                }
                Text(countsText)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if row.firstJobRevenueCents > 0 {
                    ReportsMoneyRow(label: "First completed job (before tax)", cents: row.firstJobRevenueCents, currencyCode: currencyCode, emphasis: .secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }

        private var countsText: String {
            var parts = ["\(row.customersCount) new"]
            parts.append("\(row.convertedCount) converted")
            if let bps = row.conversionBps {
                parts[parts.count - 1] += " (\(ReportsFormatting.percent(bps: bps)))"
            }
            if row.leadsCount > 0 {
                parts.append("\(row.leadsCount) open lead\(row.leadsCount == 1 ? "" : "s")")
            }
            return parts.joined(separator: " · ")
        }
    }
}

// MARK: - Quote conversion (P-33)

/// Quotes sent in the range: approval rate, outcomes, averages, time to
/// approval and a line per month.
struct OpsQuoteConversionCard: View {
    let state: LoadState<OpsQuoteConversion>
    let currencyCode: String
    let retry: () async -> Void

    var body: some View {
        ReportsCard(
            "Quote conversion",
            subtitle: "Quotes sent in this period and what became of them. Approved includes quotes already turned into jobs.",
            state: state,
            retry: retry
        ) { report in
            OpsQuoteConversionCard.Details(report: report, currencyCode: currencyCode)
        }
    }
}

extension OpsQuoteConversionCard {
    struct Details: View {
        let report: OpsQuoteConversion
        let currencyCode: String

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if report.sent == 0 {
                    ReportsEmptyLine(text: "No quotes were sent in this period.")
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Approval rate")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: Theme.Spacing.sm)
                        Text(report.conversionRateBps.map { ReportsFormatting.percent(bps: $0) } ?? "—")
                            .font(Theme.Typography.sectionTitle.monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .accessibilityElement(children: .combine)
                    ReportsMetricRow(label: "Sent", value: "\(report.sent)")
                    ReportsMetricRow(label: "Viewed", value: "\(report.viewed)")
                    ReportsMetricRow(label: "Approved", value: "\(report.approved)")
                    ReportsMetricRow(label: "Turned into jobs", value: "\(report.converted)")
                    ReportsMetricRow(label: "Declined", value: "\(report.declined)")
                    ReportsMetricRow(label: "Expired", value: "\(report.expired)")
                    ReportsMetricRow(label: "Awaiting an answer", value: "\(report.awaiting)")
                    Divider()
                    averageRow("Average quote", cents: report.averageQuoteCents)
                    averageRow("Average approved quote", cents: report.averageApprovedCents)
                    ReportsMetricRow(
                        label: "Median time to approval",
                        value: report.medianHoursToApprove.map { OpsQuoteConversion.durationText(hours: $0) } ?? "—"
                    )
                    if report.byMonth.count > 1 {
                        Divider()
                        Text("BY MONTH")
                            .font(Theme.Typography.eyebrow)
                            .foregroundStyle(Theme.textSecondary)
                        ForEach(report.byMonth) { month in
                            monthRow(month)
                        }
                    }
                }
            }
        }

        @ViewBuilder
        private func averageRow(_ label: String, cents: Int?) -> some View {
            if let cents {
                ReportsMoneyRow(label: label, cents: cents, currencyCode: currencyCode)
            } else {
                ReportsMetricRow(label: label, value: "—")
            }
        }

        private func monthRow(_ month: OpsQuoteConversion.Month) -> some View {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(month.label())
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(month.approved) of \(month.sent) approved")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: Theme.Spacing.sm)
                MoneyText(cents: month.approvedCents, currencyCode: currencyCode, size: .small)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
