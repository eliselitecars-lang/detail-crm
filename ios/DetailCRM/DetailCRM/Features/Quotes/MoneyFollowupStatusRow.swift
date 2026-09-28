//
//  MoneyFollowupStatusRow.swift
//  DetailCRM
//
//  Automatic follow-ups of one quote or invoice (P-3): what has gone out,
//  when the next one is due, and a switch to pause them for this document.
//  The shop turns follow-ups on (and edits their wording) in Settings on
//  the web; the server decides what is sent (`document_followup_status`).
//  Owners, admins and managers only — callers show it to them only.
//

import SwiftUI
import DetailCore

struct MoneyFollowupStatusRow: View {
    let kind: MoneyFollowupStatus.DocumentKind
    let documentID: UUID
    /// Changes when the document changed (status, due date, …) so the row
    /// re-reads the server's view of it.
    var refreshKey: Date? = nil

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts

    @State private var state: LoadState<MoneyFollowupStatus> = .idle
    @State private var isSaving = false

    var body: some View {
        MoneySectionCard(sectionTitle) {
            content
        }
        .task(id: TaskKey(documentID: documentID, refreshKey: refreshKey)) {
            await load()
        }
    }

    private struct TaskKey: Hashable {
        var documentID: UUID
        var refreshKey: Date?
    }

    private var sectionTitle: String {
        state.value?.title ?? (kind == .quote ? "Quote follow-ups" : "Invoice reminders")
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView().tint(Theme.glacier)
                Text("Checking follow-ups…")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                InlineMessage(text: message)
                AsyncButton("Try again", style: .themeSecondaryCompact) {
                    await load()
                }
            }
        case .loaded(let status):
            loaded(status)
        }
    }

    @ViewBuilder
    private func loaded(_ status: MoneyFollowupStatus) -> some View {
        if !status.enabled {
            Text(offText(status))
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(summary(status))
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let last = status.lastSentAt {
                    Text("Last sent \(appState.clock.dateTimeText(last))")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                Toggle(isOn: pausedBinding(status)) {
                    Text(kind == .quote ? "Pause for this quote" : "Pause for this invoice")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.textPrimary)
                }
                .tint(Theme.glacier)
                .disabled(isSaving)
                .accessibilityHint("Stops the automatic messages for this document until you turn it back on")
            }
        }
    }

    private func offText(_ status: MoneyFollowupStatus) -> String {
        switch status.stage {
        case "invoice_overdue":
            return "Automatic overdue notices are off for your shop. Turn them on in Settings on the web."
        case "invoice":
            return "Automatic invoice reminders are off for your shop. Turn them on in Settings on the web."
        default:
            return "Automatic quote follow-ups are off for your shop. Turn them on in Settings on the web."
        }
    }

    private func summary(_ status: MoneyFollowupStatus) -> String {
        let sent = "\(status.attemptsSent) of \(status.maxAttempts) sent"
        if status.paused {
            return "\(sent) · paused for this \(kind == .quote ? "quote" : "invoice")."
        }
        if let next = status.nextAt {
            var text = "\(sent) · next \(appState.clock.dateTimeText(next))"
            if status.isOverdueStage {
                text += " (shop time)"
            }
            return text + "."
        }
        if status.isFinished {
            return "\(sent) · no more are scheduled."
        }
        return "\(sent) · none due. \(notDueReason)"
    }

    /// Why nothing is scheduled although follow-ups are on.
    private var notDueReason: String {
        kind == .quote
            ? "Follow-ups go out only while a sent quote waits for an answer."
            : "Reminders go out only while a sent invoice has a balance."
    }

    private func pausedBinding(_ status: MoneyFollowupStatus) -> Binding<Bool> {
        Binding(
            get: { status.paused },
            set: { paused in
                Task { await setPaused(paused) }
            }
        )
    }

    private func load() async {
        state.beginLoading()
        let kind = self.kind
        let id = documentID
        let result = await LoadState<MoneyFollowupStatus>.result {
            try await MoneyFollowupService.status(kind: kind, documentID: id)
        }
        state.apply(result)
    }

    private func setPaused(_ paused: Bool) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            state = .loaded(try await MoneyFollowupService.setPaused(kind: kind, documentID: documentID, paused: paused))
            toasts.show(paused ? "Follow-ups paused" : "Follow-ups resumed")
        } catch {
            toasts.showError(error)
        }
    }
}
