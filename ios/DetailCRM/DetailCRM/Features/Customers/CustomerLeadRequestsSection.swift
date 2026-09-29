//
//  CustomerLeadRequestsSection.swift
//  DetailCRM
//
//  "Web form requests" on the customer screen (P-9): what the customer
//  asked for on the shop's lead forms — the message, the vehicle they
//  described and their answers — newest first. A lead form never changes
//  an existing customer's record, so this is the only place staff see the
//  request; the new-lead notification (push or bell) opens this screen.
//  Managers and up (the server's rule for lead_submissions); nothing is
//  shown for a customer who never sent a form.
//

import SwiftUI
import DetailCore

struct CustomerLeadRequestsSection: View {
    let state: LoadState<CustomerLeadRequests>
    /// The shop's customer fields (archived ones too) to label answers.
    let fields: [JobsCustomField]
    let clock: ShopClock
    let retry: () async -> Void

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .loading:
            CustomersSectionCard("Web form requests") {
                CustomersSectionStatusRow(kind: .loading)
            }
        case .failed(let message):
            CustomersSectionCard("Web form requests") {
                CustomersSectionStatusRow(kind: .failed(message), retry: retry)
            }
        case .loaded(let loaded):
            if !loaded.requests.isEmpty {
                CustomersSectionCard("Web form requests") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text(loaded.description)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(loaded.requests.enumerated()), id: \.element.id) { index, request in
                            if index > 0 { CustomersRowDivider() }
                            CustomerLeadRequestRowView(request: request, fields: fields, clock: clock)
                        }
                        if loaded.total > loaded.requests.count {
                            CustomersRowDivider()
                            Text("Older requests aren't shown.")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
    }
}

private struct CustomerLeadRequestRowView: View {
    let request: CustomerLeadRequest
    let fields: [JobsCustomField]
    let clock: ShopClock

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            header
            if let message = request.message {
                Text(message)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(Theme.surfaceMuted)
                    )
            } else {
                Text("No message.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let vehicle = request.vehicleText {
                CustomerLeadAnswerRow(label: "Vehicle described", value: vehicle)
            }
            ForEach(request.answers(fields: fields)) { answer in
                CustomerLeadAnswerRow(label: answer.label, value: answer.value)
            }
            if request.matchedExisting && request.vehicleText != nil {
                Text(LeadRequestText.matchedExistingNote)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                Image(systemName: "tray.and.arrow.down")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text(request.title)
                    .font(Theme.Typography.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if request.matchedExisting {
                    StatusBadge(text: "Existing customer", tone: .neutral)
                }
            }
            Text(clock.dateTimeText(request.createdAt))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Label above value, selectable (a gate code, a phone number).
private struct CustomerLeadAnswerRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
