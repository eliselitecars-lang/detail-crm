//
//  OpsEarningsCard.swift
//  DetailCRM
//
//  Earnings (P-12). A technician's Reports screen shows their own row of
//  `report_team`: hours, completed jobs, hourly pay, commission on their
//  jobs, service and sales commission, tips and the total. "Earnings by
//  job" opens the per-job breakdown (`report_member_earnings`), whose
//  amounts add up to the same row. Owners and admins reach the same
//  breakdown for any member from the Team card.
//
//  Every amount is computed by the server; the app only formats it.
//

import SwiftUI
import DetailCore

struct OpsEarningsCard: View {
    let state: LoadState<[ReportTeamRow]>
    let range: ReportDateRange
    let currencyCode: String
    let retry: () async -> Void

    var body: some View {
        ReportsCard(
            "My earnings",
            subtitle: "Your hours, completed jobs, pay, commission and tips for this period.",
            state: state,
            retry: retry
        ) { rows in
            if let row = rows.first {
                Summary(row: row, range: range, currencyCode: currencyCode)
            } else {
                ReportsEmptyLine(text: "No time or completed jobs in this period.")
            }
        }
    }
}

extension OpsEarningsCard {

    /// The member's totals and the link to the per-job list.
    struct Summary: View {
        let row: ReportTeamRow
        let range: ReportDateRange
        let currencyCode: String

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if let total = row.totalEarningsCents {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Total earnings")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: Theme.Spacing.sm)
                        MoneyText(cents: total, currencyCode: currencyCode, size: .large)
                    }
                    .accessibilityElement(children: .combine)
                    Divider()
                }
                ReportsMetricRow(label: "Hours worked", value: ReportsFormatting.hours(row.hours))
                ReportsMetricRow(label: "Jobs completed", value: "\(row.jobsCompleted)")
                ReportsMoneyRow(label: "Revenue (before tax)", cents: row.preTaxRevenueCents, currencyCode: currencyCode, emphasis: .secondary)
                OpsEarningsCard.Breakdown(row: row, currencyCode: currencyCode)
                NavigationLink {
                    OpsEarningsCard.JobsList(memberID: row.memberID, memberName: nil, range: range)
                } label: {
                    HStack {
                        Label("Earnings by job", systemImage: "list.bullet.rectangle")
                            .font(Theme.Typography.subheadline.weight(.semibold))
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
            }
        }
    }

    /// Pay lines the server returned for a team row (nothing for managers,
    /// who get no pay columns).
    struct Breakdown: View {
        let row: ReportTeamRow
        let currencyCode: String

        var body: some View {
            if row.hasPayColumns {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    if let labor = row.laborCostCents {
                        ReportsMoneyRow(label: hourlyLabel, cents: labor, currencyCode: currencyCode)
                    }
                    if let commission = row.commissionCents {
                        ReportsMoneyRow(label: commissionLabel, cents: commission, currencyCode: currencyCode)
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
                }
            }
        }

        private var hourlyLabel: String {
            guard let rate = row.hourlyRateCents, rate > 0 else { return "Hourly pay" }
            return "Hourly pay (\(Money.format(cents: rate, currencyCode: currencyCode))/h)"
        }

        private var commissionLabel: String {
            guard let bps = row.commissionBps, bps > 0 else { return "Commission" }
            return "Commission (\(ReportsFormatting.percent(bps: bps)))"
        }
    }

    // MARK: - Per-job list

    /// One member's completed jobs in the range with what they earned on
    /// each (`report_member_earnings`).
    struct JobsList: View {
        let memberID: UUID
        /// Shown in the title when looking at someone else.
        let memberName: String?
        let range: ReportDateRange

        @Environment(AppState.self) private var appState
        @Environment(ToastCenter.self) private var toasts
        @State private var state: LoadState<[OpsMemberEarning]> = .idle
        /// Jobs the viewer may open; nil = every job (owners / admins /
        /// managers read all jobs). Technicians read only jobs they are
        /// assigned to, and this list also has jobs they only sold.
        @State private var readableJobIDs: Set<UUID>?

        var body: some View {
            LoadStateView(state, loadingLabel: "Loading earnings…", retry: { await load() }) { rows in
                content(rows)
            }
            .screenBackground()
            .navigationTitle(memberName.map { "\($0)'s earnings" } ?? "Earnings by job")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .refreshable { await load() }
        }

        @ViewBuilder
        private func content(_ rows: [OpsMemberEarning]) -> some View {
            if rows.isEmpty {
                EmptyStateView(
                    systemImage: "briefcase",
                    title: "No completed jobs",
                    message: "No completed jobs were assigned to or sold by this person in \(range.label(appState.clock))."
                )
            } else {
                List {
                    Section {
                        OpsEarningsCard.JobsTotals(totals: OpsMemberEarning.Totals(rows), currencyCode: appState.currencyCode)
                            .themedRow()
                    } header: {
                        Text(range.label(appState.clock))
                    } footer: {
                        Text("Hourly pay isn't split by job, so it is only in the Reports total.")
                    }
                    Section {
                        ForEach(rows) { row in
                            if OpsMemberEarning.canOpen(jobID: row.jobID, readableJobIDs: readableJobIDs) {
                                NavigationLink(value: AppRoute.job(row.jobID)) {
                                    OpsEarningsCard.JobRow(row: row, clock: appState.clock, currencyCode: appState.currencyCode)
                                }
                                .themedRow()
                            } else {
                                OpsEarningsCard.JobRow(row: row, clock: appState.clock, currencyCode: appState.currencyCode)
                                    .themedRow()
                            }
                        }
                    } header: {
                        Text("Jobs")
                    } footer: {
                        if rows.contains(where: { !OpsMemberEarning.canOpen(jobID: $0.jobID, readableJobIDs: readableJobIDs) }) {
                            Text("Jobs you sold but weren't assigned to can't be opened here.")
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }

        private func load() async {
            guard let shopID = appState.shop?.id else {
                state = .failed(AppError.noShopSelected.errorDescription ?? "Choose a shop first.")
                return
            }
            let clock = appState.clock
            let from = range.fromString(clock)
            let to = range.toString(clock)
            let id = memberID
            let seesAllJobs = appState.role?.isManagerOrAbove ?? false
            state.beginLoading()
            let result = await LoadState<[OpsMemberEarning]>.result {
                try await ReportService.memberEarnings(shopID: shopID, memberID: id, from: from, to: to)
            }
            if let message = result.errorMessage, state.value != nil {
                toasts.show(message, style: .error)
            }
            if let rows = result.value {
                if seesAllJobs {
                    readableJobIDs = nil
                } else {
                    readableJobIDs = await ReportService.readableJobIDs(shopID: shopID, jobIDs: rows.map(\.jobID))
                }
            }
            state.apply(result)
        }
    }

    /// Sums of the per-job rows.
    struct JobsTotals: View {
        let totals: OpsMemberEarning.Totals
        let currencyCode: String

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Commission and tips")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: Theme.Spacing.sm)
                    MoneyText(cents: totals.earnedCents, currencyCode: currencyCode, size: .regular)
                }
                .accessibilityElement(children: .combine)
                ReportsMetricRow(label: "Jobs", value: "\(totals.jobs)")
                ReportsMetricRow(label: "Job hours", value: ReportsFormatting.hours(totals.hours))
                ReportsMoneyRow(label: "Revenue share (before tax)", cents: totals.revenueShareCents, currencyCode: currencyCode, emphasis: .secondary)
                ReportsMoneyRow(label: "Commission", cents: totals.commissionCents, currencyCode: currencyCode)
                ReportsMoneyRow(label: "Service commission", cents: totals.serviceCommissionCents, currencyCode: currencyCode)
                ReportsMoneyRow(label: "Sales commission", cents: totals.salesCommissionCents, currencyCode: currencyCode)
                ReportsMoneyRow(label: "Tips", cents: totals.tipsCents, currencyCode: currencyCode)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    /// One job: number, customer, date, hours and what was earned.
    struct JobRow: View {
        let row: OpsMemberEarning
        let clock: ShopClock
        let currencyCode: String

        var body: some View {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Job #\(row.jobNumber)")
                        .font(Theme.Typography.bodyEmphasis)
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                    Text(detail)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: Theme.Spacing.sm)
                VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                    MoneyText(cents: row.earnedCents, currencyCode: currencyCode, size: .small)
                    Text(ReportsFormatting.hours(row.hours))
                        .font(Theme.Typography.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.vertical, Theme.Spacing.xxs)
            .accessibilityElement(children: .combine)
        }

        private var subtitle: String {
            let day = clock.shortDayText(row.completedAt)
            guard let customer = row.customerLabel?.trimmedNonEmpty else { return day }
            return "\(customer) · \(day)"
        }

        private var detail: String {
            var parts: [String] = []
            if row.commissionCents != 0 {
                parts.append("Commission \(Money.format(cents: row.commissionCents, currencyCode: currencyCode))")
            }
            if row.serviceCommissionCents != 0 {
                parts.append("Service \(Money.format(cents: row.serviceCommissionCents, currencyCode: currencyCode))")
            }
            if row.salesCommissionCents != 0 {
                parts.append("Sales \(Money.format(cents: row.salesCommissionCents, currencyCode: currencyCode))")
            }
            if row.tipsCents != 0 {
                parts.append("Tips \(Money.format(cents: row.tipsCents, currencyCode: currencyCode))")
            }
            if parts.isEmpty {
                parts.append("Share \(Money.format(cents: row.revenueShareCents, currencyCode: currencyCode))")
            }
            return parts.joined(separator: " · ")
        }
    }
}
