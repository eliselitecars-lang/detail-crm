//
//  MoneyMembershipUsageRow.swift
//  DetailCRM
//
//  Included visits a member has used in the current billing period (P-23,
//  `membership_usage`). A visit counts when a job line uses the membership
//  (priced 0 as included) on a job that isn't cancelled or a no-show; when
//  the plan's limit is reached, further visits are priced from the catalog
//  until the period renews.
//

import SwiftUI
import DetailCore

struct MoneyMembershipUsageRow: View {
    let membershipID: UUID

    @Environment(AppState.self) private var appState
    @State private var state: LoadState<Membership.Usage> = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Included visits")
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            switch state {
            case .idle, .loading:
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().tint(Theme.glacier)
                    Text("Checking this period…")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    InlineMessage(text: message)
                    AsyncButton("Try again", style: .themeSecondaryCompact) {
                        await load()
                    }
                }
            case .loaded(let usage):
                loaded(usage)
            }
        }
        .task(id: membershipID) { await load() }
    }

    @ViewBuilder
    private func loaded(_ usage: Membership.Usage) -> some View {
        Text(summary(usage))
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        if let limit = usage.usesPerPeriod, limit > 0 {
            ProgressView(value: Double(min(usage.usesThisPeriod, limit)), total: Double(limit))
                .tint(usage.usesThisPeriod >= limit ? Theme.warning : Theme.glacier)
                .accessibilityHidden(true)
        }
        if let periodText = periodText(usage) {
            Text(periodText)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func summary(_ usage: Membership.Usage) -> String {
        let used = usage.usesThisPeriod
        guard let limit = usage.usesPerPeriod else {
            return used == 1 ? "1 visit this period · no limit" : "\(used) visits this period · no limit"
        }
        if used >= limit {
            return "All \(limit) used this period. More visits are charged at catalog prices until it renews."
        }
        return "\(used) of \(limit) used this period"
    }

    private func periodText(_ usage: Membership.Usage) -> String? {
        let clock = appState.clock
        switch (usage.periodStart, usage.periodEnd) {
        case let (start?, end?):
            // The period ends at `end`; its last day is the day before.
            let lastDay = end.addingTimeInterval(-1)
            return "Period \(clock.shortDayText(start)) – \(clock.shortDayText(lastDay))"
        case let (nil, end?):
            return "Renews \(clock.shortDayText(end))"
        default:
            return nil
        }
    }

    private func load() async {
        state.beginLoading()
        let id = membershipID
        let result = await LoadState<Membership.Usage>.result {
            try await MembershipService.usage(membershipID: id)
        }
        state.apply(result)
    }
}
