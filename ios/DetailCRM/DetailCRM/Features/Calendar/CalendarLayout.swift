//
//  CalendarLayout.swift
//  DetailCRM
//
//  Pure layout math for the calendar (Foundation only, no SwiftUI):
//  which events fall on which shop-local day, where a block sits on a
//  24-hour timeline (wall-clock minutes in the SHOP time zone), and how
//  overlapping jobs share the width side by side.
//

import Foundation
import DetailCore

/// Agenda / Day / Week.
enum CalendarMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case agenda
    case day
    case week

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agenda: return "Agenda"
        case .day: return "Day"
        case .week: return "Week"
        }
    }
}

/// An event clipped to one day and placed on the timeline.
struct CalendarPlacedEvent: Identifiable, Hashable, Sendable {
    let event: CalendarEvent
    /// Wall-clock minutes since shop-local midnight, 0...1440.
    let startMinute: Int
    let endMinute: Int
    /// Side-by-side slot among overlapping events (0-based) and how many
    /// slots the overlapping group uses.
    let column: Int
    let columnCount: Int

    var id: String { event.key }
    var durationMinutes: Int { max(0, endMinute - startMinute) }
}

/// One day's timeline: job and event blocks (including anonymous busy
/// blocks) laid out in columns, and closed / time-off shaded behind them.
struct CalendarDayLayout: Identifiable, Hashable, Sendable {
    /// Shop-local midnight.
    let day: Date
    let blocks: [CalendarPlacedEvent]
    let shaded: [CalendarPlacedEvent]

    var id: Date { day }
}

/// Events of one day for the agenda list.
struct CalendarAgendaDay: Identifiable, Hashable, Sendable {
    let day: Date
    let events: [CalendarEvent]

    var id: Date { day }
}

enum CalendarLayoutEngine {

    static let minutesPerDay = 24 * 60
    /// Short jobs still get a tappable block.
    static let minimumBlockMinutes = 20

    // MARK: - Ranges

    /// The loaded range for a mode around `anchor` (shop-local days).
    static func range(for mode: CalendarMode, anchor: Date, clock: ShopClock) -> DateInterval {
        switch mode {
        case .day:
            return clock.dayInterval(containing: anchor)
        case .week:
            return clock.weekInterval(containing: anchor)
        case .agenda:
            let start = clock.startOfDay(anchor)
            return DateInterval(start: start, end: clock.addingDays(agendaDays, to: start))
        }
    }

    /// Days the agenda covers per page.
    static let agendaDays = 14

    /// The anchor after moving one page forward (`direction` 1) or back (-1).
    static func step(_ mode: CalendarMode, anchor: Date, direction: Int, clock: ShopClock) -> Date {
        switch mode {
        case .day: return clock.addingDays(direction, to: clock.startOfDay(anchor))
        case .week: return clock.addingDays(7 * direction, to: clock.startOfDay(anchor))
        case .agenda: return clock.addingDays(agendaDays * direction, to: clock.startOfDay(anchor))
        }
    }

    // MARK: - Agenda

    /// For each day in `days`, the events overlapping it (multi-day jobs
    /// appear on every day they touch), in start order. Days without
    /// events are dropped unless `keepEmptyDays`.
    static func agenda(
        events: [CalendarEvent],
        days: [Date],
        clock: ShopClock,
        keepEmptyDays: Bool = false
    ) -> [CalendarAgendaDay] {
        let sorted = events.sorted(by: CalendarService.startOrder)
        var result: [CalendarAgendaDay] = []
        for day in days {
            let interval = clock.dayInterval(containing: day)
            let onDay = sorted.filter { $0.overlaps(start: interval.start, end: interval.end) }
            if keepEmptyDays || !onDay.isEmpty {
                result.append(CalendarAgendaDay(day: interval.start, events: onDay))
            }
        }
        return result
    }

    // MARK: - Timeline

