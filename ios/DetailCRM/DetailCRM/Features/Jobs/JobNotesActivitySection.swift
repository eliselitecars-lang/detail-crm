//
//  JobNotesActivitySection.swift
//  DetailCRM
//
//  Customer-visible notes, internal notes (editable by staff on the job)
//  and the status timeline stamped by the server.
//

import SwiftUI
import DetailCore

struct JobNotesSection: View {
    let job: Job
    let canEditInternal: Bool
    let onEditInternal: () -> Void

    var body: some View {
        JobSectionCard(
            "Notes",
            actionTitle: canEditInternal ? "Edit internal" : nil,
            action: canEditInternal ? onEditInternal : nil
        ) {
            noteBlock(title: "For the customer", text: job.notes, empty: "No customer notes.")
            JobDivider()
            noteBlock(title: "Internal (staff only)", text: job.internalNotes, empty: "No internal notes.")
        }
    }

    private func noteBlock(title: String, text: String?, empty: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
            Text(text?.trimmedNonEmpty ?? empty)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(text?.trimmedNonEmpty == nil ? Theme.textTertiary : Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct JobActivitySection: View {
    let job: Job
    let clock: ShopClock

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let date: Date
        let systemImage: String
    }

    private var entries: [Entry] {
        var list: [Entry] = [
            Entry(id: "created", title: "Created (\(sourceText))", date: job.createdAt, systemImage: "plus.circle"),
        ]
        if let date = job.confirmedAt {
            list.append(Entry(id: "confirmed", title: "Confirmed", date: date, systemImage: "checkmark.circle"))
        }
        if let date = job.enRouteAt {
            list.append(Entry(id: "enroute", title: "On the way", date: date, systemImage: "car.side"))
        }
        if let date = job.startedAt {
            list.append(Entry(id: "started", title: "Started", date: date, systemImage: "play.circle"))
        }
        if let date = job.completedAt {
            list.append(Entry(id: "completed", title: "Completed", date: date, systemImage: "checkmark.seal"))
        }
        if let date = job.cancelledAt {
            list.append(Entry(id: "cancelled", title: "Cancelled", date: date, systemImage: "xmark.circle"))
        }
        return list.sorted { $0.date < $1.date }
    }

    private var sourceText: String {
        switch job.source {
        case "online_booking": return "online booking"
        case "quote": return "from a quote"
        case "membership": return "membership"
        default: return "by staff"
        }
    }

    var body: some View {
        JobSectionCard("Activity") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(entries) { entry in
                    HStack(spacing: Theme.Spacing.md) {
                        Image(systemName: entry.systemImage)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: Theme.Size.rowIcon)
                            .accessibilityHidden(true)
                        Text(entry.title)
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: Theme.Spacing.sm)
                        Text(clock.dateTimeText(entry.date))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Internal notes editor (staff on the job).
struct JobInternalNotesSheet: View {
    let model: JobDetailModel

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @State private var text = ""
    @State private var errorMessage: String?
    @State private var didPrefill = false

    var body: some View {
        NavigationStack {
            FormScreen {
                if let errorMessage {
                    InlineMessage(text: errorMessage, kind: .error)
                }
                FormRow("Internal notes", hint: "Only your team sees these.") {
                    TextField("Gate code, parking, what to watch for…", text: $text, axis: .vertical)
                        .lineLimit(5...14)
                        .inputFieldStyle()
                }
            }
            .navigationTitle("Internal notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    AsyncButton("Save", style: .themePrimaryCompact) {
                        await save()
                    }
                }
            }
            .onAppear {
                guard !didPrefill else { return }
                didPrefill = true
                text = model.job?.internalNotes ?? ""
            }
        }
    }

    private func save() async {
        errorMessage = nil
        guard text.count <= 20_000 else {
            errorMessage = "Notes are limited to 20,000 characters."
            return
        }
        do {
            try await model.saveInternalNotes(text)
            toasts.show("Notes saved")
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

/// Cancel with an optional reason (managers and above).
struct JobCancelSheet: View {
    let model: JobDetailModel

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @State private var reason = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            FormScreen {
                Text("The job moves to Cancelled. Unsigned forms become void. Payments already taken aren't refunded automatically.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let errorMessage {
                    InlineMessage(text: errorMessage, kind: .error)
                }
                FormRow("Reason", hint: "Optional — kept on the job for your team.") {
                    TextField("Customer rescheduled, weather…", text: $reason, axis: .vertical)
                        .lineLimit(2...6)
                        .inputFieldStyle()
                }
                AsyncButton("Cancel job", role: .destructive, style: .themeDestructive) {
                    await cancelJob()
                }
            }
            .navigationTitle("Cancel job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep job") { dismiss() }
                }
            }
        }
    }

    private func cancelJob() async {
        errorMessage = nil
        guard reason.count <= 1000 else {
            errorMessage = "Keep the reason under 1,000 characters."
            return
        }
        do {
            let recorded = try await model.changeStatus(to: .cancelled, cancelReason: reason)
            if recorded > 0 {
                toasts.show("Job cancelled. " + JobDetailView.recordedPaymentsText(recorded), style: .info, duration: .seconds(6))
            } else {
                toasts.show("Job cancelled")
            }
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
