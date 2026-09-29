//
//  OpsServiceFollowupsSection.swift
//  DetailCRM
//
//  Maintenance follow-ups of a service (P-4) on the catalog item screen:
//  which texts / emails go out how long after a completed job with it
//  ("After 6 months · Text · On"). Read-only on the phone; the wording and
//  timing are edited in the web app. Managers and above only (the server
//  returns nothing to technicians).
//  Email follow-ups are marketing email: since 0119 they are not queued
//  while the shop has no street address and city on file, so an email one
//  that is switched on then reads "Not sent" with the reason
//  (DetailCore `MarketingAddress`, the web's MarketingAddressNotice).
//

import SwiftUI
import DetailCore

struct OpsServiceFollowupsSection: View {
    /// Loaded by the catalog item screen (a Section's own `.task` would
    /// attach to each of its rows).
    let state: LoadState<[OpsServiceFollowup]>
    /// The shop has a street address and city on file (nil = not known:
    /// no warning).
    let addressOnFile: Bool?
    /// Owners and admins add the address themselves.
    let canEditBusinessProfile: Bool
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
                    if followups.contains(where: isBlocked) {
                        AddressWarning(text: MarketingAddress.followupsWarning(canEditBusinessProfile: canEditBusinessProfile))
                            .themedRow()
                    }
                    ForEach(followups) { followup in
                        Row(followup: followup, notSent: isBlocked(followup))
                            .themedRow()
                    }
                }
            }
        } header: {
            Text("Follow-ups")
        } footer: {
            Text("Sent after a completed job with this service, unless the customer already has another visit for it booked. Each channel also needs the shop's “Service follow-up” message switched on, and emails need the shop's street address and city on file. Edit follow-ups in the web app.")
        }
    }

    private func isBlocked(_ followup: OpsServiceFollowup) -> Bool {
        MarketingAddress.isBlockedFollowup(channel: followup.channel, enabled: followup.enabled, addressOnFile: addressOnFile)
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
    /// Why the email follow-ups aren't going out.
    struct AddressWarning: View {
        let text: String

        var body: some View {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.warningInk)
                    .accessibilityHidden(true)
                Text(text)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Theme.Spacing.xxs)
            .accessibilityElement(children: .combine)
        }
    }

    /// One follow-up: delay, channel, on/off and the start of the wording.
    struct Row: View {
        let followup: OpsServiceFollowup
        /// Switched on but not sent (an email one without the shop's
        /// mailing address).
        var notSent = false

        private var badge: (text: String, tone: StatusTone) {
            if notSent { return (MarketingAddress.notSentBadge, .warning) }
            return followup.enabled ? ("On", .success) : ("Off", .neutral)
        }

        var body: some View {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: followup.channelImage)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(followup.enabled && !notSent ? Theme.glacier : Theme.textTertiary)
                    .frame(width: Theme.Size.rowIcon)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                        Text(followup.delayText)
                            .font(Theme.Typography.bodyEmphasis)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: Theme.Spacing.sm)
                        StatusBadge(text: badge.text, tone: badge.tone)
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
