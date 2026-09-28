//
//  JobServicesSection.swift
//  DetailCRM
//
//  Line items with the server's totals, and the job's money picture
//  (deposit, paid, balance, invoice). Nothing here adds up money: every
//  amount is a server column or the `job_payment_summary` result.
//

import SwiftUI
import DetailCore

struct JobServicesSection: View {
    let job: Job
    let lines: [JobLineItem]
    let currencyCode: String
    let canEdit: Bool
    /// The job's issued (non-void) invoice, when the money picture is loaded.
    let invoice: JobIssuedInvoiceInfo?
    /// Set when a line/discount write succeeded but the re-read failed.
    let refreshProblem: String?
    let onRetryRefresh: () async -> Void
    let onEdit: () -> Void

    var body: some View {
        JobSectionCard(
            "Services",
            actionTitle: canEdit ? "Edit" : nil,
            action: canEdit ? onEdit : nil
        ) {
            if let refreshProblem {
                InlineMessage(text: refreshProblem, kind: .error)
                AsyncButton("Refresh services", style: .themeSecondaryCompact) {
                    await onRetryRefresh()
                }
            }
            if let invoice, invoice.totalCents != job.totalCents {
                InlineMessage(
                    text: invoice.title + " was issued with a different total. Changes to these services don't update the invoice.",
                    kind: .info
                )
            }
            if lines.isEmpty {
                JobEmptyLine(text: canEdit ? "No services yet. Tap Edit to add some." : "No services on this job.", systemImage: "list.bullet.rectangle")
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(lines) { line in
                        JobLineRow(line: line, currencyCode: currencyCode)
                    }
                }
                JobDivider()
                totals
            }
        }
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            JobMoneyRow(label: "Subtotal", cents: job.subtotalCents, currencyCode: currencyCode)
            if job.discountCents > 0 {
                JobMoneyRow(label: discountLabel, cents: -job.discountCents, currencyCode: currencyCode)
            }
            if job.taxCents > 0 || job.taxRateBps > 0 {
                JobMoneyRow(
                    label: "Tax (\(JobsFormatting.percent(bps: job.taxRateBps)))",
                    cents: job.taxCents,
                    currencyCode: currencyCode
                )
            }
            JobMoneyRow(label: "Total", cents: job.totalCents, currencyCode: currencyCode, isTotal: true)
        }
    }

    private var discountLabel: String {
        switch job.discountKind {
        case .percent: return "Discount (\(JobsFormatting.percent(bps: job.discountValue)))"
        case .fixed, .none: return "Discount"
        }
    }
}

