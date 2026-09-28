//
//  MoneyInvoiceGroupedLinesSection.swift
//  DetailCRM
//
//  Lines of an invoice, per job (P-7). A grouped (fleet / dealer) invoice
//  bills several jobs of one customer: each job gets a heading with its
//  number, date and vehicle (opening the job), its lines below. Lines not
//  tied to a job (added to the invoice by hand) come last. The same view
//  shows a single job's invoice as a plain list, naming each line's
//  vehicle when the lines are for more than one.
//

import SwiftUI
import DetailCore

struct MoneyInvoiceGroupedLinesSection: View {
    let lines: [InvoiceLineItem]
    let jobs: [InvoiceService.BilledJob]
    let vehicles: [UUID: QuoteVehicleRef]
    let currencyCode: String
    let clock: ShopClock
    /// Job headings open the job (staff who may see it).
    var canOpenJobs: Bool = true
    /// The invoice has a document discount (explains excluded lines).
    var hasDocumentDiscount: Bool = false

    var body: some View {
        MoneySectionCard(jobs.count > 1 ? "Items by job" : "Items") {
            if lines.isEmpty {
                Text("No items on this invoice.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else if jobs.count > 1 {
                Text("This invoice bills \(jobs.count) jobs.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        heading(group)
                        rows(group.lines)
                    }
                    .padding(.top, Theme.Spacing.xs)
                }
            } else {
                rows(lines)
            }
        }
    }

    // MARK: Grouping

    /// A job's lines (or the lines tied to no job, `job == nil`).
    struct Group: Identifiable {
        let job: InvoiceService.BilledJob?
        let lines: [InvoiceLineItem]

        var id: String { job?.id.uuidString ?? "other" }

        var subtotalCents: Int {
            lines.reduce(0) { $0 + ($1.totalCents ?? 0) }
        }
    }

    private var groups: [Group] {
        let known = Set(jobs.map { $0.id })
        var result = jobs.map { job in Group(job: job, lines: lines.filter { $0.jobID == job.id }) }
        let other = lines.filter { line in line.jobID.map { !known.contains($0) } ?? true }
        if !other.isEmpty {
            result.append(Group(job: nil, lines: other))
        }
        return result.filter { !$0.lines.isEmpty }
    }

    @ViewBuilder
    private func heading(_ group: Group) -> some View {
        if let job = group.job {
            if canOpenJobs {
                NavigationLink(value: AppRoute.job(job.id)) {
                    headingLabel(group, job: job, showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the job")
            } else {
                headingLabel(group, job: job, showsChevron: false)
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("Other items")
                    .font(Theme.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Theme.Spacing.sm)
                MoneyText(cents: group.subtotalCents, currencyCode: currencyCode, size: .small, emphasis: .secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func headingLabel(_ group: Group, job: InvoiceService.BilledJob, showsChevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(job.title)
                    .font(Theme.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let detail = jobDetail(job) {
                    Text(detail)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            MoneyText(cents: group.subtotalCents, currencyCode: currencyCode, size: .small, emphasis: .secondary)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.surfaceMuted)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "Jun 3 · 2021 Toyota RAV4"
    private func jobDetail(_ job: InvoiceService.BilledJob) -> String? {
        var parts: [String] = []
        if let date = job.workDate {
            parts.append(clock.shortDayText(date))
        }
        if let vehicleID = job.vehicleID, let vehicle = vehicles[vehicleID] {
            parts.append(vehicle.displayName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Rows

    @ViewBuilder
    private func rows(_ items: [InvoiceLineItem]) -> some View {
        ForEach(items) { line in
            MoneyLineRow(
                name: line.name,
                detail: line.lineDescription,
                quantity: line.quantity,
                unitPriceCents: line.unitPriceCents,
                discountCents: line.discountCents,
                totalCents: line.totalCents,
                currencyCode: currencyCode,
                badge: line.feeID != nil ? "Fee" : nil,
                note: note(line)
            )
            if line.id != items.last?.id {
                Divider().overlay(Theme.border)
            }
        }
    }

    /// Several vehicles on the invoice: name each line's vehicle.
    private var namesVehicles: Bool {
        Set(lines.compactMap { $0.vehicleID }).count > 1
    }

    private func note(_ line: InvoiceLineItem) -> String? {
        var parts: [String] = []
        if namesVehicles, let vehicleID = line.vehicleID, let vehicle = vehicles[vehicleID] {
            parts.append(vehicle.displayName)
        }
        if !line.taxable {
            parts.append("Not taxed")
        }
        if hasDocumentDiscount && !line.discountEligible {
            parts.append("Invoice discount doesn't apply")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
