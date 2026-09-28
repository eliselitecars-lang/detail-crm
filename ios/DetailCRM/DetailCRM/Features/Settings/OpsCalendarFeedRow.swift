//
//  OpsCalendarFeedRow.swift
//  DetailCRM
//
//  "Subscribe in Calendar" (P-19): the signed-in member's private iCal
//  feed of their jobs for Apple Calendar, Google Calendar or Outlook.
//  Owners, admins and managers can include every job of the shop. The link
//  is a credential (anyone with it sees the jobs), so it can be reset —
//  which stops the old link — or turned off.
//

import SwiftUI
import UIKit
import DetailCore

struct OpsCalendarFeedRow: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.openURL) private var openURL

    @State private var state: LoadState<OpsCalendarFeed?> = .idle
    @State private var includeAll = false
    @State private var working = false
    @State private var confirmation: ConfirmationRequest?

    private var canIncludeAll: Bool { appState.role?.isManagerOrAbove ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "Calendar subscription")
            Text(explanation)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .task(id: appState.shop?.id) { await load() }
        .confirmation($confirmation)
    }

    private var explanation: String {
        "Add your jobs to Apple Calendar, Google Calendar or Outlook. Calendar apps check for changes every so often, so updates can take a while to show. Anyone with the link can see these jobs — keep it private."
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView()
                Text("Loading…")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                InlineMessage(text: message, kind: .error)
                AsyncButton("Try again", style: .themeSecondaryCompact) {
                    await load()
                }
            }
        case .loaded(let feed):
            if AppConfig.supabaseURL == nil {
                InlineMessage(text: "This build isn't connected to a server, so there is no calendar link.", kind: .error)
            } else if let feed {
                active(feed)
            } else {
                inactive
            }
        }
    }

    private var inactive: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if canIncludeAll {
                Toggle(isOn: $includeAll) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("Include every job in the shop")
                            .font(Theme.Typography.subheadline)
                        Text("Off: only jobs assigned to you.")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .tint(Theme.glacier)
            }
            AsyncButton(style: .themePrimary) {
                await create(subscribeAfter: true)
            } label: {
                Label("Subscribe in Calendar", systemImage: "calendar.badge.plus")
            }
            .disabled(working)
        }
    }

    private func active(_ feed: OpsCalendarFeed) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                StatusBadge(text: "On", tone: .success)
                Text(feed.includeAll ? "Every job in the shop" : "Jobs assigned to you")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textPrimary)
            }
            if let lastRead = feed.lastAccessedAt {
                Text("Last checked by a calendar app \(appState.clock.relativeDayText(lastRead)), \(appState.clock.timeText(lastRead)).")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text("No calendar app has read this link yet.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Button {
                if let url = feed.webcalURL { openURL(url) }
            } label: {
                Label("Subscribe in Calendar", systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.themePrimary)
            .disabled(feed.webcalURL == nil)
            .accessibilityHint("Opens the Calendar app to add the subscription")
            AdaptiveButtonRow(spacing: Theme.Spacing.sm) {
                Button {
                    guard let url = feed.httpsURL else { return }
                    UIPasteboard.general.url = url
                    toasts.show("Calendar link copied. In Google Calendar, add it under Other calendars › From URL.")
                } label: {
                    Label("Copy link", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.themeSecondaryCompact)
                .disabled(feed.httpsURL == nil)
                Menu {
                    if canIncludeAll {
                        Button(feed.includeAll ? "Only my jobs (new link)" : "Every job in the shop (new link)",
                               systemImage: "arrow.triangle.2.circlepath") {
                            confirmReset(includeAll: !feed.includeAll)
                        }
                    }
                    Button("Reset link", systemImage: "arrow.clockwise") {
                        confirmReset(includeAll: feed.includeAll)
                    }
                    Button("Turn off", systemImage: "xmark.circle", role: .destructive) {
                        confirmTurnOff()
                    }
                } label: {
                    Label("Manage", systemImage: "ellipsis.circle")
                        .frame(maxWidth: .infinity)
                }
                .menuStyle(.button)
                .buttonStyle(.themeSecondaryCompact)
                .disabled(working)
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        guard let shopID = appState.shop?.id, let memberID = appState.member?.id else {
            state = .failed(AppError.noShopSelected.errorDescription ?? "Choose a shop first.")
            return
        }
        state.beginLoading()
        let result = await LoadState<OpsCalendarFeed?>.result {
            try await OpsCalendarFeedService.current(shopID: shopID, memberID: memberID)
        }
        state.apply(result)
        if case .loaded(let feed) = state, let feed {
            includeAll = feed.includeAll
        }
    }

    private func create(subscribeAfter: Bool, includeAllOverride: Bool? = nil) async {
        guard let shopID = appState.shop?.id, let memberID = appState.member?.id else { return }
        working = true
        defer { working = false }
        do {
            let wantsAll = canIncludeAll && (includeAllOverride ?? includeAll)
            let feed = try await OpsCalendarFeedService.create(shopID: shopID, memberID: memberID, includeAll: wantsAll)
            state = .loaded(feed)
            includeAll = feed.includeAll
            if subscribeAfter, let url = feed.webcalURL {
                openURL(url)
            } else {
                toasts.show("New calendar link ready. Subscribe again in your calendar app — the old link has stopped working.")
            }
        } catch {
            toasts.showError(error)
            await refreshAfterFailedCreate(shopID: shopID, memberID: memberID)
        }
    }

    /// The server may have replaced the link even though the call failed
    /// (the reply was lost), so the link on screen can be dead. Show the
    /// live one, or an error with Try again when it can't be read — never
    /// a link that may have been revoked.
    private func refreshAfterFailedCreate(shopID: UUID, memberID: UUID) async {
        do {
            let fresh = try await OpsCalendarFeedService.current(shopID: shopID, memberID: memberID)
            state = .loaded(fresh)
            if let fresh { includeAll = fresh.includeAll }
        } catch {
            state = .failed("Couldn't check your calendar link. Try again before sharing it — it may have been replaced.")
        }
    }

    private func confirmReset(includeAll newValue: Bool) {
        confirmation = ConfirmationRequest(
            title: "Make a new calendar link?",
            message: "The current link stops working, so calendars subscribed to it stop updating. Subscribe again with the new link.",
            confirmTitle: "New link"
        ) {
            await create(subscribeAfter: false, includeAllOverride: newValue)
        }
    }

    private func confirmTurnOff() {
        confirmation = ConfirmationRequest(
            title: "Turn off the calendar link?",
            message: "Calendars subscribed to it stop updating. Remove the subscription from your calendar app too.",
            confirmTitle: "Turn off",
            isDestructive: true
        ) {
            await turnOff()
        }
    }

    private func turnOff() async {
        guard let shopID = appState.shop?.id else { return }
        working = true
        defer { working = false }
        do {
            try await OpsCalendarFeedService.revoke(shopID: shopID)
            state = .loaded(nil)
            toasts.show("Calendar link turned off")
        } catch {
            toasts.showError(error)
        }
    }
}
