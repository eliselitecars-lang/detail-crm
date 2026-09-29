//
//  JobTimeSection.swift
//  DetailCRM
//
//  The job's Time section (the web job page's TimeCard): who is on the
//  clock for this job right now, "Clock in on this job" / "Clock out" for
//  an assigned member, and the job's time entries (member, start, end,
//  duration) with their total. Punches go through `clock_in` / `clock_out`
//  with the device location when the member allows it (P-24), exactly like
//  the Time Clock screen; the server stamps the time and enforces the
//  rules (one open job timer per member, assigned jobs only, never on a
//  cancelled or no-show job).
//
//  Managers and above see everyone's entries; technicians see their own
//  (RLS). The job screen hides the section on a completed, cancelled or
//  no-show job with no time recorded (`JobTime.showsSection`), and a
//  closed job never offers "Clock in".
//

import SwiftUI
import DetailCore

struct JobTimeSection: View {
    let state: LoadState<JobTimeSnapshot>
    let snapshot: JobDetailSnapshot
    let memberID: UUID?
    let clock: ShopClock
    /// Managers+: the list holds everyone's entries.
    let seesEveryone: Bool
    let retry: () async -> Void
    let onPunch: (JobTime.Action) async -> Void

    var body: some View {
        JobSectionCard("Time") {
            JobSectionStateView(state, loadingLabel: "Loading time…", retry: retry) { time in
                JobTimeContent(
                    time: time,
                    snapshot: snapshot,
                    memberID: memberID,
                    clock: clock,
                    seesEveryone: seesEveryone,
                    onPunch: onPunch
                )
            }
        }
    }
}

private struct JobTimeContent: View {
    let time: JobTimeSnapshot
    let snapshot: JobDetailSnapshot
    let memberID: UUID?
    let clock: ShopClock
    let seesEveryone: Bool
    let onPunch: (JobTime.Action) async -> Void

    var body: some View {
        // Re-read every minute so open entries and the total keep moving.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let summary = time.summary(now: context.date)
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                onTheClock(summary)
                actionRow
                if !time.entries.isEmpty {
                    JobDivider()
                    entryList(now: context.date)
                    totalRow(summary)
                }
                if !seesEveryone {
                    Text("You see your own time on this job.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Who is on the clock

    @ViewBuilder
    private func onTheClock(_ summary: JobTime.Summary) -> some View {
        if summary.hasOpenEntries {
            Label {
                Text("On the clock: " + summary.openMemberIDs.map(name(for:)).joined(separator: ", "))
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "clock.fill")
                    .foregroundStyle(Theme.successInk)
            }
            .accessibilityElement(children: .combine)
        } else {
            JobEmptyLine(text: "Nobody is clocked in on this job.", systemImage: "clock")
        }
    }

    // MARK: Clock in / out

    private var action: JobTime.Action {
        time.action(jobID: snapshot.job.id, jobStatus: snapshot.job.status, isAssigned: snapshot.isAssigned(memberID: memberID))
    }

    @ViewBuilder
    private var actionRow: some View {
        switch action {
        case .clockIn:
            AsyncButton(style: .themePrimary) {
                await onPunch(.clockIn)
            } label: {
                Label("Clock in on this job", systemImage: "play.circle")
            }
            .accessibilityHint("Starts your job timer. Records where you are if you allow location access.")
        case .clockOut:
            AsyncButton(style: .themeSecondary) {
                await onPunch(.clockOut)
            } label: {
                Label("Clock out", systemImage: "stop.circle")
            }
            .accessibilityHint("Stops your job timer on this job.")
        case .clockedInElsewhere:
            Text("You're clocked in on another job. Clock out there first.")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .none:
            EmptyView()
        }
    }

    // MARK: Entries

    private func entryList(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(time.entries) { entry in
                JobTimeEntryRow(entry: entry, memberName: name(for: entry.memberID), clock: clock, now: now)
            }
        }
    }

    private func totalRow(_ summary: JobTime.Summary) -> some View {
        HStack {
            Text(summary.entryCount == 1 ? "Total · 1 entry" : "Total · \(summary.entryCount) entries")
                .font(Theme.Typography.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Theme.Spacing.sm)
            Text(TimeEntry.durationText(seconds: summary.totalSeconds))
                .font(Theme.Typography.bodyEmphasis.monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    private func name(for memberID: UUID) -> String {
        if memberID == self.memberID { return "You" }
        return snapshot.member(memberID)?.displayName.trimmedNonEmpty ?? "Team member"
    }
}

/// One entry: member, start – end (or "Now"), duration.
private struct JobTimeEntryRow: View {
    let entry: TimeEntry
    let memberName: String
    let clock: ShopClock
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(memberName)
                    .font(Theme.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(rangeText)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.sm)
            if entry.isOpen {
                StatusBadge(text: "Now", tone: .success)
            } else {
                Text(TimeEntry.durationText(seconds: entry.durationSeconds(now: now)))
                    .font(Theme.Typography.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var rangeText: String {
        let start = clock.dateTimeText(entry.clockIn)
        guard let clockOut = entry.clockOut else {
            return "\(start) – running \(TimeEntry.durationText(seconds: entry.durationSeconds(now: now)))"
        }
        let end = clock.isSameDay(entry.clockIn, clockOut) ? clock.timeText(clockOut) : clock.dateTimeText(clockOut)
        return "\(start) – \(end)"
    }
}

// MARK: - Punches

extension JobDetailModel {

    /// Clocks the signed-in member in on this job or out of it, with the
    /// device location when allowed, then re-reads the section. Returns
    /// the confirmation to show. The section is re-read after a refusal
    /// too (someone may have clocked in elsewhere meanwhile).
    func punchJobTime(_ action: JobTime.Action) async throws -> String {
        guard let shopID else { throw AppError.noShopSelected }
        guard action == .clockIn || action == .clockOut else { return "" }
        let spot = await OpsClockLocationProvider.shared.currentSpot()
        let base = action == .clockIn ? "Clocked in on this job." : "Clocked out."
        do {
            if action == .clockIn {
                _ = try await TimeClockService.clockIn(shopID: shopID, jobID: jobID, location: spot)
            } else {
                _ = try await TimeClockService.clockOut(shopID: shopID, kind: .job, location: spot)
            }
        } catch {
            await loadTime()
            throw error
        }
        await loadTime()
        return OpsClockLocationProvider.shared.punchMessage(base, spot: spot)
    }
}
