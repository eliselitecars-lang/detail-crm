//
//  TeamInviteLinkSheet.swift
//  DetailCRM
//
//  Shown when an invite exists but its email did not go out (the email
//  service failed or the invites function is unavailable): the admin
//  shares the join link another way. Used after inviting and resending.
//

import SwiftUI
import DetailCore

/// An invite whose link must be shared by hand.
struct TeamInviteShare: Identifiable, Equatable {
    let id = UUID()
    let email: String
    let link: URL?
    /// True when this is a new link (older links for this email stop working).
    let newLink: Bool
}

/// The "email didn't go out — share this link" content (no navigation chrome).
struct TeamInviteLinkPanel: View {
    let share: TeamInviteShare

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            InlineMessage(
                text: "The invite is saved, but the email to \(share.email) didn't go out.",
                kind: .error
            )
            if let link = share.link {
                Text("Send them this link another way (text or your own email). It expires in 7 days.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(link.absoluteString)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ShareLink(item: link) {
                    Label("Share invite link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.themePrimary)
            } else {
                Text("Use Share link on the invite under Pending invites, or try Resend later.")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if share.newLink {
                Text("Any earlier link for this email no longer works.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Stand-alone sheet around `TeamInviteLinkPanel` (used after a resend).
struct TeamInviteLinkSheet: View {
    let share: TeamInviteShare

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FormScreen {
                TeamInviteLinkPanel(share: share)
            }
            .screenBackground()
            .navigationTitle("Share invite link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
