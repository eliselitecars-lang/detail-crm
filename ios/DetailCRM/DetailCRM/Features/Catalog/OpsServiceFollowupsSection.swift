//
//  OpsServiceFollowupsSection.swift
//  DetailCRM
//
//  Maintenance follow-ups of a service (P-4) on the catalog item screen:
//  which texts / emails go out how long after a completed job with it
//  ("After 6 months · Text · On"). Read-only on the phone; the wording and
//  timing are edited in the web app. Managers and above only (the server
//  returns nothing to technicians).
//

import SwiftUI
import DetailCore

struct OpsServiceFollowupsSection: View {
    /// Loaded by the catalog item screen (a Section's own `.task` would
    /// attach to each of its rows).
    let state: LoadState<[OpsServiceFollowup]>
    let retry: () async -> Void

    var body: some View {
        Section {
            switch state {
            case .idle, .loading:
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView()
                    Text("Loading follow-ups…")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .themedRow()
            case .failed(let message):
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    InlineMessage(text: message, kind: .error)
                    AsyncButton("Try again", style: .themeSecondaryCompact) {
                        await retry()
                    }
                }
                .themedRow()
            case .loaded(let followups):
                if followups.isEmpty {
                    Text("No follow-ups for this service yet.")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .themedRow()
                } else {
                    ForEach(followups) { followup in
                        Row(followup: followup)
                            .themedRow()
                    }
                }
            }
        } header: {
            Text("Follow-ups")
        } footer: {
            Text("Sent after a completed job with this service, unless the customer already has another visit for it booked. Each channel also needs the shop's “Service follow-up” message switched on. Edit follow-ups in the web app.")
        }
    }

    /// Loads the follow-ups of `serviceID` into `state` (managers+).
    @MainActor
    static func load(into state: Binding<LoadState<[OpsServiceFollowup]>>, shopID: UUID?, serviceID: UUID) async {
        guard let shopID else {
            state.wrappedValue = .failed(AppError.noShopSelected.errorDescription ?? "Choose a shop first.")
            return
        }
        state.wrappedValue.beginLoading()
        let result = await LoadState<[OpsServiceFollowup]>.result {
            try await CatalogService.serviceFollowups(shopID: shopID, serviceID: serviceID)
        }
        state.wrappedValue.apply(result)
    }
}

extension OpsServiceFollowupsSection {
    /// One follow-up: delay, channel, on/off and the start of the wording.
    struct Row: View {
        let followup: OpsServiceFollowup

        var body: some View {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: followup.channelImage)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(followup.enabled ? Theme.glacier : Theme.textTertiary)
                    .frame(width: Theme.Size.rowIcon)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                        Text(followup.delayText)
                            .font(Theme.Typography.bodyEmphasis)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: Theme.Spacing.sm)
                        StatusBadge(text: followup.enabled ? "On" : "Off", tone: followup.enabled ? .success : .neutral)
                    }
                    Text(followup.channelName)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    if let subject = followup.subject?.trimmedNonEmpty {
                        Text(subject)
                            .font(Theme.Typography.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                    Text(followup.body)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                }
            }
            .padding(.vertical, Theme.Spacing.xxs)
            .accessibilityElement(children: .combine)
        }
    }
}
