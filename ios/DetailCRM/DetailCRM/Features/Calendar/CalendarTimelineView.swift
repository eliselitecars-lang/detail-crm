//
//  CalendarTimelineView.swift
//  DetailCRM
//
//  Day and Week modes: a 24-hour grid (shop wall clock) with positioned
//  job blocks — overlapping jobs sit side by side — and blocked time
//  shaded behind them. Day shows one wide column; Week shows seven compact
//  columns under a tappable day header (tap a day to open it in Day mode).
//
//  Layout math lives in CalendarLayoutEngine (pure, tested on Linux);
//  these views only turn minutes into points. Every frame is clamped to
//  be non-negative.
//

import SwiftUI
import DetailCore

struct CalendarTimelineView: View {
    let layouts: [CalendarDayLayout]
    let compact: Bool
    let clock: ShopClock
    let memberColors: [UUID: String]
    let onRefresh: () async -> Void
    let onSelectDay: (Date) -> Void
    /// Opens a calendar event (managers+); nil = events aren't tappable.
    var onOpenEvent: ((CalendarEvent) -> Void)? = nil

    /// The first-hour scroll runs once per range (the parent gives each
    /// range its own identity), not on every reappearance, so coming back
    /// from a job keeps the user's place.
    @State private var didInitialScroll = false

    private var hourHeight: CGFloat { compact ? 48 : 60 }
    private let labelWidth: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            if compact {
                CalendarWeekHeader(
                    days: layouts.map { $0.day },
                    clock: clock,
                    labelWidth: labelWidth,
                    onSelectDay: onSelectDay
                )
                Rectangle()
                    .fill(Theme.border)
                    .frame(height: Theme.Size.hairline)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        CalendarHourLabels(hourHeight: hourHeight, width: labelWidth)
                        HStack(alignment: .top, spacing: compact ? 2 : 0) {
                            ForEach(layouts) { layout in
                                CalendarDayColumn(
                                    layout: layout,
                                    hourHeight: hourHeight,
                                    compact: compact,
                                    clock: clock,
                                    memberColors: memberColors,
                                    onOpenEvent: onOpenEvent
                                )
                            }
                        }
                    }
                    .padding(.trailing, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.sm)
                }
                .refreshable { await onRefresh() }
                .onAppear {
                    guard !didInitialScroll else { return }
                    didInitialScroll = true
                    let hour = CalendarLayoutEngine.initialScrollHour(for: layouts)
                    DispatchQueue.main.async {
                        proxy.scrollTo(CalendarHourLabels.anchorID(hour), anchor: .top)
                    }
                }
            }
        }
    }
}

// MARK: - Week header

private struct CalendarWeekHeader: View {
    let days: [Date]
    let clock: ShopClock
    let labelWidth: CGFloat
    let onSelectDay: (Date) -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Matches CalendarHourLabels' width + trailing padding.
            Color.clear.frame(width: labelWidth + Theme.Spacing.xs, height: 1)
            HStack(spacing: 2) {
                ForEach(days, id: \.self) { day in
                    CalendarWeekHeaderDay(day: day, clock: clock) {
                        onSelectDay(day)
                    }
                }
            }
        }
        .padding(.trailing, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
    }
}

private struct CalendarWeekHeaderDay: View {
    let day: Date
    let clock: ShopClock
    let action: () -> Void

