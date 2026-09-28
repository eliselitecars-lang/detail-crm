//
//  TimeClockView.swift
//  DetailCRM
//
//  Clock in/out for the signed-in member: shift clock with a running
//  timer, an optional job timer for one of today's assigned jobs, and this
//  week's entries with totals (shop time zone). Managers and above also
//  get "Team time": who is clocked in now and editable timesheets.
//
//  The server stamps punch times, enforces one open entry per kind and
//  job assignment, and ends the job timer when the shift ends.
//

import SwiftUI
import DetailCore

/// Everything the Time Clock screen shows for the signed-in member.
struct TimeClockSnapshot: Equatable {
    var openShift: TimeEntry?
    var openJob: TimeEntry?
    var weekEntries: [TimeEntry]
    var week: DateInterval
    var jobOptions: [TimeClockJobOption]
    /// Set when today's jobs couldn't be loaded (the clock still works).
    var jobsError: String?
    var jobNumbers: [UUID: Int]
}

enum TimeClockLoader {

    static func snapshot(shopID: UUID, memberID: UUID, clock: ShopClock, now: Date = Date()) async throws -> TimeClockSnapshot {
        let week = clock.weekInterval(containing: now)
        async let openRows = TimeClockService.openEntries(shopID: shopID, memberID: memberID)
        async let weekRows = TimeClockService.entries(shopID: shopID, memberID: memberID, interval: week)
        let open = try await openRows
        let entries = try await weekRows

        var jobOptions: [TimeClockJobOption] = []
        var jobsError: String?
        do {
            jobOptions = try await TimeClockService.clockableJobsToday(shopID: shopID, memberID: memberID, clock: clock, now: now)
        } catch {
            jobsError = ErrorText.message(for: error)
        }

        var jobIDs: [UUID] = entries.compactMap { $0.jobID }
        jobIDs.append(contentsOf: open.compactMap { $0.jobID })
        let numbers = (try? await TimeClockService.jobNumbers(shopID: shopID, jobIDs: jobIDs)) ?? [:]

        return TimeClockSnapshot(
            openShift: open.first { $0.kind == .shift },
            openJob: open.first { $0.kind == .job },
            weekEntries: entries,
            week: week,
            jobOptions: jobOptions,
            jobsError: jobsError,
            jobNumbers: numbers
        )
    }
}

struct TimeClockView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(JobsRealtimeHub.self) private var realtime
    @State private var state: LoadState<TimeClockSnapshot> = .idle
    @State private var selectedJobID: UUID?

    var body: some View {
        LoadStateView(state, loadingLabel: "Loading your time…", retry: { await load() }) { snapshot in
            TimeClockContent(
                snapshot: snapshot,
                clock: appState.clock,
                canManageTeamTime: appState.can(.viewAllTimeEntries),
                selectedJobID: $selectedJobID,
                clockIn: { jobID in await clockIn(jobID: jobID) },
                clockOut: { kind in await clockOut(kind: kind) }
            )
        }
        .screenBackground()
        .navigationTitle("Time Clock")
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: realtime.revision(.timeEntries)) { _, _ in
            Task { await load() }
        }
    }

    private func load() async {
        guard let shopID = appState.shop?.id, let memberID = appState.member?.id else {
            state = .failed(AppError.noShopSelected.errorDescription ?? "Choose a shop first.")
            return
        }
        let clock = appState.clock
        state.beginLoading()
        let result = await LoadState<TimeClockSnapshot>.result {
            try await TimeClockLoader.snapshot(shopID: shopID, memberID: memberID, clock: clock)
        }
        if let message = result.errorMessage, state.value != nil {
            toasts.show(message, style: .error)
        }
        state.apply(result)
        if let snapshot = state.value, let selected = selectedJobID,
           !snapshot.jobOptions.contains(where: { $0.id == selected }) {
            selectedJobID = nil
        }
    }

    /// Clock in with the device location when the member allows it (P-24);
    /// without one the punch still goes through.
    private func clockIn(jobID: UUID?) async {
        do {
            let shopID = try appState.requireShopID()
            let spot = await OpsClockLocationProvider.shared.currentSpot()
            _ = try await TimeClockService.clockIn(shopID: shopID, jobID: jobID, location: spot)
            toasts.show(punchMessage(jobID == nil ? "Clocked in." : "Job timer started.", spot: spot))
        } catch {
            toasts.showError(error)
        }
        await load()
    }

    private func clockOut(kind: TimeEntryKind) async {
        do {
            let shopID = try appState.requireShopID()
            let spot = await OpsClockLocationProvider.shared.currentSpot()
            _ = try await TimeClockService.clockOut(shopID: shopID, kind: kind, location: spot)
            toasts.show(punchMessage(kind == .shift ? "Clocked out." : "Job timer stopped.", spot: spot))
        } catch {
            toasts.showError(error)
        }
        await load()
    }

    private func punchMessage(_ base: String, spot: TimeEntry.Spot?) -> String {
        OpsClockLocationProvider.shared.punchMessage(base, spot: spot)
    }
}

