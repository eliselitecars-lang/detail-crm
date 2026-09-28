//
//  CalendarAgendaView.swift
//  DetailCRM
//
//  Agenda mode: the visible range as a list grouped by shop-local day.
//  Jobs the viewer may open link to the job; busy blocks and blocked
//  time are shown but not tappable.
//

import SwiftUI
import DetailCore

struct CalendarAgendaView: View {
    let days: [CalendarAgendaDay]
    let clock: ShopClock
    let memberColors: [UUID: String]
    let onRefresh: () async -> Void
    /// Opens a calendar event (managers+); nil = events aren't tappable.
    var onOpenEvent: ((CalendarEvent) -> Void)? = nil

    var body: some View {
        if days.isEmpty {
            ScrollView {
                EmptyStateView(
                    systemImage: "calendar",
                    title: "Nothing scheduled",
                    message: "No jobs or events in these two weeks."
                )
                .frame(minHeight: 320)
            }
            .refreshable { await onRefresh() }
        } else {
            List {
                ForEach(days) { day in
                    Section {
                        ForEach(day.events, id: \.key) { event in
                            CalendarAgendaRowLink(event: event, clock: clock, memberColors: memberColors, onOpenEvent: onOpenEvent)
                                .themedRow()
                        }
                    } header: {
                        CalendarAgendaDayHeader(day: day.day, count: day.events.count, clock: clock)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable { await onRefresh() }
        }
    }
}

private struct CalendarAgendaDayHeader: View {
    let day: Date
    let count: Int
    let clock: ShopClock

    var body: some View {
        let relative = clock.relativeDayText(day)
        let short = clock.shortDayText(day)
        let text = relative == short ? short : "\(relative) · \(short)"
        Text(text)
            .font(Theme.Typography.eyebrow)
            .tracking(0.6)
            .foregroundStyle(clock.isSameDay(day, Date()) ? Theme.glacier : Theme.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Wraps a row in a job link when the viewer may open it.
private struct CalendarAgendaRowLink: View {
    let event: CalendarEvent
    let clock: ShopClock
    let memberColors: [UUID: String]
    let onOpenEvent: ((CalendarEvent) -> Void)?

    var body: some View {
        if event.isOpenableJob {
            NavigationLink(value: AppRoute.job(event.id)) {
                CalendarAgendaRow(event: event, clock: clock, memberColors: memberColors)
            }
        } else if event.isBlockedTime, let onOpenEvent {
            Button {
                onOpenEvent(event)
            } label: {
                CalendarAgendaRow(event: event, clock: clock, memberColors: memberColors)
            }
            .buttonStyle(.plain)
        } else {
            CalendarAgendaRow(event: event, clock: clock, memberColors: memberColors)
        }
    }
}

struct CalendarAgendaRow: View {
    let event: CalendarEvent
    let clock: ShopClock
    let memberColors: [UUID: String]

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(CalendarPalette.color(for: event, memberColors: memberColors))
                .frame(width: 4)
                .frame(minHeight: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(CalendarFormat.timeRange(event, clock: clock))
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: Theme.Spacing.xs) {
                    if let kind = event.blockKind {
                        Image(systemName: kind.systemImage)
                            .foregroundStyle(CalendarPalette.color(for: event, memberColors: memberColors))
                            .accessibilityHidden(true)
                    } else if event.isSeriesJob {
                        Image(systemName: "repeat")
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityHidden(true)
                    }
                    Text(event.displayTitle)
                        .font(Theme.Typography.bodyEmphasis)
                        .foregroundStyle(event.isOpenableJob || event.isForegroundEvent ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(2)
                }
                detailLines
            }

            Spacer(minLength: Theme.Spacing.sm)

            if event.isOpenableJob, let status = event.status {
                StatusBadge(status)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(CalendarAccessibility.label(for: event, clock: clock))
    }

    @ViewBuilder
    private var detailLines: some View {
        if let kind = event.blockKind {
            Text(blockDetail(kind))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
            if let customer = event.customerName?.trimmedNonEmpty {
                Label(customer, systemImage: "person")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        } else if event.isBusyBlock {
            Text("Another team member's job")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
        } else {
            if let services = event.servicesSummary {
                Text(services)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            if let vehicle = event.vehicleLabel?.trimmedNonEmpty {
                Label(vehicle, systemImage: "car")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            if event.isMobile, let address = event.serviceAddress?.trimmedNonEmpty {
                Label(address, systemImage: "mappin.and.ellipse")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            if let number = event.jobNumber {
                Text(verbatim: "Job #" + String(number) + (event.isSeriesJob ? " · repeating" : ""))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func blockDetail(_ kind: JobsCalendarEvent.Kind) -> String {
        let who = event.memberID == nil ? "Whole shop" : "One team member"
        return kind.displayName + " · " + who
    }
}
