//
//  JobScheduleSection.swift
//  DetailCRM
//
//  When and where (shop time zone), the bay/van, and who is assigned.
//  Managers and above edit both from sheets.
//

import SwiftUI
import DetailCore

struct JobScheduleSection: View {
    let snapshot: JobDetailSnapshot
    let resources: [JobResource]
    /// The bays/vans list failed to load (names can't be shown).
    let resourcesFailed: Bool
    let clock: ShopClock
    let canEdit: Bool
    let onEditDetails: () -> Void
    let onEditAssignees: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(AppState.self) private var appState

    private var job: Job { snapshot.job }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            JobSectionCard(
                "Schedule & location",
                actionTitle: canEdit ? "Edit" : nil,
                action: canEdit ? onEditDetails : nil
            ) {
                scheduleRows
            }
            JobSectionCard(
                "Assigned",
                actionTitle: canEdit ? "Edit" : nil,
                action: canEdit ? onEditAssignees : nil
            ) {
                assigneeRows
            }
        }
    }

    // MARK: - Schedule

    private var scheduleRows: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            InfoRow(label: "When", value: whenText, systemImage: "calendar")
            if let minutes = job.scheduledMinutes {
                InfoRow(label: "Length", value: ShopClock.durationText(minutes: minutes), systemImage: "clock")
            }
            InfoRow(label: "Where", value: job.locationType.displayName, systemImage: job.locationType.systemImage)
            if job.locationType == .mobile {
                mobileAddressRow
            }
            if let resourceName {
                InfoRow(label: "Bay / van", value: resourceName, systemImage: "square.grid.2x2")
            }
            if job.depositRequiredCents > 0 {
                HStack {
                    Label("Deposit required", systemImage: "banknote")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: Theme.Spacing.md)
                    MoneyText(cents: job.depositRequiredCents, currencyCode: appState.currencyCode, size: .small)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var whenText: String {
        guard let start = job.scheduledStart else { return "Not scheduled yet" }
        let day = clock.longDayText(start)
        guard let end = job.scheduledEnd else { return day + ", " + clock.timeText(start) }
        if clock.isSameDay(start, end) {
            return day + "\n" + clock.rangeText(from: start, to: end)
        }
        return clock.rangeText(from: start, to: end)
    }

    private var resourceName: String? {
        guard let id = job.resourceID else { return nil }
        if let name = resources.first(where: { $0.id == id })?.name { return name }
        // Not in the active list: either the list didn't load, or the bay /
        // van was deactivated or archived after booking.
        return resourcesFailed ? "Couldn't load the name" : "Inactive or archived"
    }

    @ViewBuilder
    private var mobileAddressRow: some View {
        if let address = job.serviceAddressSummary {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Text(address)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: Theme.Spacing.sm)
                if let url = directionsURL(address) {
                    JobIconButton(systemImage: "arrow.triangle.turn.up.right.diamond.fill", accessibilityLabel: "Directions to the service address") {
                        openURL(url)
                    }
                }
            }
        } else {
            InlineMessage(text: "No service address on this mobile job.", kind: .info)
        }
    }

    private func directionsURL(_ address: String) -> URL? {
        if let lat = job.serviceLat, let lng = job.serviceLng {
            return MapLinks.directions(latitude: lat, longitude: lng, name: address)
        }
        return MapLinks.directions(toAddress: address)
    }

    // MARK: - Assignees

    @ViewBuilder
    private var assigneeRows: some View {
        if snapshot.assignments.isEmpty {
            JobEmptyLine(text: "Nobody is assigned yet.", systemImage: "person.badge.plus")
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(snapshot.assignments) { assignment in
                    assigneeRow(assignment)
                }
            }
        }
    }

    private func assigneeRow(_ assignment: JobAssignment) -> some View {
        let member = snapshot.member(assignment.memberID)
        let name = member?.displayName ?? "Team member"
        return HStack(spacing: Theme.Spacing.md) {
            AvatarView(name: name, size: Theme.Size.avatarSmall, colorHex: member?.calendarColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                if let role = member?.role {
                    Text(role.displayName)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