    var body: some View {
        let isToday = clock.isSameDay(day, Date())
        Button(action: action) {
            VStack(spacing: Theme.Spacing.xxs) {
                Text(CalendarFormat.weekdayShort(day, clock: clock))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                // Sized by the text (Dynamic Type), not a fixed frame, so
                // two-digit dates never truncate at accessibility sizes.
                Text(CalendarFormat.dayNumber(day, clock: clock))
                    .font(Theme.Typography.captionEmphasis)
                    .foregroundStyle(isToday ? Theme.onAccent : Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(Theme.Spacing.xxs)
                    .frame(minWidth: 26, minHeight: 26)
                    .background(Capsule().fill(isToday ? Theme.glacierSolid : Color.clear))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(clock.longDayText(day))
        .accessibilityHint("Opens this day")
    }
}

// MARK: - Hour labels

struct CalendarHourLabels: View {
    let hourHeight: CGFloat
    let width: CGFloat

    static func anchorID(_ hour: Int) -> String { "calendar-hour-\(hour)" }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hour == 0 ? "" : CalendarFormat.hourLabel(hour))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: width, height: hourHeight, alignment: .topTrailing)
                    .padding(.trailing, Theme.Spacing.xs)
                    .offset(y: -7)
                    .id(CalendarHourLabels.anchorID(hour))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Day column

private struct CalendarDayColumn: View {
    let layout: CalendarDayLayout
    let hourHeight: CGFloat
    let compact: Bool
    let clock: ShopClock
    let memberColors: [UUID: String]
    let onOpenEvent: ((CalendarEvent) -> Void)?

    private var totalHeight: CGFloat { hourHeight * 24 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CalendarHourGrid(hourHeight: hourHeight)
            GeometryReader { geometry in
                let width = max(geometry.size.width, 0)
                ZStack(alignment: .topLeading) {
                    ForEach(layout.shaded) { placed in
                        CalendarShadedBlock(placed: placed, compact: compact, clock: clock, onOpen: onOpenEvent)
                            .frame(width: width, height: height(of: placed))
                            .offset(y: y(of: placed.startMinute))
                    }
                    ForEach(layout.blocks) { placed in
                        let placedWidth = blockWidth(placed, total: width)
                        CalendarBlockLink(
                            placed: placed,
                            compact: compact,
                            width: placedWidth,
                            clock: clock,
                            memberColors: memberColors,
                            onOpenEvent: onOpenEvent
                        )
                        .frame(width: placedWidth, height: height(of: placed))
                        .offset(x: blockX(placed, total: width), y: y(of: placed.startMinute))
                    }
                    CalendarNowLine(day: layout.day, clock: clock, hourHeight: hourHeight)
                        .frame(width: width)
                }
            }
        }
        .frame(height: totalHeight)
        .frame(maxWidth: .infinity)
    }

    private func y(of minute: Int) -> CGFloat {
        max(0, CGFloat(minute) / 60 * hourHeight)
    }

    private func height(of placed: CalendarPlacedEvent) -> CGFloat {
        max(1, CGFloat(placed.durationMinutes) / 60 * hourHeight - 1)
    }

    private func blockWidth(_ placed: CalendarPlacedEvent, total: CGFloat) -> CGFloat {
        let count = CGFloat(max(placed.columnCount, 1))
        let gap: CGFloat = 1
        return max(1, total / count - gap)
    }

    private func blockX(_ placed: CalendarPlacedEvent, total: CGFloat) -> CGFloat {
        let count = CGFloat(max(placed.columnCount, 1))
        return max(0, total / count * CGFloat(placed.column))
    }
}

private struct CalendarHourGrid: View {
    let hourHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Theme.border)
                        .frame(height: Theme.Size.hairline)
                    Spacer(minLength: 0)
                }
                .frame(height: hourHeight)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A red line at the current time on today's column.
private struct CalendarNowLine: View {
    let day: Date
    let clock: ShopClock
    let hourHeight: CGFloat

