//
//  TeamView.swift
//  DetailCRM
//
//  Team directory for everyone (technicians see names and colours only),
//  pending invites with resend / revoke / share link for owners and
//  admins, and an invite sheet. Member detail handles role changes,
//  (de)activation and pay settings. The server enforces every rule
//  (SPEC §3); the UI only hides what a role can't do.
//

import SwiftUI
import DetailCore

struct TeamView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var state: LoadState<[TeamDirectoryEntry]> = .idle
    /// Loaded separately so a failed invites read never hides the directory.
    @State private var invitesState: LoadState<[TeamInvite]> = .idle
    @State private var showInvite = false
    @State private var share: TeamInviteShare?
    @State private var confirmation: ConfirmationRequest?

    var body: some View {
        LoadStateView(state, loadingLabel: "Loading team…", retry: { await load() }) { members in
            TeamList(
                members: members,
                invitesState: invitesState,
                clock: appState.clock,
                myMemberID: appState.member?.id,
                canManage: appState.can(.manageTeam),
                canViewDetails: appState.can(.viewTeamDetails),
                retryInvites: { await loadInvites() },
                resend: { invite in await resend(invite) },
                revoke: { invite in confirmRevoke(invite) }
            )
        }
        .screenBackground()
        .navigationTitle("Team")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showInvite) {
            TeamInviteSheet(actorRole: appState.role ?? .technician) {
                await load()
            }
        }
        .sheet(item: $share) { item in
            TeamInviteLinkSheet(share: item)
        }
        .navigationDestination(for: TeamDirectoryEntry.self) { member in
            TeamMemberDetailView(member: member) {
                await load()
            }
        }
        .confirmation($confirmation)
        .task { await load() }
        .refreshable { await load() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if appState.can(.manageTeam) {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInvite = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
                .accessibilityLabel("Invite a team member")
            }
        }
    }

    private func load() async {
        guard let shopID = appState.shop?.id else {
            state = .failed(AppError.noShopSelected.errorDescription ?? "Choose a shop first.")
            return
        }
        state.beginLoading()
        let result = await LoadState<[TeamDirectoryEntry]>.result {
            try await TeamService.directory(shopID: shopID)
        }
        if let message = result.errorMessage, state.value != nil {
            toasts.show(message, style: .error)
        }
        state.apply(result)
        await loadInvites()
    }

    /// Open invites (owners/admins only); failures stay inside the section.
    private func loadInvites() async {
        guard appState.can(.manageTeam), let shopID = appState.shop?.id else {
            invitesState = .loaded([])
            return
        }
        invitesState.beginLoading()
        let result = await LoadState<[TeamInvite]>.result {
            try await TeamService.pendingInvites(shopID: shopID)
        }
        if let message = result.errorMessage, invitesState.value != nil {
            toasts.show(message, style: .error)
        }
        invitesState.apply(result)
    }

    private func resend(_ invite: TeamInvite) async {
        do {
            let outcome = try await TeamService.resendInvite(invite)
            switch outcome {
            case .emailed(let newLink):
                toasts.show(newLink
                    ? "The old invite had expired. A new link was emailed to \(invite.email)."
                    : "The invite was emailed to \(invite.email) again.")
            case .createdWithoutEmail(let link, let newLink):
                share = TeamInviteShare(email: invite.email, link: link, newLink: newLink)
            }
        } catch {
            toasts.showError(error)
        }
        await loadInvites()
    }

    private func confirmRevoke(_ invite: TeamInvite) {
        confirmation = ConfirmationRequest(
            title: "Revoke this invite?",
            message: "\(invite.email) won't be able to join with this link.",
            confirmTitle: "Revoke",
            isDestructive: true
        ) {
            do {
                try await TeamService.revokeInvite(inviteID: invite.id)
                toasts.show("Invite revoked.")
            } catch {
                toasts.showError(error)
            }
            await loadInvites()
        }
    }
}

private struct TeamList: View {
    let members: [TeamDirectoryEntry]
    let invitesState: LoadState<[TeamInvite]>
    let clock: ShopClock
    let myMemberID: UUID?
    let canManage: Bool
    let canViewDetails: Bool
    let retryInvites: () async -> Void
    let resend: (TeamInvite) async -> Void
    let revoke: (TeamInvite) -> Void

