//
//  JoinShopView.swift
//  DetailCRM
//
//  Join a team by invite: paste the invite link (or code) from the email,
//  review which shop and role it is for, then accept. The server checks
//  that the invite matches the signed-in (confirmed) email address.
//

import SwiftUI
import DetailCore

struct JoinShopView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var token: UUID?
    @State private var preview: LoadState<InvitePreview?> = .idle
    @State private var errorMessage: String?

    var body: some View {
        FormScreen {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Join your team")
                    .font(Theme.Typography.largeTitle)
                    .foregroundStyle(Theme.textPrimary)
                Text(introText)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: Theme.Spacing.lg) {
                ThemedTextField(
                    label: "Invite link or code",
                    placeholder: "https://…/invite/…",
                    text: $input,
                    kind: .url,
                    error: input.isEmpty || token != nil ? nil : "That doesn't look like an invite link."
                )
                previewSection
                if let errorMessage {
                    InlineMessage(text: errorMessage, kind: .error)
                }
                if let invite = preview.value ?? nil, invite.isPending {
                    AsyncButton("Join \(invite.shopName)") {
                        await accept()
                    }
                }
            }
        }
        .navigationTitle("Join a shop")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: input) { _, newValue in
            token = ShopService.inviteToken(from: newValue)
            errorMessage = nil
        }
        .task(id: token) {
            await loadPreview()
        }
    }

    private var introText: String {
        let base = "Paste the invite link from your email. Invites are tied to the address they were sent to"
        if let email = appState.userEmail {
            return base + " — you're signed in as " + email + "."
        }
        return base + "."
    }

    @ViewBuilder
    private var previewSection: some View {
        if token != nil {
            switch preview {
            case .idle, .loading:
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView()
                    Text("Checking invite…")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .failed(let message):
                InlineMessage(text: message, kind: .error)
            case .loaded(let invite):
                if let invite {
                    InvitePreviewCard(invite: invite)
                } else {
                    InlineMessage(text: "We couldn't find that invite. Ask for a new link.", kind: .error)
                }
            }
        }
    }

    private func loadPreview() async {
        guard let token else {
            preview = .idle
            return
        }
        preview = .loading
        let result = await LoadState<InvitePreview?>.result {
            try await ShopService.invitePreview(token: token)
        }
        preview.apply(result)
    }

    private func accept() async {
        guard let token else { return }
        errorMessage = nil
        let member: ShopMember
        do {
            member = try await ShopService.acceptInvite(token: token)
        } catch {
            errorMessage = ErrorText.message(for: error)
            return
        }
        var shopName: String?
        if case .loaded(let invite?) = preview {
            shopName = invite.shopName
        }
        do {
            // Activating the shop swaps the root to the main tabs.
            try await appState.activateShop(member.shopID)
            toasts.show(shopName.map { "You joined \($0)." } ?? "You joined the team.")
        } catch {
            // The invite is already accepted; only opening the shop failed.
            // Go back to the list (pull to refresh shows it) rather than
            // offering to accept the used invite again.
            toasts.show("You joined \(shopName ?? "the team"). Pull down to refresh your shops and open it.",
                        style: .info, duration: .seconds(6))
            dismiss()
        }
    }
}

private struct InvitePreviewCard: View {
    let invite: InvitePreview

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text(invite.shopName)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                StatusBadge(invite.role)
            }
            InfoRow(label: "Sent to", value: invite.email)
            InlineMessage(text: invite.statusMessage, kind: invite.isPending ? .success : .error)
        }
        .cardStyle()
    }
}
