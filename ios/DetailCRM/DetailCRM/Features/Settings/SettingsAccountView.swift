//
//  SettingsAccountView.swift
//  DetailCRM
//
//  The signed-in user's own details: profile name and mobile number
//  (shared across shops) and the name teammates see in this shop, the
//  personal calendar subscription (P-19), the Privacy Policy and Terms of Service (web pages), and deleting the
//  account (every role; App Store guideline 5.1.1(v)). Signing out lives in
//  the More tab.
//

import SwiftUI
import DetailCore

struct SettingsAccountView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var fullName = ""
    @State private var phone = ""
    @State private var displayName = ""
    @State private var loaded = false
    @State private var showErrors = false
    @State private var errorMessage: String?
    @State private var deleteError: String?
    @State private var confirmation: ConfirmationRequest?

    private var phoneProblem: String? {
        guard let text = phone.trimmedNonEmpty else { return nil }
        return PhoneNumber.normalize(text) == nil ? "Enter a valid mobile number." : nil
    }

    private var fullNameProblem: String? {
        fullName.trimmingCharacters(in: .whitespacesAndNewlines).count > 200 ? "Use 200 characters or fewer." : nil
    }

    private var displayNameProblem: String? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter the name your team sees." }
        if trimmed.count > 100 { return "Use 100 characters or fewer." }
        return nil
    }

    private var hasProblems: Bool {
        phoneProblem != nil || fullNameProblem != nil || displayNameProblem != nil
    }

    var body: some View {
        FormScreen {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                SectionHeader(title: "Profile")
                if let email = appState.userEmail {
                    InfoRow(label: "Email", value: email, systemImage: "envelope")
                }
                ThemedTextField(label: "Full name", placeholder: "Your name", text: $fullName, kind: .name,
                                error: showErrors ? fullNameProblem : nil)
                ThemedTextField(label: "Mobile number", placeholder: "(555) 123-4567", text: $phone, kind: .phone,
                                hint: "Optional.", error: showErrors ? phoneProblem : nil)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                SectionHeader(title: appState.shop.map { "In \($0.name)" } ?? "In this shop")
                ThemedTextField(label: "Name shown to your team", placeholder: "Display name", text: $displayName, kind: .name,
                                hint: "Appears on the calendar, jobs and the team list.",
                                error: showErrors ? displayNameProblem : nil)
                if let role = appState.role {
                    HStack {
                        Text("Role")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        StatusBadge(role)
                    }
                }
            }
            if let errorMessage {
                InlineMessage(text: errorMessage, kind: .error)
            }
            AsyncButton("Save", style: .themePrimary) {
                await save()
            }
            .disabled(!loaded)
            Text("To sign out or switch shops, use the More tab.")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textTertiary)
            OpsCalendarFeedRow()
            SettingsLegalSection()
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(title: "Delete account")
                Text("Permanently deletes your sign-in and profile and removes you from every shop. The shops' customers, jobs and payments stay with the shops. A shop owner must first transfer ownership or delete the shop.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let deleteError {
                    InlineMessage(text: deleteError, kind: .error)
                }
                Button(role: .destructive) {
                    confirmDelete()
                } label: {
                    Text("Delete account")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.themeDestructive)
            }
        }
        .confirmation($confirmation)
        .navigationTitle("Your account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            fullName = appState.profile?.fullName ?? ""
            phone = appState.profile?.phone.map { PhoneNumber.format($0) } ?? ""
            displayName = appState.member?.displayName ?? ""
            loaded = true
        }
    }

    private func confirmDelete() {
        deleteError = nil
        confirmation = ConfirmationRequest(
            title: "Delete your account?",
            message: "This can't be undone. You'll be signed out on this device and can't sign in again with \(appState.userEmail ?? "this email").",
            confirmTitle: "Delete account",
            isDestructive: true
        ) {
            await deleteAccount()
        }
    }

    private func deleteAccount() async {
        do {
            try await AccountService.deleteAccount()
        } catch {
            deleteError = ErrorText.message(for: error)
            return
        }
        toasts.show("Your account was deleted.")
        await appState.signOut()
    }

    private func save() async {
        errorMessage = nil
        showErrors = true
        guard !hasProblems else { return }
        let name = fullName.trimmedNonEmpty
        let e164 = phone.trimmedNonEmpty.flatMap { PhoneNumber.normalize($0) }
        let shownName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let profileChanged = name != appState.profile?.fullName || e164 != appState.profile?.phone
            if profileChanged {
                try await SettingsService.updateMyProfile(fullName: name, phone: e164)
            }
            if let member = appState.member, shownName != member.displayName {
                try await SettingsService.updateMyDisplayName(shopID: member.shopID, memberID: member.id, displayName: shownName)
            }
            try await appState.refreshCurrentShop()
            showErrors = false
            toasts.show("Account saved.")
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