    var body: some View {
        let active = members.filter { $0.active }
        let inactive = members.filter { !$0.active }
        List {
            Section {
                if active.isEmpty {
                    Text("No active members.")
                        .foregroundStyle(Theme.textSecondary)
                        .themedRow()
                } else {
                    ForEach(active) { member in
                        memberRow(member)
                    }
                }
            } header: {
                Text("Members (\(active.count))")
            } footer: {
                Text(canViewDetails
                    ? "Tap your own name to change how it appears to the team."
                    : "Tap your own name to change how it appears. Contact details and pay are visible to managers and admins.")
            }
            if !inactive.isEmpty {
                Section {
                    ForEach(inactive) { member in
                        memberRow(member)
                    }
                } header: {
                    Text("Inactive")
                }
            }
            if canManage {
                TeamInvitesSection(state: invitesState, clock: clock, retry: retryInvites, resend: resend, revoke: revoke)
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func memberRow(_ member: TeamDirectoryEntry) -> some View {
        if canViewDetails || member.memberID == myMemberID {
            NavigationLink(value: member) {
                TeamMemberRow(member: member, isMe: member.memberID == myMemberID)
            }
            .themedRow()
        } else {
            TeamMemberRow(member: member, isMe: false)
                .themedRow()
        }
    }
}

struct TeamMemberRow: View {
    let member: TeamDirectoryEntry
    let isMe: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            AvatarView(name: member.displayName, size: Theme.Size.avatarSmall, colorHex: member.calendarColor)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(isMe ? "\(member.displayName) (you)" : member.displayName)
                    .font(Theme.Typography.bodyEmphasis)
                    .foregroundStyle(member.active ? Theme.textPrimary : Theme.textSecondary)
                if let email = member.email, !email.isEmpty {
                    Text(email)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            if !member.active {
                StatusBadge(text: "Inactive", tone: .neutral)
            }
            StatusBadge(member.role)
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

/// Open invites: expiry, share link, resend, revoke. Loading and errors
/// are shown inside the section so the member list stays usable.
private struct TeamInvitesSection: View {
    let state: LoadState<[TeamInvite]>
    let clock: ShopClock
    let retry: () async -> Void
    let resend: (TeamInvite) async -> Void
    let revoke: (TeamInvite) -> Void

    var body: some View {
        Section {
            switch state {
            case .idle, .loading:
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView()
                    Text("Loading invites…")
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
            case .loaded(let invites):
                if invites.isEmpty {
                    Text("No pending invites.")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .themedRow()
                } else {
                    ForEach(invites) { invite in
                        TeamInviteRow(invite: invite, clock: clock, resend: resend, revoke: revoke)
                            .themedRow()
                    }
                }
            }
        } header: {
            Text("Pending invites")
        } footer: {
            Text("Resending emails the same link again; an expired invite gets a new link.")
        }
    }
}

private struct TeamInviteRow: View {
    let invite: TeamInvite
    let clock: ShopClock
    let resend: (TeamInvite) async -> Void
    let revoke: (TeamInvite) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(invite.email)
                    .font(Theme.Typography.bodyEmphasis)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Spacing.sm)
                StatusBadge(invite.role)
            }
            Text(expiryText)
                .font(Theme.Typography.footnote)
                .foregroundStyle(invite.isExpired() ? Theme.warning : Theme.textSecondary)
            HStack(spacing: Theme.Spacing.sm) {
                AsyncButton("Resend", style: .themeSecondaryCompact) {
                    await resend(invite)
                }
                if let link = invite.link, !invite.isExpired() {
                    ShareLink(item: link) {
                        Label("Share link", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.themeSecondaryCompact)
                }
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    revoke(invite)
                } label: {
                    Text("Revoke")
                        .foregroundStyle(Theme.danger)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var expiryText: String {
        if invite.isExpired() {
            return "Expired \(clock.shortDayText(invite.expiresAt)) — resend to issue a new link."
        }
        return "Sent \(clock.shortDayText(invite.createdAt)) · expires \(clock.dateTimeText(invite.expiresAt))"
    }
}
