//
//  JobsGateOverridesNotice.swift
//  DetailCRM
//
//  P-11 audit trail on the job screen: each time a manager moved the job
//  past its required checklist items or photo minimums ("Complete anyway"
//  / "Start anyway", `set_job_status` with force), who did it, when, why,
//  and what was still missing (`job_gate_overrides`). Everyone who can
//  work the job sees it, so a technician can tell that a completed job
//  skipped its required photos. Nothing is shown for a job that never
//  needed an override; it is secondary information, so no spinner either.
//

import SwiftUI
import DetailCore

struct JobsGateOverridesNotice: View {
    let model: JobDetailModel
    let clock: ShopClock

    var body: some View {
        switch model.gateOverrides {
        case .idle, .loading:
            EmptyView()
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                InlineMessage(text: "Couldn't load the requirement overrides. " + message, kind: .error)
                AsyncButton("Try again", style: .themeSecondaryCompact) {
                    await model.loadGateOverrides()
                }
            }
            .cardStyle()
        case .loaded(let overrides):
            if !overrides.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ForEach(overrides) { record in
                        JobsGateOverrideEntry(
                            record: record,
                            who: name(of: record.overriddenBy),
                            clock: clock
                        )
                    }
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(Theme.warning.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.warning, lineWidth: Theme.Size.hairline)
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Requirement overrides")
            }
        }
    }

    /// The manager's name from the team directory (nil once they're gone).
    private func name(of userID: UUID?) -> String? {
        guard let userID else { return nil }
        return model.snapshot?.team.first { $0.userID == userID }?.displayName
    }
}

private struct JobsGateOverrideEntry: View {
    let record: JobsGateOverride
    let who: String?
    let clock: ShopClock

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.shield")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.warningInk)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(GateWaiver.headline(to: record.toStatus))
                    .font(Theme.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.warningInk)
                    .fixedSize(horizontal: false, vertical: true)
                Text(byline)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.warningInk)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Reason: " + GateWaiver.reasonText(record.reason))
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.warningInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                let missing = record.waiver.sentences
                if !missing.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        ForEach(missing, id: \.self) { sentence in
                            Text("• " + sentence)
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.warningInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Not met: " + missing.joined(separator: ". "))
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var byline: String {
        let when = clock.dateTimeText(record.createdAt)
        guard let who else { return when }
        return when + " · by " + who
    }
}
