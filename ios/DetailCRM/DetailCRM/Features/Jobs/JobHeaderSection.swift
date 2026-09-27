//
//  JobHeaderSection.swift
//  DetailCRM
//
//  Job number, status badge, the tappable status stepper and the primary
//  next-step action. Only transitions the signed-in role may take are
//  offered (DetailCore `JobStatus` rules, same table as the database).
//

import SwiftUI
import DetailCore

struct JobHeaderSection: View {
    let job: Job
    let customerName: String?
    let clock: ShopClock
    let permissions: JobDetailPermissions
    let onSelectStatus: (JobStatus) -> Void
    let onMessage: (JobMessageTemplateKey) -> Void

    private var targets: [JobStatus] { permissions.statusTargets(from: job.status) }

    /// The nearest forward pipeline step the role may take (managers:
    /// scheduled → confirmed; technicians: scheduled → on the way).
    private var primaryTarget: JobStatus? {
        guard let currentIndex = job.status.pipelineIndex else { return nil }
        return JobStatus.pipeline.first { candidate in
            guard let index = candidate.pipelineIndex else { return false }
            return index > currentIndex && targets.contains(candidate)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            titleBlock
            JobStatusStepper(current: job.status, allowedTargets: targets, onSelect: onSelectStatus)
            if job.status == .cancelled, let reason = job.cancelReason?.trimmedNonEmpty {
                InlineMessage(text: "Cancelled: \(reason)", kind: .info)
            }
            actions
        }
        .cardStyle()
    }

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(job.title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.textPrimary)
                if let customerName {
                    Text(customerName)
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(JobsFormatting.scheduleText(start: job.scheduledStart, end: job.scheduledEnd, clock: clock))
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            StatusBadge(job.status)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let primaryTarget {
                Button {
                    onSelectStatus(primaryTarget)
                } label: {
                    Label(Self.actionTitle(for: primaryTarget), systemImage: Self.icon(for: primaryTarget))
                }
                .buttonStyle(.themePrimary)
            }
            HStack(spacing: Theme.Spacing.sm) {
                if permissions.canMessageCustomer && !job.status.isSideExit {
                    messageMenu
                }
                if !otherTargets.isEmpty {
                    statusMenu
                }
            }
        }
    }

    /// Every allowed target except the primary one.
    private var otherTargets: [JobStatus] {
        targets.filter { $0 != primaryTarget }
    }

    private var statusMenu: some View {
        Menu {
            ForEach(otherTargets, id: \.self) { target in
                Button(role: target.isSideExit ? .destructive : nil) {
                    onSelectStatus(target)
                } label: {
                    Label(Self.menuTitle(for: target, from: job.status), systemImage: Self.icon(for: target))
                }
            }
        } label: {
            Label("Status", systemImage: "arrow.triangle.swap")
        }
        .buttonStyle(.themeSecondaryCompact)
        .accessibilityLabel("Change status")
    }

    private var messageMenu: some View {
        Menu {
            ForEach(JobMessageTemplateKey.allCases) { key in
                Button {
                    onMessage(key)
                } label: {
                    Label(key.title, systemImage: key.systemImage)
                }
            }
        } label: {
            Label("Text customer", systemImage: "message")
        }
        .buttonStyle(.themeSecondaryCompact)
        .accessibilityLabel("Send the customer a message")
    }

    // MARK: - Wording

    static func actionTitle(for status: JobStatus) -> String {
        switch status {
        case .requested: return "Back to requested"
        case .scheduled: return "Schedule"
        case .confirmed: return "Confirm appointment"
        case .enRoute: return "On my way"
        case .inProgress: return "Start job"
        case .completed: return "Complete job"
        case .cancelled: return "Cancel job"
        case .noShow: return "Mark no-show"
        }
    }

    static func menuTitle(for target: JobStatus, from current: JobStatus) -> String {
        if current.transition(to: target)?.direction == .backward {
            return "Back to \(target.displayName.lowercased())"
        }
        return actionTitle(for: target)
    }

    static func icon(for status: JobStatus) -> String {
        switch status {
        case .requested: return "tray"
        case .scheduled: return "calendar"
        case .confirmed: return "checkmark.circle"
        case .enRoute: return "car.side"
        case .inProgress: return "play.circle"
        case .completed: return "checkmark.seal"
        case .cancelled: return "xmark.circle"
        case .noShow: return "person.crop.circle.badge.xmark"
        }
    }
}

/// The pipeline as tappable chevron steps. Steps the role may move to are
/// buttons; the rest are plain labels. Side exits show as a single step.
struct JobStatusStepper: View {
    let current: JobStatus
    let allowedTargets: [JobStatus]
    let onSelect: (JobStatus) -> Void

    private var steps: [JobStatus] {
        current.isSideExit ? JobStatus.pipeline + [current] : JobStatus.pipeline
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(steps, id: \.self) { step in
                    stepView(step)
                }
            }
            .padding(.vertical, Theme.Spacing.xxs)
        }
    }

    @ViewBuilder
    private func stepView(_ step: JobStatus) -> some View {
        let tappable = allowedTargets.contains(step)
        if tappable {
            Button {
                onSelect(step)
            } label: {
                JobStatusStepLabel(step: step, state: stepState(step), tappable: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Move to \(step.displayName)")
        } else {
            JobStatusStepLabel(step: step, state: stepState(step), tappable: false)
                .accessibilityLabel(step == current ? step.displayName + ", current status" : step.displayName)
        }
    }

    private func stepState(_ step: JobStatus) -> JobStatusStepLabel.StepState {
        if step == current { return .current }
        if current.isSideExit { return .upcoming }
        guard let stepIndex = step.pipelineIndex, let currentIndex = current.pipelineIndex else { return .upcoming }
        return stepIndex < currentIndex ? .done : .upcoming
    }
}

struct JobStatusStepLabel: View {
    enum StepState {
        case done
        case current
        case upcoming
    }

    let step: JobStatus
    let state: StepState
    let tappable: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .bold))
                .accessibilityHidden(true)
            Text(step.displayName)
                .font(Theme.Typography.captionEmphasis)
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, Theme.Spacing.sm)
        .frame(minHeight: 32)
        .background(
            Capsule(style: .continuous)
                .fill(fill)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(stroke, lineWidth: Theme.Size.hairline)
        )
        .contentShape(Capsule(style: .continuous))
    }

    private var iconName: String {
        switch state {
        case .done: return "checkmark"
        case .current: return "circle.fill"
        case .upcoming: return tappable ? "chevron.right" : "circle"
        }
    }

    private var tone: StatusTone {
        state == .current ? step.tone : .info
    }

    private var foreground: Color {
        switch state {
        case .current: return Theme.color(for: tone)
        case .done: return Theme.textSecondary
        case .upcoming: return tappable ? Theme.glacier : Theme.textTertiary
        }
    }

    private var fill: Color {
        switch state {
        case .current: return Theme.fill(for: tone)
        case .done, .upcoming: return Theme.surfaceMuted
        }
    }

    private var stroke: Color {
        tappable ? Theme.glacier.opacity(0.5) : Color.clear
    }
}
