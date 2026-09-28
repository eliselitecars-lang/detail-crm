//
//  TodaySections.swift
//  DetailCRM
//
//  Read-only sections of the Today tab: greeting, revenue tiles, the
//  "needs attention" tiles, today's jobs and who is on the clock. Money
//  is always server-computed cents rendered with MoneyText.
//

import SwiftUI
import DetailCore

/// Per-render values the sections need from AppState (so subviews stay
/// plain values and don't each observe the whole app state).
struct TodayContext {
    let clock: ShopClock
    let currencyCode: String
    let displayName: String
    let shopAddress: String?
    let canViewMoney: Bool
    let canDecideBookings: Bool
    let canOpenInvoices: Bool
    let canOpenQuotes: Bool
    let canOpenInbox: Bool
}

/// Everything the sections can ask the screen to do.
struct TodayActions {
    let refresh: () async -> Void
    let approve: (DashboardSummaryBookingRequest) -> Void
    let decline: (DashboardSummaryBookingRequest) -> Void
    let clockIn: () async -> Void
    let clockOut: () -> Void
}

// MARK: - Greeting

struct TodayGreeting: View {
    let context: TodayContext

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(context.clock.longDayText(now).uppercased())
                .font(Theme.Typography.eyebrow)
                .tracking(0.6)
                .foregroundStyle(Theme.textSecondary)
            Text("\(TodayLoader.greeting(now: now, clock: context.clock)), \(TodayLoader.firstName(context.displayName))")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Revenue (manager+)

struct TodayRevenueSection: View {
    let revenue: DashboardSummaryRevenue
    let context: TodayContext

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: Theme.Spacing.md)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "Collected")
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.md) {
                TodayRevenueTile(title: "Today", period: revenue.today, currencyCode: context.currencyCode)
                TodayRevenueTile(title: "This week", period: revenue.week, currencyCode: context.currencyCode)
                TodayRevenueTile(title: "This month", period: revenue.month, currencyCode: context.currencyCode)
            }
        }
    }
}

private struct TodayRevenueTile: View {
    let title: String
    let period: DashboardSummaryRevenuePeriod
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(title, systemImage: "dollarsign.circle")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textSecondary)
                .labelStyle(TodayTintedIconLabelStyle(tint: Theme.moneyInk))
            MoneyText(cents: period.netCents, currencyCode: currencyCode)
            Text(detailText)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle(padding: Theme.Spacing.md)
        .accessibilityElement(children: .combine)
    }

    private var detailText: String {
        let payments = period.paymentsCount == 1 ? "1 payment" : "\(period.paymentsCount) payments"
        guard period.tipsCents > 0 else { return payments }
        return "\(payments) · \(Money.format(cents: period.tipsCents, currencyCode: currencyCode)) tips"
    }
}

/// Icon in a tint color, title in the inherited style.
struct TodayTintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            configuration.icon
                .foregroundStyle(tint)
            configuration.title
        }
    }
}

// MARK: - Needs attention (manager+)

struct TodayAttentionSection: View {
    let summary: DashboardSummary
    let context: TodayContext

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.md)]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "Needs attention")
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.md) {
                if let open = summary.openInvoices {
                    TodayInvoiceTileLink(
                        title: "Open invoices",
                        systemImage: "doc.plaintext",
                        totals: open,
                        context: context
                    )
                }
                if let overdue = summary.overdueInvoices {
                    TodayInvoiceTileLink(
                        title: "Overdue",
                        systemImage: "exclamationmark.circle",
                        totals: overdue,
                        context: context
                    )
                }
                if let unread = summary.unreadInboundMessages {
                    TodayCountTileLink(
                        title: "Unread messages",
                        systemImage: "bubble.left.and.bubble.right",
                        count: unread,
                        destination: context.canOpenInbox ? TodayCountDestination.inbox : nil
                    )
                }
                if let quotes = summary.quotesAwaitingResponse {
                    TodayCountTileLink(
                        title: "Quotes awaiting reply",
                        systemImage: "doc.text",
                        count: quotes,
                        destination: context.canOpenQuotes ? TodayCountDestination.quotes : nil
                    )
                }
            }
        }
    }
}

enum TodayCountDestination {
    case inbox
    case quotes
}

private struct TodayInvoiceTileLink: View {
    let title: String
    let systemImage: String
    let totals: DashboardSummaryInvoiceTotals
    let context: TodayContext

    var body: some View {
        if context.canOpenInvoices {
            NavigationLink {
                InvoicesView()
            } label: {
                tile
            }
            .buttonStyle(.plain)
        } else {
            tile
        }
    }

    private var invoiceCountText: String {
        totals.count == 1 ? "1 invoice" : "\(totals.count) invoices"
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(title, systemImage: systemImage)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textSecondary)
                .labelStyle(TodayTintedIconLabelStyle(tint: totals.count > 0 ? Theme.moneyInk : Theme.textTertiary))
            MoneyText(
                cents: totals.balanceCents,
                currencyCode: context.currencyCode,
                emphasis: totals.balanceCents > 0 ? .attention : .secondary
            )
            Text(invoiceCountText)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .cardStyle(padding: Theme.Spacing.md)
        .accessibilityElement(children: .combine)
    }
}

