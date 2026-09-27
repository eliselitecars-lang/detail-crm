//
//  CalendarComponents.swift
//  DetailCRM
//
//  Small building blocks shared by the calendar screens: date text in the
//  shop time zone, event colors, the date navigation bar and the
//  "jump to date" sheet.
//

import SwiftUI
import DetailCore

// MARK: - Formatting (shop time zone)

enum CalendarFormat {

    /// "7 AM" style hour label. Built from a fixed UTC reference so DST
    /// gaps never repeat or skip a label.
    static func hourLabel(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .current
        formatter.setLocalizedDateFormatFromTemplate("j")
        let clamped = min(max(hour, 0), 23)
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(clamped * 3600)))
    }

    /// "Mon" in the shop zone.
    static func weekdayShort(_ date: Date, clock: ShopClock) -> String {
        format(date, template: "EEE", clock: clock)
    }

    /// "27" in the shop zone.
    static func dayNumber(_ date: Date, clock: ShopClock) -> String {
        format(date, template: "d", clock: clock)
    }

    /// Toolbar title for the visible range.
    static func rangeTitle(mode: CalendarMode, range: DateInterval, clock: ShopClock, now: Date = Date()) -> String {
        switch mode {
        case .day:
            let relative = clock.relativeDayText(range.start, now: now)
            let short = clock.shortDayText(range.start)
            return relative == short ? short : "\(relative) · \(short)"
        case .week, .agenda:
            let lastDay = clock.addingDays(-1, to: range.end)
            return "\(clock.shortDayText(range.start)) – \(clock.shortDayText(lastDay))"
        }
    }

    /// "9:00 – 11:00 AM", with dates when the event spans days.
    static func timeRange(_ event: CalendarEvent, clock: ShopClock) -> String {
        clock.rangeText(from: event.startsAt, to: event.endsAt)
    }

    private static func format(_ date: Date, template: String, clock: ShopClock) -> String {
        let formatter = DateFormatter()
        formatter.locale = clock.locale
        formatter.timeZone = clock.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

// MARK: - Colors

enum CalendarPalette {

    /// Accent for an event: the first assigned member's calendar color,
    /// muted for busy blocks / blocked time, danger for cancelled/no-show.
    static func color(for event: CalendarEvent, memberColors: [UUID: String]) -> Color {
        if event.isBlockedTime || event.isBusyBlock {
            return Theme.textTertiary
        }
        if let status = event.status, status.isSideExit {
            return Theme.danger
        }
        for memberID in event.assignedMemberIDs {
            if let hex = memberColors[memberID], let color = Color(hexString: hex) {
                return color
            }
        }
        return Theme.glacier
    }
}

// MARK: - Accessibility

enum CalendarAccessibility {

    static func label(for event: CalendarEvent, clock: ShopClock) -> String {
        var parts: [String] = [event.displayTitle, CalendarFormat.timeRange(event, clock: clock)]
        if event.isBlockedTime {
            parts.insert("Blocked time", at: 0)
        }
        if let status = event.status, event.isOpenableJob {
            parts.append(status.displayName)
        }
        if let vehicle = event.vehicleLabel?.trimmedNonEmpty {
            parts.append(vehicle)
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Date navigation bar

struct CalendarControlBar: View {
    @Binding var mode: CalendarMode
    let title: String
    let isShowingToday: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onToday: () -> Void
    let onPickDate: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                Button(action: onPrevious) {
                    Image(systemName: "chevron.left")
                        .font(Theme.Typography.bodyEmphasis)
                        .frame(width: Theme.Size.compactControlHeight, height: Theme.Size.compactControlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.glacier)
                .accessibilityLabel("Previous")

                Button(action: onPickDate) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(title)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Image(systemName: "chevron.down")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Theme.Size.compactControlHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title). Choose a date")

                Button(action: onNext) {
                    Image(systemName: "chevron.right")
                        .font(Theme.Typography.bodyEmphasis)
                        .frame(width: Theme.Size.compactControlHeight, height: Theme.Size.compactControlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.glacier)
                .accessibilityLabel("Next")

                Button("Today", action: onToday)
                    .buttonStyle(.themeSecondaryCompact)
                    .disabled(isShowingToday)
            }

            Picker("View", selection: $mode) {
                ForEach(CalendarMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.sm)
        .background(Theme.background)
    }
}

// MARK: - Jump to date

struct CalendarDatePickerSheet: View {
    let clock: ShopClock
    let initialDate: Date
    let onPick: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Date = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.lg) {
                DatePicker("Date", selection: $selection, displayedComponents: [.date])
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .environment(\.timeZone, clock.timeZone)
                    .tint(Theme.glacier)
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.gutter)
            .screenBackground()
            .navigationTitle("Go to date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") {
                        onPick(clock.startOfDay(selection))
                        dismiss()
                    }
                }
            }
        }
        .onAppear { selection = initialDate }
        .presentationDetents([.medium, .large])
    }
}
