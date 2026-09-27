//
//  JobMessageSheet.swift
//  DetailCRM
//
//  "On my way" / "Job started" / "Job complete": shows exactly what the
//  shop's template will send for this job, then sends it through the
//  messaging edge function after the user confirms with Send.
//

import SwiftUI
import DetailCore

struct JobMessageSheet: View {
    let model: JobDetailModel
    let key: JobMessageTemplateKey

    @Environment(\.dismiss) private var dismiss
    @Environment(ToastCenter.self) private var toasts
    @State private var channel: JobMessageChannel = .sms
    @State private var preview: LoadState<JobMessagePreview?> = .idle
    @State private var errorMessage: String?
    /// Reused when Send is tapped again on the same channel, so the server
    /// never queues the message twice (see `InboxComposeAttempt`).
    @State private var lastAttempt: InboxComposeAttempt?

    var body: some View {
        NavigationStack {
            FormScreen {
                Picker("Send by", selection: $channel) {
                    ForEach(JobMessageChannel.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                previewBlock
                if let errorMessage {
                    InlineMessage(text: errorMessage, kind: .error)
                }
                AsyncButton(style: .themePrimary) {
                    await send()
                } label: {
                    Label("Send \(channel == .sms ? "text" : "email")", systemImage: "paperplane.fill")
                }
                .disabled(!canSend)
            }
            .navigationTitle(key.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: channel) { await loadPreview() }
        }
    }

    private var canSend: Bool {
        guard let loaded = preview.value else { return false }
        guard let value = loaded else { return true }
        return value.enabled != false
    }

    @ViewBuilder
    private var previewBlock: some View {
        switch preview {
        case .idle, .loading:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView().tint(Theme.glacier)
                Text("Preparing preview…")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                InlineMessage(text: message, kind: .error)
                AsyncButton("Try again", style: .themeSecondaryCompact) {
                    await loadPreview()
                }
            }
        case .loaded(let value):
            if let value {
                previewCard(value)
            } else {
                InlineMessage(text: "No preview available. The shop's template will be used.", kind: .info)
            }
        }
    }

    private func previewCard(_ value: JobMessagePreview) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if value.enabled == false {
                InlineMessage(text: "This template is turned off for \(channel.displayName.lowercased()) messages in the shop's settings.", kind: .info)
            }
            if let to = value.toAddress?.trimmedNonEmpty {
                InfoRow(label: "To", value: channel == .sms ? PhoneNumber.format(to) : to)
            } else {
                InlineMessage(
                    text: channel == .sms ? "This customer has no mobile number on file." : "This customer has no email address on file.",
                    kind: .info
                )
            }
            if let subject = value.subject?.trimmedNonEmpty, channel == .email {
                InfoRow(label: "Subject", value: subject)
            }
            Text(value.body?.trimmedNonEmpty ?? "(empty message)")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(Theme.surfaceMuted)
                )
        }
    }

    private func loadPreview() async {
        preview = .loading
        errorMessage = nil
        let jobID = model.jobID
        let currentKey = key
        let currentChannel = channel
        preview = await LoadState<JobMessagePreview?>.result {
            try await JobService.previewTemplate(jobID: jobID, key: currentKey, channel: currentChannel)
        }
    }

    private func send() async {
        errorMessage = nil
        let attempt = InboxComposeAttempt.next(
            after: lastAttempt,
            fingerprint: [model.jobID.uuidString, key.rawValue, channel.rawValue]
        )
        lastAttempt = attempt
        do {
            let result = try await model.sendMessage(key, channel: channel, nonce: attempt.nonce)
            if result.didFail {
                errorMessage = result.error.map { ErrorText.sentence($0) } ?? "The message couldn't be delivered."
                return
            }
            toasts.show(channel == .sms ? "Text sent" : "Email sent")
            dismiss()
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
