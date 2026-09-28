//
//  TimeClockTeamView.swift
//  DetailCRM
//
//  Managers and above: who is clocked in right now, and one member's
//  timesheet for a shop week with add / edit / delete. Punches made in the
//  app carry the device location when the member allowed it (P-24); each
//  one links to Maps. The server rejects
//  overlapping entries and a second open entry of the same kind; those
//  errors are shown in the editor.
//

import SwiftUI
import DetailCore

/// Directory + currently open entries.
struct TimeClockTeamSnapshot: Equatable {
    var members: [TeamDirectoryEntry]
    var openEntries: [TimeEntry]

    func name(for memberID: UUID) -> String {
        members.first { $0.memberID == memberID }?.displayName ?? "Former member"
    }
}

/// Identity of the timesheet being shown (reloads when it changes).
struct TimeClockSheetKey: Equatable {
    var memberID: UUID?
    var weekStart: Date
}

struct TimeClockTeamView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(JobsRealtimeHub.self) private var realtime
    @State private var state: LoadState<TimeClockTeamSnapshot> = .idle
    @State private var selectedMemberID: UUID?
    @State private var weekStart: Date = Date()
    @State private var sheet: LoadState<[TimeEntry]> = .idle
    @State private var jobNumbers: [UUID: Int] = [:]
    @State private var editor: TimeClockEditorMode?
    @State private var confirmation: ConfirmationRequest?
    @State private var didSetWeek = false

    var body: some View {
        LoadStateView(state, loadingLabel: "Loading team time…", retry: { await loadTeam() }) { snapshot in
            teamList(snapshot)
        }
        .screenBackground()
        .navigationTitle("Team time")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let memberID = selectedMemberID {
                        editor = .add(memberID: memberID)
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(selectedMemberID == nil || !appState.can(.editTimeEntries))
                .accessibilityLabel("Add time entry")
            }
        }
        .sheet(item: $editor) { mode in
            TimeClockEntryEditor(
                mode: mode,
                memberName: memberName(for: mode),
                clock: appState.clock
            ) {
                await reloadSheet()
                await loadTeam()
            }
        }
        .confirmation($confirmation)
        .task {
            if !didSetWeek {
                weekStart = appState.clock.totalsWeekInterval(containing: Date()).start
                didSetWeek = true
            }
            await loadTeam()
        }
        .task(id: TimeClockSheetKey(memberID: selectedMemberID, weekStart: weekStart)) {
            await reloadSheet()
        }
        .refreshable {
            await loadTeam()
            await reloadSheet()
        }
        .onChange(of: realtime.revision(.timeEntries)) { _, _ in
            Task {
                await loadTeam()
                await reloadSheet(quietly: true)
            }
        }
    }

    private func teamList(_ snapshot: TimeClockTeamSnapshot) -> some View {
        List {
            TimeClockOpenNowSection(snapshot: snapshot, clock: appState.clock)
            Section {
                Picker("Team member", selection: $selectedMemberID) {
                    Text("Choose someone").tag(UUID?.none)
                    ForEach(snapshot.members) { member in
                        Text(member.active ? member.displayName : "\(member.displayName) (inactive)")
                            .tag(UUID?.some(member.memberID))
                    }
                }
                .themedRow()
                TimeClockWeekStepper(weekStart: $weekStart, clock: appState.clock)
                    .themedRow()
            } header: {
                Text("Timesheet")
            }
            TimeClockSheetSection(
                state: sheet,
                hasMember: selectedMemberID != nil,
                clock: appState.clock,
                week: appState.clock.totalsWeekInterval(containing: weekStart),
                jobNumbers: jobNumbers,
                canEdit: appState.can(.editTimeEntries),
                retry: { await reloadSheet() },
                edit: { entry in editor = .edit(entry) },
                delete: { entry in confirmDelete(entry) }
            )
        }
        .listStyle(.insetGrouped)
    }

    private func memberName(for mode: TimeClockEditorMode) -> String {
        guard let snapshot = state.value else { return "Team member" }
        switch mode {
        case .add(let memberID):
            return snapshot.name(for: memberID)
        case .edit(let entry):
            return snapshot.name(for: entry.memberID)
        }
    }

    private func loadTeam() async {
        guard let shopID = appState.shop?.id else {
            state = .failed(AppError.noShopSelected.errorDescription ?? "Choose a shop first.")
            return
        }
        state.beginLoading()
        let result = await LoadState<TimeClockTeamSnapshot>.result {
            async let members = TeamService.directory(shopID: shopID)
            async let open = TimeClockService.openEntriesForShop(shopID: shopID)
            return try await TimeClockTeamSnapshot(members: members, openEntries: open)
        }
        if let message = result.errorMessage, state.value != nil {
            toasts.show(message, style: .error)
        }
        state.apply(result)
        if selectedMemberID == nil, let snapshot = state.value {
            selectedMemberID = snapshot.members.first { $0.memberID == appState.member?.id }?.memberID
                ?? snapshot.members.first?.memberID
        }
    }

    /// `quietly`: a live refresh keeps the current rows on screen until the
    /// new ones arrive.
    private func reloadSheet(quietly: Bool = false) async {
        guard let shopID = appState.shop?.id, let memberID = selectedMemberID else {
            sheet = .idle
            return
        }
        let clock = appState.clock
        let interval = clock.totalsWeekInterval(containing: weekStart)
        if quietly {
            sheet.beginLoading()
        } else {
            sheet = .loading
        }
        let result = await LoadState<[TimeEntry]>.result {
            try await TimeClockService.entries(shopID: shopID, memberID: memberID, interval: interval)
        }
        sheet.apply(result)
        if let entries = sheet.value {
            let ids = entries.compactMap { $0.jobID }
            if let numbers = try? await TimeClockService.jobNumbers(shopID: shopID, jobIDs: ids) {
                jobNumbers.merge(numbers) { _, new in new }
            }
        }
    }

    private func confirmDelete(_ entry: TimeEntry) {
        let clock = appState.clock
        confirmation = ConfirmationRequest(
            title: "Delete this entry?",
            message: "\(entry.kind.displayName) on \(clock.shortDayText(entry.clockIn)). This can't be undone.",
            confirmTitle: "Delete",
            isDestructive: true
        ) {
            do {
                let shopID = try appState.requireShopID()
                try await TimeClockService.deleteEntry(shopID: shopID, entryID: entry.id)
                toasts.show("Entry deleted.")
            } catch {
                toasts.showError(error)
            }
            await reloadSheet()
            await loadTeam()
        }
    }
}

