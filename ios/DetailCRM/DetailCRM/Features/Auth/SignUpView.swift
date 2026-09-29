//
//  SignUpView.swift
//  DetailCRM
//
//  Account creation. After sign-up the user either lands in onboarding
//  (create or join a shop) or, when the project requires email
//  confirmation, sees instructions to confirm first. The Terms of Service
//  and Privacy Policy links sit under the button (creating the account is
//  what the Terms count as acceptance).
//

import SwiftUI
import DetailCore

struct SignUpView: View {
    @State private var fullName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var showErrors = false
    @State private var errorMessage: String?
    @State private var confirmationEmail: String?

    private var nameError: String? {
        guard showErrors else { return nil }
        return Validation.isPresent(fullName) ? nil : "Enter your name."
    }

    private var emailError: String? {
        guard showErrors else { return nil }
        return Validation.isValidEmail(email) ? nil : "Enter a valid email address."
    }

    private var passwordError: String? {
        guard showErrors else { return nil }
        return Validation.isAcceptablePassword(password)
            ? nil
            : "Use at least \(Validation.minimumPasswordLength) characters."
    }

    var body: some View {
        FormScreen {
            if let confirmationEmail {
                ConfirmEmailNotice(email: confirmationEmail)
            } else {
                form
            }
        }
        .navigationTitle("Create account")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            AuthHeader(
                title: "Create your account",
                subtitle: "You'll set up your shop — or join your team's — right after."
            )
            VStack(spacing: Theme.Spacing.lg) {
                ThemedTextField(label: "Your name", placeholder: "First and last name", text: $fullName,
                                kind: .name, error: nameError)
                ThemedTextField(label: "Email", placeholder: "you@yourshop.com", text: $email,
                                kind: .email, error: emailError)
                ThemedTextField(label: "Password", placeholder: "At least \(Validation.minimumPasswordLength) characters",
                                text: $password, kind: .newPassword, error: passwordError)
                if let errorMessage {
                    InlineMessage(text: errorMessage, kind: .error)
                }
                AsyncButton("Create account") {
                    await signUp()
                }
                LegalLinksFooter(step: .createAccount)
            }
        }
    }

    private func signUp() async {
        showErrors = true
        errorMessage = nil
        guard Validation.isPresent(fullName),
              Validation.isValidEmail(email),
              Validation.isAcceptablePassword(password) else { return }
        do {
            let outcome = try await AuthService.signUp(fullName: fullName, email: email, password: password)
            switch outcome {
            case .signedIn:
                break // AppState moves to onboarding.
            case .confirmationRequired(let address):
                confirmationEmail = address
            }
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}

private struct ConfirmEmailNotice: View {
    let email: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 40))
                .foregroundStyle(Theme.glacier)
                .accessibilityHidden(true)
            Text("Check your email")
                .font(Theme.Typography.largeTitle)
                .foregroundStyle(Theme.textPrimary)
            Text("We sent a confirmation link to \(email). Open it on this phone, then come back and sign in.")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
