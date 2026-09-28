//
//  JobsDepositFollowupRow.swift
//  DetailCRM
//
//  Automatic deposit reminders on the job's money card (P-3, managers+):
//  whether they run for this job, how many went out, when the next one is
//  due, and a pause switch. The shop turns them on (and writes the
//  message) in Settings on the web; when that is off the row says so.
//

import SwiftUI
import DetailCore

struct JobsDepositFollowupRow: View {
    let jobID: UUID

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var state: LoadState<JobService.FollowupStatus> = .idle
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label("Deposit reminders", systemImage: "bell.badge")
                .font(Theme.Typography.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            switch state {
            case .idle, .loading:
                Text("Checking…")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            case .failed(let message):
                JobReferenceLoadError(text: message) { await load() }
            case .loaded(let status):
                content(status)
            }
        }
        .task(id: jobID) { await load() }
    }

    @ViewBuilder
    private func content(_ status: JobService.FollowupStatus) -> some View {
        if !status.enabled {
            Text("Automatic deposit reminders are off for the shop (Settings on the web).")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(summary(status))
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Pause for this job", isOn: pausedBinding(status))
                .tint(Theme.glacier)
                .font(Theme.Typography.footnote)
                .disabled(isSaving)
        }
    }

    private func summary(_ status: JobService.FollowupStatus) -> String {
        var parts = ["\(status.attemptsSent) of \(status.maxAttempts) sent"]
        if status.paused {
            parts.append("paused")
        } else if let next = status.nextAt {
            parts.append("next " + appState.clock.dateTimeText(next))
        } else if status.attemptsSent >= status.maxAttempts {
            parts.append("no more scheduled")
        } else {
            parts.append("none due")
        }
        if let last = status.lastSentAt {
            parts.append("last " + appState.clock.relativeDayText(last))
        }
        return parts.joined(separator: " · ")
    }

    private func pausedBinding(_ status: JobService.FollowupStatus) -> Binding<Bool> {
        Binding(
            get: { status.paused },
            set: { paused in Task { await setPaused(paused) } }
        )
    }

    private func load() async {
        state.beginLoading()
        let jobID = self.jobID
        let result = await LoadState<JobService.FollowupStatus>.result {
            try await JobService.depositFollowupStatus(jobID: jobID)
        }
        state.apply(result)
    }

    private func setPaused(_ paused: Bool) async {
        isSaving = true
        defer { isSaving = false }
        do {
            state = .loaded(try await JobService.setDepositFollowupsPaused(jobID: jobID, paused: paused))
            toasts.show(paused ? "Deposit reminders paused" : "Deposit reminders resumed")
        } catch {
            toasts.showError(error)
        }
    }
}