/// One line: name, quantity × unit price, discount and the server's line total.
struct JobLineRow: View {
    let line: JobLineItem
    let currencyCode: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(line.name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detailText)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                if let description = line.description?.trimmedNonEmpty {
                    Text(description)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            if let total = line.totalCents {
                MoneyText(cents: total, currencyCode: currencyCode, size: .small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detailText: String {
        var parts: [String] = [
            JobsFormatting.quantity(line.quantity) + " × " + Money.format(cents: line.unitPriceCents, currencyCode: currencyCode),
        ]
        if line.discountCents > 0 {
            parts.append("−" + Money.format(cents: line.discountCents, currencyCode: currencyCode) + " off")
        }
        if line.durationMinutes > 0 {
            parts.append(ShopClock.durationText(minutes: line.durationMinutes))
        }
        if !line.taxable {
            parts.append("not taxed")
        }
        if line.feeID != nil {
            parts.append("fee")
        }
        if line.membershipID != nil {
            parts.append("membership")
        }
        if line.discountEligible == false {
            parts.append("no job discount")
        }
        return parts.joined(separator: " · ")
    }
}

/// Deposit, payments and the invoice (collectors only).
struct JobMoneySection: View {
    let state: LoadState<JobPaymentSummary?>
    let job: Job
    let currencyCode: String
    let retry: () async -> Void
    let onCreateInvoice: () async -> Void
    /// Managers see the automatic deposit reminders (P-3).
    var showsDepositFollowups: Bool = false

    var body: some View {
        JobSectionCard("Payment") {
            JobSectionStateView(state, loadingLabel: "Loading payments…", retry: retry) { summary in
                if let summary {
                    JobMoneySummaryView(
                        summary: summary,
                        job: job,
                        currencyCode: currencyCode,
                        onCreateInvoice: onCreateInvoice
                    )
                    if showsDepositFollowups && summary.depositDueCents > 0 {
                        JobDivider()
                        JobsDepositFollowupRow(jobID: job.id)
                    }
                } else {
                    JobEmptyLine(text: "No payment information yet.", systemImage: "creditcard")
                }
            }
        }
    }
}

struct JobMoneySummaryView: View {
    let summary: JobPaymentSummary
    let job: Job
    let currencyCode: String
    let onCreateInvoice: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if summary.depositRequiredCents > 0 {
                    JobMoneyRow(label: "Deposit required", cents: summary.depositRequiredCents, currencyCode: currencyCode)
                    JobMoneyRow(label: "Deposit paid", cents: summary.depositPaidCents, currencyCode: currencyCode)
                    if summary.depositDueCents > 0 {
                        JobMoneyRow(
                            label: "Deposit due",
                            cents: summary.depositDueCents,
                            currencyCode: currencyCode,
                            emphasis: .attention
                        )
                    }
                }
                JobMoneyRow(label: "Paid", cents: summary.paidCents, currencyCode: currencyCode)
                if summary.tipCents > 0 {
                    JobMoneyRow(label: "Tips", cents: summary.tipCents, currencyCode: currencyCode, emphasis: .secondary)
                }
                if summary.refundedCents > 0 {
                    JobMoneyRow(label: "Refunded", cents: summary.refundedCents, currencyCode: currencyCode, emphasis: .secondary)
                }
                if summary.pendingCents > 0 {
                    JobMoneyRow(label: "Processing", cents: summary.pendingCents, currencyCode: currencyCode, emphasis: .secondary)
                }
                JobMoneyRow(
                    label: "Balance",
                    cents: summary.balanceCents,
                    currencyCode: currencyCode,
                    emphasis: summary.balanceCents > 0 ? .attention : .normal,
                    isTotal: true
                )
            }
            JobDivider()
            invoiceRow
        }
    }

    @ViewBuilder
    private var invoiceRow: some View {
        if let invoiceID = summary.invoiceID {
            NavigationLink(value: AppRoute.invoice(invoiceID)) {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "doc.plaintext")
                        .foregroundStyle(Theme.glacier)
                        .accessibilityHidden(true)
                    Text(summary.invoiceNumber.map { "Invoice #\($0)" } ?? "Invoice")
                        .font(Theme.Typography.bodyEmphasis)
                        .foregroundStyle(Theme.textPrimary)
                    if let status = summary.invoiceStatus {
                        StatusBadge(status)
                    }
                    Spacer(minLength: Theme.Spacing.sm)
                    Image(systemName: "chevron.right")
                        .font(Theme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the invoice to collect payment or send it")
            if summary.isOnGroupedInvoice, let count = summary.invoiceJobCount {
                Text("Billed together with \(count - 1) other job\(count == 2 ? "" : "s") on this invoice; the balance is the invoice's.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if summary.isOnGroupedInvoice {
            JobEmptyLine(text: "This job is billed on a grouped invoice with other jobs.", systemImage: "doc.on.doc")
        } else if job.status == .cancelled || job.status == .noShow {
            JobEmptyLine(text: "No invoice. This job was \(job.status.displayName.lowercased()).", systemImage: "doc.plaintext")
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("No invoice yet. Creating one copies this job's services and attaches any deposit already paid.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                AsyncButton(style: .themeMoney) {
                    await onCreateInvoice()
                } label: {
                    Label("Create invoice", systemImage: "doc.badge.plus")
                }
            }
        }
    }
}
