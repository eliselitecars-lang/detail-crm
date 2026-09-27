//
//  MoneyDocumentMessagePreview.swift
//  DetailCRM
//
//  The quote / invoice send sheets show exactly what the customer will
//  get: the server renders the shop's quote_sent / invoice_sent wording
//  with the document's link, total and balance (`preview_document_message`)
//  — the same text the send queues. Nothing is rendered in the app.
//

import SwiftUI
import DetailCore

struct MoneyDocumentMessagePreviewView: View {
    let request: MoneyDocumentMessage.Request

    @State private var state: LoadState<MoneyDocumentPreview?> = .idle

    var body: some View {
        content
            .task(id: request) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
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
                    await load()
                }
            }
        case .loaded(let value):
            if let value {
                card(value)
            } else {
                InlineMessage(
                    text: "Your shop has no \"\(request.kind.documentNoun) sent\" \(channelNoun) yet. Add it in Settings, or share the link yourself.",
                    kind: .info
                )
            }
        }
    }

    private var channelNoun: String {
        request.channel == .sms ? "text" : "email"
    }

    private func card(_ value: MoneyDocumentPreview) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if !value.enabled {
                InlineMessage(text: MoneyDocumentMessage.disabledText(request), kind: .info)
            }
            if let to = value.toAddress?.trimmedNonEmpty {
                InfoRow(label: "To", value: request.channel == .sms ? PhoneNumber.format(to) : to)
            } else {
                InlineMessage(
                    text: request.channel == .sms
                        ? "This customer has no mobile number on file."
                        : "This customer has no email address on file.",
                    kind: .info
                )
            }
            if request.channel == .email, let subject = value.subject?.trimmedNonEmpty {
                InfoRow(label: "Subject", value: subject)
            }
            Text(value.body.trimmedNonEmpty ?? "(empty message)")
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

    private func load() async {
        state = .loading
        let current = request
        let result = await LoadState<MoneyDocumentPreview?>.result {
            try await MoneyDocumentMessage.preview(request: current)
        }
        // A newer request (channel switch) replaced this load: keep quiet.
        if case .idle = result { return }
        state = result
    }
}