private struct TodayCountTileLink: View {
    let title: String
    let systemImage: String
    let count: Int
    let destination: TodayCountDestination?

    var body: some View {
        switch destination {
        case .some(.inbox):
            NavigationLink {
                InboxView()
            } label: {
                tile
            }
            .buttonStyle(.plain)
        case .some(.quotes):
            NavigationLink {
                QuotesView()
            } label: {
                tile
            }
            .buttonStyle(.plain)
        case .none:
            tile
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(title, systemImage: systemImage)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textSecondary)
                .labelStyle(TodayTintedIconLabelStyle(tint: count > 0 ? Theme.glacier : Theme.textTertiary))
            Text(String(count))
                .font(Theme.Typography.sectionTitle.monospacedDigit())
                .foregroundStyle(count > 0 ? Theme.textPrimary : Theme.textSecondary)
        }
        .cardStyle(padding: Theme.Spacing.md)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Today's jobs

struct TodayJobsSection: View {
    let title: String
    let emptyText: String
    let jobs: [CalendarEvent]
    let jobsToday: DashboardSummaryJobsToday
    let context: TodayContext

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: title)
            if jobs.isEmpty {
                Text(emptyText)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .cardStyle()
            } else {
                Text(statusLine)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.Spacing.xs)
                VStack(spacing: 0) {
                    ForEach(Array(jobs.enumerated()), id: \.element.key) { index, job in
                        NavigationLink(value: AppRoute.job(job.id)) {
                            TodayJobRow(job: job, clock: context.clock)
                        }
                        .buttonStyle(.themeRow)
                        if index < jobs.count - 1 {
                            Rectangle()
                                .fill(Theme.border)
                                .frame(height: Theme.Size.hairline)
                                .padding(.leading, Theme.Spacing.lg)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: Theme.Size.hairline)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
        }
    }

    /// "4 jobs · 1 in progress · 2 done" from the server's status counts.
    private var statusLine: String {
        var parts = [jobsToday.total == 1 ? "1 job" : "\(jobsToday.total) jobs"]
        let active = jobsToday.count(.inProgress) + jobsToday.count(.enRoute)
        if active > 0 { parts.append("\(active) under way") }
        let done = jobsToday.count(.completed)
        if done > 0 { parts.append("\(done) done") }
        let waiting = jobsToday.count(.requested)
        if waiting > 0 { parts.append("\(waiting) awaiting approval") }
        return parts.joined(separator: " · ")
    }
}

struct TodayJobRow: View {
    let job: CalendarEvent
    let clock: ShopClock

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                Text(startText)
                    .font(Theme.Typography.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                Text(ShopClock.durationText(minutes: durationMinutes))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(minWidth: 64, alignment: .trailing)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(job.displayTitle)
                    .font(Theme.Typography.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let services = job.servicesSummary {
                    Text(services)
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                if let vehicle = job.vehicleLabel?.trimmedNonEmpty {
                    Label(vehicle, systemImage: "car")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if job.isMobile, let address = job.serviceAddress?.trimmedNonEmpty {
                    Label(address, systemImage: "mappin.and.ellipse")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Theme.Spacing.sm)

            VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                if let status = job.status {
                    StatusBadge(status)
                }
                Image(systemName: "chevron.right")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(CalendarAccessibility.label(for: job, clock: clock))
    }

    /// Start time, or the date when the job began on an earlier day.
    private var startText: String {
        if clock.isSameDay(job.startsAt, Date()) {
            return clock.timeText(job.startsAt)
        }
        return clock.shortDayText(job.startsAt)
    }

    private var durationMinutes: Int {
        Int(job.endsAt.timeIntervalSince(job.startsAt) / 60)
    }
}

// MARK: - On the clock (manager+)

struct TodayClockedInSection: View {
    let clockedIn: DashboardSummaryClockedIn
    let context: TodayContext

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "On the clock")
            if clockedIn.members.isEmpty {
                Text("Nobody is clocked in right now.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .cardStyle()
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(clockedIn.members) { member in
                        TodayClockedInRow(member: member, clock: context.clock)
                    }
                }
                .cardStyle()
            }
        }
    }
}

private struct TodayClockedInRow: View {
    let member: DashboardSummaryClockedMember
    let clock: ShopClock

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            AvatarView(name: member.displayName, size: Theme.Size.avatarSmall)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(member.displayName)
                    .font(Theme.Typography.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("Since \(clock.timeText(member.since))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            if let jobID = member.jobID {
                NavigationLink(value: AppRoute.job(jobID)) {
                    Text("On a job")
                        .font(Theme.Typography.captionEmphasis)
                }
                .buttonStyle(.themeSecondaryCompact)
                .accessibilityLabel("Open the job \(member.displayName) is working on")
            }
            Text(member.since, style: .timer)
                .font(Theme.Typography.footnote.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
    }
}
