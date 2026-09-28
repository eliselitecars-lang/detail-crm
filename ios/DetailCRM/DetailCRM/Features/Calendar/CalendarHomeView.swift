//
//  CalendarHomeView.swift
//  DetailCRM
//
//  Calendar tab: Agenda / Day / Week over `calendar_events` for the
//  visible range, in the SHOP time zone. Prev / next / Today / jump to a
//  date; the + menu (managers+) adds a job or a calendar event (time off,
//  meeting, consultation, reminder, closed), and managers tap an event to
//  edit it. The map button opens the day's mobile route. Technicians see
//  other people's jobs as anonymous busy blocks — the server decides that,
//  this screen only renders it. Realtime job changes refresh the range.
//

import SwiftUI
import DetailCore

/// Events loaded for one visible range (the range travels with the data
/// so a late response for an old range is never shown for a new one).
struct CalendarRangeData: Hashable, Sendable {
    let range: DateInterval
    let includeCancelled: Bool
    let events: [CalendarEvent]
}

struct CalendarHomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(JobsRealtimeHub.self) private var realtime

    @State private var mode: CalendarMode = .day
    @State private var anchor: Date = Date()
    @State private var includeCancelled = false
    @State private var state: LoadState<CalendarRangeData> = .idle
    @State private var memberColors: [UUID: String] = [:]
    @State private var showingDatePicker = false
    @State private var showingNewJob = false
    @State private var newJobStart: Date?
    @State private var eventSheet: JobsCalendarEventSheet.Target?

    private var clock: ShopClock { appState.clock }

    private var range: DateInterval {
        CalendarLayoutEngine.range(for: mode, anchor: anchor, clock: clock)
    }

    private var loadKey: String {
        "\(mode.rawValue)|\(range.start.timeIntervalSince1970)|\(includeCancelled)"
    }

    private var isShowingToday: Bool {
        let now = Date()
        if mode == .agenda { return clock.isSameDay(anchor, now) }
        return range.contains(now)
    }

    var body: some View {
        VStack(spacing: 0) {
            CalendarControlBar(
                mode: $mode,
                title: CalendarFormat.rangeTitle(mode: mode, range: range, clock: clock),
                isShowingToday: isShowingToday,
                onPrevious: { move(-1) },
                onNext: { move(1) },
                onToday: { anchor = clock.startOfDay(Date()) },
                onPickDate: { showingDatePicker = true }
            )
            Rectangle()
                .fill(Theme.border)
                .frame(height: Theme.Size.hairline)
            content
        }
        .screenBackground()
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        // Also re-runs whenever the tab / stack root reappears (back from a
        // job, tab switch); load() only blanks the screen when the range or
        // filter actually changed, otherwise it refreshes in place.
        .task(id: loadKey) { await load(reset: true) }
        .task { await loadTeamColors() }
        .sheet(isPresented: $showingDatePicker) {
            CalendarDatePickerSheet(clock: clock, initialDate: anchor) { day in
                anchor = day
            }
        }
        .sheet(isPresented: $showingNewJob, onDismiss: {
            Task { await load(reset: false) }
        }) {
            NewJobView(prefillStart: newJobStart, prefillCustomerID: nil)
        }
        .sheet(item: $eventSheet) { target in
            JobsCalendarEventSheet(target: target) {
                Task { await load(reset: false) }
            }
        }
        // Someone scheduled, moved or cancelled a job (Realtime).
        .onChange(of: realtime.revision(.jobs)) { _, _ in
            Task { await load(reset: false) }
        }
    }

    /// Managers open calendar events to edit them.
    private var openEvent: ((CalendarEvent) -> Void)? {
        guard appState.can(.editJobs) else { return nil }
        return { event in eventSheet = .edit(event.id) }
    }

    // MARK: - Content (AnyView seam: the mode views are large generic trees)

    private var content: AnyView {
        let currentRange = range
        let currentMode = mode
        let cancelledShown = includeCancelled
        let currentClock = clock
        let colors = memberColors
        let onOpenEvent = openEvent
        return AnyView(
            LoadStateView(state, loadingLabel: "Loading calendar…", retry: { await load(reset: true) }) { data in
                if data.range == currentRange && data.includeCancelled == cancelledShown {
                    CalendarModeContent(
                        mode: currentMode,
                        data: data,
                        clock: currentClock,
                        memberColors: colors,
                        onRefresh: { await load(reset: false) },
                        onSelectDay: { day in
                            anchor = day
                            mode = .day
                        },
                        onOpenEvent: onOpenEvent
                    )
                } else {
                    LoadingStateView(label: "Loading calendar…")
                }
            }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Toggle("Show cancelled jobs", isOn: $includeCancelled)
            } label: {
                Image(systemName: includeCancelled
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Calendar filters")
        }
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                JobsDayMapView(day: mapDay)
            } label: {
                Image(systemName: "map")
            }
            .accessibilityLabel("Map of the day's mobile jobs")
        }
        ToolbarItem(placement: .topBarTrailing) {
            if appState.can(.createJobs) {
                Menu {
                    Button {
                        newJobStart = suggestedNewJobStart()
                        showingNewJob = true
                    } label: {
                        Label("New job", systemImage: "wrench.and.screwdriver")
                    }
                    Button {
                        eventSheet = .new(start: suggestedEventStart())
                    } label: {
                        Label("New event or time off", systemImage: "calendar.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add to the calendar")
            }
        }
    }

    /// The day the map opens on: the shown day in Day mode, else today.
    private var mapDay: Date {
        mode == .day ? clock.startOfDay(anchor) : clock.startOfDay(Date())
    }

    /// 9:00 on the shown day (Day mode), else the next whole hour.
    private func suggestedEventStart() -> Date {
        if mode == .day, !clock.isSameDay(anchor, Date()), let nine = clock.date(on: anchor, timeString: "09:00") {
            return nine
        }
        let now = Date()
        let hour = clock.calendar.dateInterval(of: .hour, for: now)?.end ?? now
        return hour
    }

    // MARK: - Actions

    private func move(_ direction: Int) {
        anchor = CalendarLayoutEngine.step(mode, anchor: anchor, direction: direction, clock: clock)
    }

    /// A day other than today in Day mode pre-fills 9:00 that day; otherwise
    /// the New Job flow picks the time.
    private func suggestedNewJobStart() -> Date? {
        guard mode == .day, !clock.isSameDay(anchor, Date()) else { return nil }
        return clock.date(on: anchor, timeString: "09:00")
    }

    // MARK: - Loading

    private func load(reset: Bool) async {
        let shopID: UUID
        do {
            shopID = try appState.requireShopID()
        } catch {
            state = .failed(ErrorText.message(for: error))
            return
        }
        let requestedRange = range
        let cancelled = includeCancelled
        // `reset` asks for a spinner only when what is on screen belongs to
        // another range / filter. Reappearing on the same range keeps the
        // loaded calendar (and the timeline's scroll position) visible, and
        // a failed refetch then shows a toast instead of the error screen.
        let showsSameKey = state.value.map {
            $0.range == requestedRange && $0.includeCancelled == cancelled
        } ?? false
        if reset && !showsSameKey {
            state = .loading
        } else {
            state.beginLoading()
        }
        let hadContent = state.value != nil
        let result = await LoadState<CalendarRangeData>.result {
            let events = try await CalendarService.events(
                shopID: shopID,
                from: requestedRange.start,
                to: requestedRange.end,
                includeCancelled: cancelled
            )
            return CalendarRangeData(range: requestedRange, includeCancelled: cancelled, events: events)
        }
        // The user moved on while this was loading: a newer load owns the state.
        guard requestedRange == range, cancelled == includeCancelled else { return }
        if hadContent, let message = result.errorMessage {
            toasts.show(message, style: .error, duration: .seconds(5))
        }
        state.apply(result)
    }

    /// Member colors tint job blocks; without them blocks use the accent.
    private func loadTeamColors() async {
        guard let shopID = try? appState.requireShopID() else { return }
        do {
            let team = try await CalendarService.team(shopID: shopID)
            var colors: [UUID: String] = [:]
            for member in team {
                if let hex = member.calendarColor { colors[member.memberID] = hex }
            }
            memberColors = colors
        } catch {
            // Decorative only: the calendar stays fully usable with default colors.
            memberColors = [:]
        }
    }
}