    var body: some View {
        let now = Date()
        let isToday = clock.isSameDay(day, now)
        let minute = clock.minutesSinceMidnight(now)
        HStack(spacing: 0) {
            Circle()
                .fill(Theme.danger)
                .frame(width: 6, height: 6)
            Rectangle()
                .fill(Theme.danger)
                .frame(height: 1.5)
        }
        .offset(y: max(0, CGFloat(minute) / 60 * hourHeight - 3))
        .opacity(isToday ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Blocks

private struct CalendarShadedBlock: View {
    let placed: CalendarPlacedEvent
    let compact: Bool
    let clock: ShopClock
    /// Managers open closed hours / time off to edit them.
    let onOpen: ((CalendarEvent) -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Theme.surfaceMuted)
                .opacity(0.9)
            if !compact {
                Label(placed.event.displayTitle, systemImage: placed.event.blockKind?.systemImage ?? "nosign")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .padding(.top, Theme.Spacing.xxs)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen?(placed.event) }
        .allowsHitTesting(onOpen != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CalendarAccessibility.label(for: placed.event, clock: clock))
        .accessibilityAddTraits(onOpen != nil ? .isButton : [])
    }
}

private struct CalendarBlockLink: View {
    let placed: CalendarPlacedEvent
    let compact: Bool
    let width: CGFloat
    let clock: ShopClock
    let memberColors: [UUID: String]
    let onOpenEvent: ((CalendarEvent) -> Void)?

    var body: some View {
        if placed.event.isOpenableJob {
            NavigationLink(value: AppRoute.job(placed.event.id)) {
                CalendarBlock(placed: placed, compact: compact, width: width, clock: clock, memberColors: memberColors)
            }
            .buttonStyle(.plain)
        } else if placed.event.isForegroundEvent, let onOpenEvent {
            Button {
                onOpenEvent(placed.event)
            } label: {
                CalendarBlock(placed: placed, compact: compact, width: width, clock: clock, memberColors: memberColors)
            }
            .buttonStyle(.plain)
        } else {
            CalendarBlock(placed: placed, compact: compact, width: width, clock: clock, memberColors: memberColors)
        }
    }
}

private struct CalendarBlock: View {
    let placed: CalendarPlacedEvent
    let compact: Bool
    /// The block's width on screen (Week columns are narrow, and jobs that
    /// overlap share one).
    let width: CGFloat
    let clock: ShopClock
    let memberColors: [UUID: String]
    /// The narrowest Week block that still shows words (a few letters and
    /// "…"); a narrower one shows initials.
    @ScaledMetric(relativeTo: .caption) private var minWordsWidth: CGFloat = 36

    var body: some View {
        let event = placed.event
        let accent = CalendarPalette.color(for: event, memberColors: memberColors)
        HStack(spacing: 0) {
            Rectangle()
                .fill(accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    if let kind = event.blockKind {
                        Image(systemName: kind.systemImage)
                            .font(Theme.Typography.caption2)
                            .accessibilityHidden(true)
                    } else if event.isSeriesJob {
                        Image(systemName: "repeat")
                            .font(Theme.Typography.caption2)
                            .accessibilityHidden(true)
                    }
                    if compact {
                        CalendarCompactTitle(title: event.displayTitle, showsWords: width >= minWordsWidth)
                    } else {
                        Text(event.displayTitle)
                            .font(Theme.Typography.footnote.weight(.semibold))
                            .lineLimit(2)
                    }
                }
                .foregroundStyle(event.isOpenableJob || event.isForegroundEvent ? Theme.textPrimary : Theme.textSecondary)
                if !compact && placed.durationMinutes >= 40 {
                    Text(CalendarFormat.timeRange(event, clock: clock))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if !compact && placed.durationMinutes >= 70, let detail = detailText(event) {
                    Text(detail)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, compact ? 2 : Theme.Spacing.xs)
            .padding(.vertical, 2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(accent.opacity(event.isBusyBlock ? 0.10 : 0.18))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                .strokeBorder(accent.opacity(0.35), lineWidth: Theme.Size.hairline)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CalendarAccessibility.label(for: event, clock: clock))
        .accessibilityAddTraits(event.isOpenableJob || event.isForegroundEvent ? .isButton : [])
    }

    private func detailText(_ event: CalendarEvent) -> String? {
        let parts = [event.servicesSummary, event.vehicleLabel?.trimmedNonEmpty].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A Week-column block title (about 45 pt wide on an iPhone): whole words,
/// one per line, each truncated ("Christo…") instead of broken mid-word, or
/// initials when the block is too narrow for even a few letters. VoiceOver
/// reads the block's full label.
private struct CalendarCompactTitle: View {
    let title: String
    let showsWords: Bool

    var body: some View {
        Group {
            if showsWords {
                let lines = CompactTitle.lines(title, maxLines: 3)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index])
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            } else {
                Text(AvatarView.initials(from: title))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .font(Theme.Typography.caption.weight(.semibold))
    }
}
