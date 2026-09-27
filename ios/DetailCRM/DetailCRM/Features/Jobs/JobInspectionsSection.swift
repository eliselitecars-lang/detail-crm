//
//  JobInspectionsSection.swift
//  DetailCRM
//
//  Pre / post inspections on the job card: one row per inspection with
//  its mark count and signature state, plus buttons to start the missing
//  kinds. The full inspection opens in `JobInspectionSheet`.
//

import SwiftUI
import DetailCore

struct JobInspectionsSection: View {
    let model: JobDetailModel
    let hasVehicle: Bool
    let canWork: Bool
    let clock: ShopClock
    let onOpen: (UUID) -> Void

    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        JobSectionCard("Inspections") {
            JobSectionStateView(model.inspections, loadingLabel: "Loading inspections…", retry: { await model.loadInspections() }) { bundles in
                content(bundles)
            }
        }
    }

    @ViewBuilder
    private func content(_ bundles: [JobInspectionBundle]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if bundles.isEmpty {
                JobEmptyLine(text: "No inspections yet.", systemImage: "car.rear.and.tire.marks")
            } else {
                ForEach(bundles) { bundle in
                    Button {
                        onOpen(bundle.id)
                    } label: {
                        JobInspectionRow(bundle: bundle, clock: clock)
                    }
                    .buttonStyle(.plain)
                }
            }
            if canWork {
                startButtons(existing: Set(bundles.map { $0.inspection.kind }))
            }
        }
    }

    @ViewBuilder
    private func startButtons(existing: Set<JobInspectionKind>) -> some View {
        let missing = JobInspectionKind.allCases.filter { !existing.contains($0) }
        if !missing.isEmpty {
            if !hasVehicle {
                Text("Add a vehicle to the job to tie inspections to it.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(missing) { kind in
                    AsyncButton(style: .themeSecondaryCompact) {
                        await start(kind)
                    } label: {
                        Label(kind == .pre ? "Start pre" : "Start post", systemImage: "plus.viewfinder")
                    }
                    .accessibilityLabel("Start \(kind.displayName.lowercased())")
                }
            }
        }
    }

    private func start(_ kind: JobInspectionKind) async {
        do {
            let id = try await model.createInspection(kind)
            onOpen(id)
        } catch {
            toasts.showError(error)
        }
    }
}

struct JobInspectionRow: View {
    let bundle: JobInspectionBundle
    let clock: ShopClock

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: bundle.inspection.isSigned ? "checkmark.seal.fill" : "doc.text.magnifyingglass")
                .foregroundStyle(bundle.inspection.isSigned ? Theme.success : Theme.glacier)
                .frame(width: Theme.Size.rowIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(bundle.inspection.kind.displayName)
                    .font(Theme.Typography.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: Theme.Size.controlHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let count = bundle.marks.count
        let marksText = count == 1 ? "1 mark" : "\(count) marks"
        if let signedAt = bundle.inspection.signedAt {
            let who = bundle.inspection.signedByName ?? "customer"
            return marksText + " · Signed by \(who), " + clock.dateTimeText(signedAt)
        }
        return marksText + " · Not signed"
    }
}
