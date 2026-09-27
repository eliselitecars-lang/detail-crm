//
//  TeamInviteSheet.swift
//  DetailCRM
//
//  Owner/admin sheet: email + role (limited to the roles the actor may
//  grant — never owner). The `invites` edge function creates the invite
//  and emails the link; the server re-checks the role and membership.
//  When the email doesn't go out, the sheet switches to the link to share.
//

import SwiftUI
import DetailCore

struct TeamInviteSheet: View {
    let actorRole: ShopRole
    let onSent: () async -> Void

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var role: ShopRole = .technician
    @State private var errorMessage: String?
    /// Set when the invite was created but not emailed.
    @State private var share: TeamInviteShare?

    private var roles: [ShopRole] { actorRole.invitableRoles }

    private var emailProblem: String? {
        guard let text = email.trimmedNonEmpty else { return nil }
        return Validation.isValidEmail(text) ? nil : "Enter a valid email address."
    }

    var body: some View {
        NavigationStack {
            FormScreen {
                if let share {
                    TeamInviteLinkPanel(share: share)
                } else if roles.isEmpty {
                    InlineMessage(text: "Only owners and admins can invite team members.", kind: .info)
                } else {
                    Text("They'll get an email with a link to join \(appState.shop?.name ?? "your shop"). The link expires in 7 days.")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ThemedTextField(
                        label: "Email",
                        placeholder: "name@example.com",
                        text: $email,
                        kind: .email,
                        error: emailProblem
                    )
                    FormRow("Role", hint: roleHint) {
                        Picker("Role", selection: $role) {
                            ForEach(roles, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    if let errorMessage {
                        InlineMessage(text: errorMessage, kind: .error)
                    }
                    AsyncButton("Send invite", style: .themePrimary) {
                        await send()
                    }
                    .disabled(email.trimmedNonEmpty == nil || emailProblem != nil)
                }
            }
            .navigationTitle(share == nil ? "Invite teammate" : "Share invite link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(share == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
            .onAppear {
                if !roles.contains(role), let first = roles.last {
                    role = first
                }
            }
        }
    }

    private var roleHint: String {
        switch role {
        case .admin: return "Full access except deleting or transferring the shop."
        case .manager: return "Jobs, customers, calendar and money. No settings or pay."
        case .technician: return "Only their assigned jobs, time clock and own reports."
        case .owner: return ""
        }
    }

    private func send() async {
        errorMessage = nil
        guard roles.contains(role) else {
            errorMessage = "You can't invite someone with that role."
            return
        }
        do {
            let shopID = try appState.requireShopID()
            let address = Validation.normalizedEmail(email)
            let outcome = try await TeamService.sendInvite(shopID: shopID, email: address, role: role)
            switch outcome {
            case .emailed:
                toasts.show("Invite sent to \(address).")
                await onSent()
                dismiss()
            case .createdWithoutEmail(let link, let newLink):
                share = TeamInviteShare(email: address, link: link, newLink: newLink)
                await onSent()
            }
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