    /// Minute span of `event` on the day `[dayStart, dayEnd)`, or nil when
    /// it doesn't touch that day. Positions use the shop's wall clock so
    /// blocks line up with the hour labels (also on DST change days).
    static func minuteSpan(
        of event: CalendarEvent,
        dayStart: Date,
        dayEnd: Date,
        clock: ShopClock
    ) -> (start: Int, end: Int)? {
        guard event.overlaps(start: dayStart, end: dayEnd) else { return nil }
        var start = event.startsAt <= dayStart ? 0 : clock.minutesSinceMidnight(event.startsAt)
        var end = event.endsAt >= dayEnd ? minutesPerDay : clock.minutesSinceMidnight(event.endsAt)
        start = min(max(start, 0), minutesPerDay)
        end = min(max(end, 0), minutesPerDay)
        if end - start < minimumBlockMinutes {
            end = start + minimumBlockMinutes
            if end > minutesPerDay {
                end = minutesPerDay
                start = minutesPerDay - minimumBlockMinutes
            }
        }
        return (start, end)
    }

    /// Lays out one shop-local day.
    static func layoutDay(events: [CalendarEvent], day: Date, clock: ShopClock) -> CalendarDayLayout {
        let interval = clock.dayInterval(containing: day)
        var jobSpans: [CalendarSpan] = []
        var shaded: [CalendarPlacedEvent] = []
        for event in events {
            guard let span = minuteSpan(of: event, dayStart: interval.start, dayEnd: interval.end, clock: clock) else {
                continue
            }
            // Closed hours and time off shade the column; meetings,
            // consultations, reminders and other events sit with the jobs.
            if event.isBackgroundBlock {
                shaded.append(CalendarPlacedEvent(
                    event: event, startMinute: span.start, endMinute: span.end, column: 0, columnCount: 1
                ))
            } else {
                jobSpans.append(CalendarSpan(event: event, start: span.start, end: span.end))
            }
        }
        shaded.sort { lhs, rhs in
            if lhs.startMinute != rhs.startMinute { return lhs.startMinute < rhs.startMinute }
            return lhs.id < rhs.id
        }
        return CalendarDayLayout(day: interval.start, blocks: assignColumns(jobSpans), shaded: shaded)
    }

    /// Greedy interval partitioning: events that overlap (directly or
    /// through a chain) form a group; each gets the first free column in
    /// its group and the group's column count sets the block width.
    static func assignColumns(_ spans: [CalendarSpan]) -> [CalendarPlacedEvent] {
        let sorted = spans.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end > rhs.end }
            return lhs.event.key < rhs.event.key
        }
        var result: [CalendarPlacedEvent] = []
        var group: [(span: CalendarSpan, column: Int)] = []
        var columnEnds: [Int] = []
        var groupEnd = Int.min

        func flush() {
            let count = max(columnEnds.count, 1)
            for item in group {
                result.append(CalendarPlacedEvent(
                    event: item.span.event,
                    startMinute: item.span.start,
                    endMinute: item.span.end,
                    column: item.column,
                    columnCount: count
                ))
            }
            group.removeAll()
            columnEnds.removeAll()
            groupEnd = Int.min
        }

        for span in sorted {
            if !group.isEmpty && span.start >= groupEnd {
                flush()
            }
            var column = columnEnds.firstIndex(where: { $0 <= span.start }) ?? -1
            if column < 0 {
                column = columnEnds.count
                columnEnds.append(span.end)
            } else {
                columnEnds[column] = span.end
            }
            group.append((span: span, column: column))
            groupEnd = max(groupEnd, span.end)
        }
        if !group.isEmpty { flush() }
        return result
    }

    /// The hour to scroll to first: an hour before the earliest block of
    /// the given layouts, else 7 AM.
    static func initialScrollHour(for layouts: [CalendarDayLayout]) -> Int {
        let earliest = layouts
            .flatMap { $0.blocks }
            .map { $0.startMinute }
            .min()
        guard let earliest else { return 7 }
        return max(0, min(23, earliest / 60 - 1))
    }
}

/// An event with its minute span on one day (layout input).
struct CalendarSpan: Hashable, Sendable {
    let event: CalendarEvent
    let start: Int
    let end: Int
}