/// The loaded screen: shift, job timer, this week, team time.
private struct TimeClockContent: View {
    let snapshot: TimeClockSnapshot
    let clock: ShopClock
    let canManageTeamTime: Bool
    @Binding var selectedJobID: UUID?
    let clockIn: (UUID?) async -> Void
    let clockOut: (TimeEntryKind) async -> Void

    var body: some View {
        List {
            Section {
                TimeClockShiftCard(openShift: snapshot.openShift, clock: clock, clockIn: clockIn, clockOut: clockOut)
                    .themedRow()
            } header: {
                Text("Shift")
            } footer: {
                Text("Clocking in or out on this screen records where you are (if you allow location access), so your manager can see where the punch happened. Location is read only at that moment.")
            }
            Section {
                TimeClockJobCard(
                    openJob: snapshot.openJob,
                    options: snapshot.jobOptions,
                    jobsError: snapshot.jobsError,
                    jobNumbers: snapshot.jobNumbers,
                    clock: clock,
                    selectedJobID: $selectedJobID,
                    clockIn: clockIn,
                    clockOut: clockOut
                )
                .themedRow()
            } header: {
                Text("Job timer")
            } footer: {
                Text("Optional. Track time on one of today's jobs assigned to you. Ending your shift also stops the job timer.")
            }
            TimeClockWeekSection(entries: snapshot.weekEntries, week: snapshot.week, clock: clock, jobNumbers: snapshot.jobNumbers)
            if canManageTeamTime {
                Section {
                    NavigationLink {
                        TimeClockTeamView()
                    } label: {
                        Label("Team time & timesheets", systemImage: "person.2")
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .themedRow()
                } header: {
                    Text("Team")
                } footer: {
                    Text("See who's clocked in, and add or correct entries.")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// Shift status with a running timer and the clock in/out button.
private struct TimeClockShiftCard: View {
    let openShift: TimeEntry?
    let clock: ShopClock
    let clockIn: (UUID?) async -> Void
    let clockOut: (TimeEntryKind) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(openShift == nil ? "Off the clock" : "On the clock")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Theme.Spacing.sm)
                StatusBadge(text: openShift == nil ? "Clocked out" : "Clocked in",
                            tone: openShift == nil ? .neutral : .success)
            }
            TimeClockRunningTimer(entry: openShift, clock: clock)
            if openShift == nil {
                AsyncButton("Clock in", style: .themePrimary) {
                    await clockIn(nil)
                }
            } else {
                AsyncButton("Clock out", style: .themeSecondary) {
                    await clockOut(.shift)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

/// Big elapsed-time readout for an open entry (always in the hierarchy).
struct TimeClockRunningTimer: View {
    let entry: TimeEntry?
    let clock: ShopClock

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                Text(TimeEntry.timerText(seconds: entry?.durationSeconds(now: context.date) ?? 0))
                    .font(Theme.Typography.largeTitle.monospacedDigit())
                    .foregroundStyle(entry == nil ? Theme.textTertiary : Theme.textPrimary)
                    .accessibilityLabel(accessibilityText(now: context.date))
            }
            Text(sinceText)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var sinceText: String {
        guard let entry else { return "Not running" }
        return "Since \(clock.relativeDayText(entry.clockIn)), \(clock.timeText(entry.clockIn))"
    }

    private func accessibilityText(now: Date) -> String {
        guard let entry else { return "Timer not running" }
        return "Running for \(TimeEntry.durationText(seconds: entry.durationSeconds(now: now)))"
    }
}

/// Job timer: running job, or a picker of today's assigned jobs.
private struct TimeClockJobCard: View {
    let openJob: TimeEntry?
    let options: [TimeClockJobOption]
    let jobsError: String?
    let jobNumbers: [UUID: Int]
    let clock: ShopClock
    @Binding var selectedJobID: UUID?
    let clockIn: (UUID?) async -> Void
    let clockOut: (TimeEntryKind) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if let openJob {
                Text(runningJobTitle(openJob))
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                TimeClockRunningTimer(entry: openJob, clock: clock)
                AsyncButton("Stop job timer", style: .themeSecondary) {
                    await clockOut(.job)
                }
            } else if let jobsError {
                InlineMessage(text: "Couldn't load today's jobs. \(jobsError)", kind: .error)
            } else if options.isEmpty {
                InlineMessage(text: "No jobs are assigned to you today.", kind: .info)
            } else {
                Picker("Job", selection: $selectedJobID) {
                    Text("Choose a job").tag(UUID?.none)
                    ForEach(options) { option in
                        Text(optionTitle(option)).tag(UUID?.some(option.id))
                    }
                }
                .pickerStyle(.menu)
                AsyncButton("Start job timer", style: .themePrimary) {
                    await clockIn(selectedJobID)
                }
                .disabled(selectedJobID == nil)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func runningJobTitle(_ entry: TimeEntry) -> String {
        if let jobID = entry.jobID, let option = options.first(where: { $0.id == jobID }) {
            return "Working on \(option.label)"
        }
        if let jobID = entry.jobID, let number = jobNumbers[jobID] {
            return "Working on job #\(number)"
        }
        return "Working on a job"
    }

    private func optionTitle(_ option: TimeClockJobOption) -> String {
        guard let start = option.startsAt else { return option.label }
        return "\(clock.timeText(start)) · \(option.label)"
    }
}

/// This week's entries (shop week) with shift/job totals and per-entry rows.
private struct TimeClockWeekSection: View {
    let entries: [TimeEntry]
    let week: DateInterval
    let clock: ShopClock
    let jobNumbers: [UUID: Int]

    var body: some View {
        Section {
            TimelineView(.periodic(from: Date(), by: 60)) { context in
                TimeClockTotalsRow(entries: entries, now: context.date)
            }
            .themedRow()
            if entries.isEmpty {
                Text("No time recorded this week.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .themedRow()
            } else {
                ForEach(entries) { entry in
                    TimeClockEntryRow(entry: entry, clock: clock, jobNumber: entry.jobID.flatMap { jobNumbers[$0] }, memberName: nil)
                        .themedRow()
                }
            }
        } header: {
            Text("This week · \(clock.shortDayText(week.start)) – \(clock.shortDayText(clock.addingDays(-1, to: week.end)))")
        }
    }
}

/// "Shift time / Job time" totals (open entries count up to `now`).
struct TimeClockTotalsRow: View {
    let entries: [TimeEntry]
    let now: Date

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            TimeClockTotalTile(title: "Shift time", value: TimeEntry.durationText(seconds: shiftSeconds))
            TimeClockTotalTile(title: "Job time", value: TimeEntry.durationText(seconds: jobSeconds))
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var shiftSeconds: Int {
        TimeEntry.totalSeconds(entries.filter { $0.kind == .shift }, now: now)
    }

    private var jobSeconds: Int {
        TimeEntry.totalSeconds(entries.filter { $0.kind == .job }, now: now)
    }
}

private struct TimeClockTotalTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(title.uppercased())
                .font(Theme.Typography.eyebrow)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(Theme.Typography.sectionTitle.monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One time entry: day, time range, duration, kind, job and notes.
struct TimeClockEntryRow: View {
    let entry: TimeEntry
    let clock: ShopClock
    let jobNumber: Int?
    let memberName: String?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                if let memberName {
                    Text(memberName)
                        .font(Theme.Typography.bodyEmphasis)
                        .foregroundStyle(Theme.textPrimary)
                }
                Text(clock.shortDayText(entry.clockIn))
                    .font(memberName == nil ? Theme.Typography.bodyEmphasis : Theme.Typography.subheadline)
                    .foregroundStyle(memberName == nil ? Theme.textPrimary : Theme.textSecondary)
                Text(rangeText)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                if let notes = entry.notes?.trimmedNonEmpty {
                    Text(notes)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                Text(entry.isOpen ? "Running" : TimeEntry.durationText(seconds: entry.durationSeconds()))
                    .font(Theme.Typography.bodyEmphasis.monospacedDigit())
                    .foregroundStyle(entry.isOpen ? Theme.success : Theme.textPrimary)
                StatusBadge(text: kindText, tone: entry.kind == .shift ? .neutral : .info)
                if entry.source == .manual {
                    Text("Manual")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }

    private var kindText: String {
        if entry.kind == .job, let jobNumber { return "Job #\(jobNumber)" }
        return entry.kind.displayName
    }

    private var rangeText: String {
        guard let clockOut = entry.clockOut else {
            return "\(clock.timeText(entry.clockIn)) – now"
        }
        return clock.rangeText(from: entry.clockIn, to: clockOut)
    }
}