/// Everyone with an open shift or job timer.
private struct TimeClockOpenNowSection: View {
    let snapshot: TimeClockTeamSnapshot
    let clock: ShopClock

    var body: some View {
        Section {
            if snapshot.openEntries.isEmpty {
                Text("Nobody is clocked in right now.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .themedRow()
            } else {
                ForEach(snapshot.openEntries) { entry in
                    TimeClockOpenRow(
                        name: snapshot.name(for: entry.memberID),
                        colorHex: snapshot.members.first { $0.memberID == entry.memberID }?.calendarColor,
                        entry: entry,
                        clock: clock
                    )
                    .themedRow()
                }
            }
        } header: {
            Text("Clocked in now")
        }
    }
}

private struct TimeClockOpenRow: View {
    let name: String
    let colorHex: String?
    let entry: TimeEntry
    let clock: ShopClock

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            summary
            if let url = entry.clockInSpot?.mapURL(label: "\(name) clocked in") {
                Link(destination: url) {
                    Image(systemName: "mappin.circle")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.glacier)
                        .frame(width: Theme.Size.compactControlHeight, height: Theme.Size.compactControlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Show where \(name) clocked in on the map")
            }
        }
    }

    private var summary: some View {
        HStack(spacing: Theme.Spacing.md) {
            AvatarView(name: name, size: Theme.Size.avatarSmall, colorHex: colorHex)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(name)
                    .font(Theme.Typography.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(entry.kind.displayName) since \(clock.relativeDayText(entry.clockIn)), \(clock.timeText(entry.clockIn))")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            TimelineView(.periodic(from: Date(), by: 60)) { context in
                Text(TimeEntry.durationText(seconds: entry.durationSeconds(now: context.date)))
                    .font(Theme.Typography.bodyEmphasis.monospacedDigit())
                    .foregroundStyle(Theme.successInk)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "‹ Sep 21 – Sep 27 ›" week navigation in the shop time zone.
private struct TimeClockWeekStepper: View {
    @Binding var weekStart: Date
    let clock: ShopClock

    var body: some View {
        HStack {
            Button {
                weekStart = clock.addingDays(-7, to: clock.totalsWeekInterval(containing: weekStart).start)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: Theme.Size.compactControlHeight, height: Theme.Size.compactControlHeight)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.glacier)
            .accessibilityLabel("Previous week")
            Spacer(minLength: Theme.Spacing.sm)
            Text(label)
                .font(Theme.Typography.bodyEmphasis)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Spacer(minLength: Theme.Spacing.sm)
            Button {
                weekStart = clock.addingDays(7, to: clock.totalsWeekInterval(containing: weekStart).start)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: Theme.Size.compactControlHeight, height: Theme.Size.compactControlHeight)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.glacier)
            .accessibilityLabel("Next week")
        }
    }

    private var label: String {
        let week = clock.totalsWeekInterval(containing: weekStart)
        return "\(clock.shortDayText(week.start)) – \(clock.shortDayText(clock.addingDays(-1, to: week.end)))"
    }
}

/// The selected member's entries for the week, with totals.
private struct TimeClockSheetSection: View {
    let state: LoadState<[TimeEntry]>
    let hasMember: Bool
    let clock: ShopClock
    /// The shop week the sheet shows; totals count only the part of each
    /// entry inside it.
    let week: DateInterval
    let jobNumbers: [UUID: Int]
    let canEdit: Bool
    let retry: () async -> Void
    let edit: (TimeEntry) -> Void
    let delete: (TimeEntry) -> Void

    var body: some View {
        Section {
            if !hasMember {
                Text("Choose a team member to see their timesheet.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .themedRow()
            } else {
                switch state {
                case .idle, .loading:
                    HStack(spacing: Theme.Spacing.sm) {
                        ProgressView()
                        Text("Loading entries…")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .themedRow()
                case .failed(let message):
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        InlineMessage(text: message, kind: .error)
                        AsyncButton("Try again", style: .themeSecondaryCompact) {
                            await retry()
                        }
                    }
                    .themedRow()
                case .loaded(let entries):
                    TimelineView(.periodic(from: Date(), by: 60)) { context in
                        TimeClockTotalsRow(entries: entries, range: week, now: context.date)
                    }
                    .themedRow()
                    if entries.isEmpty {
                        Text("No entries this week.")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .themedRow()
                    } else {
                        ForEach(entries) { entry in
                            TimeClockSheetRow(
                                entry: entry,
                                clock: clock,
                                week: week,
                                jobNumber: entry.jobID.flatMap { jobNumbers[$0] },
                                canEdit: canEdit,
                                edit: edit,
                                delete: delete
                            )
                            .themedRow()
                        }
                    }
                }
            }
        } header: {
            Text("Entries")
        } footer: {
            Text(canEdit ? "Tap an entry to correct it. Swipe to delete." : "")
        }
    }
}

private struct TimeClockSheetRow: View {
    let entry: TimeEntry
    let clock: ShopClock
    let week: DateInterval
    let jobNumber: Int?
    let canEdit: Bool
    let edit: (TimeEntry) -> Void
    let delete: (TimeEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Button {
                if canEdit { edit(entry) }
            } label: {
                TimeClockEntryRow(entry: entry, clock: clock, jobNumber: jobNumber, memberName: nil, week: week)
            }
            .buttonStyle(.plain)
            .accessibilityHint(canEdit ? "Opens the entry editor" : "")
            if entry.clockInSpot != nil || entry.clockOutSpot != nil {
                HStack(spacing: Theme.Spacing.lg) {
                    spotLink(entry.clockInSpot, title: "Clock-in spot", label: "Clocked in")
                    spotLink(entry.clockOutSpot, title: "Clock-out spot", label: "Clocked out")
                    Spacer(minLength: 0)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canEdit {
                Button(role: .destructive) {
                    delete(entry)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// A map link for a recorded punch location (P-24).
    @ViewBuilder
    private func spotLink(_ spot: TimeEntry.Spot?, title: String, label: String) -> some View {
        if let spot, let url = spot.mapURL(label: label) {
            Link(destination: url) {
                Label(spot.accuracyText.map { "\(title) (\($0))" } ?? title, systemImage: "mappin.and.ellipse")
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.glacier)
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Opens the location in Maps")
        }
    }
}
