//
//  OpsTaskRow.swift
//  DetailCRM
//
//  One task in the Tasks list (P-32): a check button, the title (tap to
//  edit), due time in the shop's time zone (overdue in red), who it is for
//  and links to its customer and job.
//

import SwiftUI
import DetailCore

struct OpsTaskRow: View {
    let task: OpsTask
    let references: OpsTask.References
    let clock: ShopClock
    let now: Date
    /// True while the done / open change is being saved.
    let isSaving: Bool
    let canDelete: Bool
    let toggleDone: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            checkButton
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Button(action: edit) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(task.title)
                            .font(Theme.Typography.bodyEmphasis)
                            .foregroundStyle(task.isDone ? Theme.textSecondary : Theme.textPrimary)
                            .strikethrough(task.isDone, color: Theme.textTertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let notes = task.notes?.trimmedNonEmpty {
                            Text(notes)
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        metaLine
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Edit the task")
                links
            }
            Menu {
                Button("Edit", systemImage: "pencil", action: edit)
                Button(task.isDone ? "Mark as not done" : "Mark as done",
                       systemImage: task.isDone ? "arrow.uturn.backward" : "checkmark",
                       action: toggleDone)
                if canDelete {
                    Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Theme.textTertiary)
                    .iconTapTarget()
            }
            .accessibilityLabel("More for \(task.title)")
        }
        .cardStyle(padding: Theme.Spacing.md)
    }

    private var checkButton: some View {
        Button(action: toggleDone) {
            ZStack {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(task.isDone ? Theme.successInk : Theme.textTertiary)
                    .opacity(isSaving ? 0 : 1)
                ProgressView()
                    .tint(Theme.glacier)
                    .opacity(isSaving ? 1 : 0)
            }
            .iconTapTarget()
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel(task.isDone ? "Done. Mark as not done" : "Mark as done")
    }

    /// "Due today, 3:00 PM · For Sam".
    private var metaLine: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let dueText {
                Label(dueText, systemImage: task.isOverdue(now: now) ? "exclamationmark.circle" : "clock")
                    .foregroundStyle(task.isOverdue(now: now) ? Theme.dangerInk : Theme.textSecondary)
            }
            if let assignee = references.memberName(task.assigneeMemberID) {
                Text(dueText == nil ? "For \(assignee)" : "· For \(assignee)")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .font(Theme.Typography.caption)
        .labelStyle(.titleAndIcon)
    }

    private var dueText: String? {
        if let doneAt = task.doneAt {
            return "Done \(clock.relativeDayText(doneAt, now: now)), \(clock.timeText(doneAt))"
        }
        guard let dueAt = task.dueAt else { return nil }
        let prefix = task.isOverdue(now: now) ? "Was due" : "Due"
        return "\(prefix) \(clock.relativeDayText(dueAt, now: now)), \(clock.timeText(dueAt))"
    }

    @ViewBuilder
    private var links: some View {
        if task.jobID != nil || task.customerID != nil {
            HStack(spacing: Theme.Spacing.sm) {
                if let jobID = task.jobID {
                    NavigationLink(value: AppRoute.job(jobID)) {
                        chip(references.jobNumbers[jobID].map { "Job #\($0)" } ?? "Job", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the job")
                }
                if let customerID = task.customerID {
                    NavigationLink(value: AppRoute.customer(customerID)) {
                        chip(references.customerNames[customerID] ?? "Customer", systemImage: "person")
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the customer")
                }
            }
        }
    }

    private func chip(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(Theme.Typography.captionEmphasis)
            .foregroundStyle(Theme.glacierInk)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                    .fill(Theme.fill(for: .info))
            )
    }
}