/// Switches between the three modes for loaded data.
private struct CalendarModeContent: View {
    let mode: CalendarMode
    let data: CalendarRangeData
    let clock: ShopClock
    let memberColors: [UUID: String]
    let onRefresh: () async -> Void
    let onSelectDay: (Date) -> Void
    let onOpenEvent: ((CalendarEvent) -> Void)?

    var body: some View {
        switch mode {
        case .agenda:
            AnyView(
                CalendarAgendaView(
                    days: CalendarLayoutEngine.agenda(
                        events: data.events,
                        days: clock.days(from: data.range.start, to: data.range.end),
                        clock: clock
                    ),
                    clock: clock,
                    memberColors: memberColors,
                    onRefresh: onRefresh,
                    onOpenEvent: onOpenEvent
                )
            )
        case .day, .week:
            AnyView(
                CalendarTimelineView(
                    layouts: dayLayouts,
                    compact: mode == .week,
                    clock: clock,
                    memberColors: memberColors,
                    onRefresh: onRefresh,
                    onSelectDay: onSelectDay,
                    onOpenEvent: onOpenEvent
                )
                // One identity per mode + range: a new range (or Day <-> Week
                // on the same start) gets a fresh timeline and first-hour scroll.
                .id("\(mode.rawValue)|\(data.range.start.timeIntervalSince1970)")
            )
        }
    }

    private var dayLayouts: [CalendarDayLayout] {
        clock.days(from: data.range.start, to: data.range.end).map { day in
            CalendarLayoutEngine.layoutDay(events: data.events, day: day, clock: clock)
        }
    }
}
