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
            ReportsRevenueBody(rows: rows, bucket: range.bucket(clock), clock: clock, currencyCode: currencyCode)
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
                        ReportsTeamRowView(row: row, currencyCode: currencyCode)
                    }
                }
            }
        }
    }
}

private struct ReportsTeamRowView: View {
    let row: ReportTeamRow
    let currencyCode: String

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
