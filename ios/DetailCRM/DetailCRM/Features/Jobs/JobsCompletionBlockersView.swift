//
//  JobsCompletionBlockersView.swift
//  DetailCRM
//
//  Shown when the server refused to start or complete a job (P-11): the
//  open required checklist items (tick them right here) and the before /
//  after photos still missing. "Try again" re-checks and moves the job;
//  managers and up may "Complete anyway" with a reason, which the server
//  records as an override.
//

import SwiftUI
import DetailCore

struct JobsCompletionBlockersView: View {
    let model: JobDetailModel
    let target: JobStatus
    /// The server's refusal ("Finish the required checklist items first: …").
    let serverMessage: String

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @State private var state: LoadState<JobsCompletionBlockers> = .idle
    @State private var overrideReason = ""
    @State private var showsOverride = false
    @State private var errorMessage: String?

    private var permissions: JobDetailPermissions { model.permissions }
    private var canOverride: Bool { permissions.role.isManagerOrAbove }
    private var verb: String { target == .completed ? "complete" : "start" }

    var body: some View {
        NavigationStack {
            FormScreen {
                InlineMessage(text: serverMessage, kind: .error)
                if let errorMessage {
                    InlineMessage(text: errorMessage, kind: .error)
                }
                JobSectionStateView(state, loadingLabel: "Checking what's missing…", retry: { await load() }) { blockers in
                    blockerList(blockers)
                }
                actions
            }
            .navigationTitle(target == .completed ? "Can't complete yet" : "Can't start yet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    // MARK: - Blockers

    @ViewBuilder
    private func blockerList(_ blockers: JobsCompletionBlockers) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if target == .completed && !blockers.openRequiredItems.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Required checklist items")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.textPrimary)
                    ForEach(blockers.openRequiredItems) { item in
                        requiredItemRow(item)
                    }
                }
            }
            if target == .inProgress {
                photoLine("Before photos", count: blockers.beforePhotos)
            }
            if target == .completed {
                photoLine("After photos", count: blockers.afterPhotos)
            }
            if !blockers.blocks(target) {
                InlineMessage(text: "Everything is in place now. Try again to \(verb) the job.", kind: .success)
            }
        }
        .cardStyle()
    }

    private func requiredItemRow(_ item: JobsCompletionBlockers.Item) -> some View {
        let checklistItem = model.checklist.value?.first { $0.id == item.id }
        return Button {
            guard let checklistItem else { return }
            Task { await tick(checklistItem) }
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: checklistItem?.isDone == true ? "checkmark.circle.fill" : "circle")
                    .font(Theme.Typography.title.weight(.regular))
                    .foregroundStyle(checklistItem?.isDone == true ? Theme.success : Theme.textTertiary)
                    .accessibilityHidden(true)
                Text(item.label)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: Theme.Size.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(checklistItem == nil || !permissions.canWork)
        .accessibilityLabel(item.label)
        .accessibilityValue(checklistItem?.isDone == true ? "Done" : "Not done")
        .accessibilityHint("Marks the item done")
    }

    private func photoLine(_ title: String, count: JobsCompletionBlockers.PhotoCount) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: count.missing > 0 ? "camera.badge.ellipsis" : "checkmark.circle")
                .font(Theme.Typography.body)
                .foregroundStyle(count.missing > 0 ? Theme.textPrimary : Theme.success)
            Spacer()
            Text(count.required == 0 ? "None needed" : "\(count.have) of \(count.required)")
                .font(Theme.Typography.subheadline.weight(.semibold))
                .foregroundStyle(count.missing > 0 ? Theme.warning : Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(count.missing > 0 ? "Add \(count.missing) more in Photos on the job." : "")
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            AsyncButton("Try again", style: .themePrimary) { await retryMove() }
            if canOverride {
                if showsOverride {
                    FormRow("Why are you overriding?", hint: "Saved with the job for the record.") {
                        TextField("Reason", text: $overrideReason, axis: .vertical)
                            .lineLimit(2...4)
                            .inputFieldStyle()
                    }
                    AsyncButton(target == .completed ? "Complete anyway" : "Start anyway", role: .destructive, style: .themeDestructive) {
                        await forceMove()
                    }
                    .disabled(overrideReason.trimmedNonEmpty == nil)
                } else {
                    Button(target == .completed ? "Complete anyway…" : "Start anyway…") {
                        showsOverride = true
                    }
                    .buttonStyle(.themeSecondary)
                }
            }
        }
    }

    private func load() async {
        state.beginLoading()
        let result = await LoadState<JobsCompletionBlockers>.result {
            try await model.completionBlockers()
        }
        state.apply(result)
    }

    private func tick(_ item: JobChecklistItem) async {
        do {
            try await model.toggleChecklistItem(item)
            await load()
        } catch {
            toasts.showError(error)
        }
    }

    private func retryMove() async {
        errorMessage = nil
        do {
            try await model.changeStatus(to: target)
            toasts.show("Job is now \(target.displayName.lowercased()).")
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
            await load()
        }
    }

    private func forceMove() async {
        guard let reason = overrideReason.trimmedNonEmpty else { return }
        errorMessage = nil
        do {
            try await model.changeStatus(to: target, force: true, overrideReason: reason)
            toasts.show("Job is now \(target.displayName.lowercased()). The override was recorded.")
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
