//
//  ForgotPasswordView.swift
//  DetailCRM
//
//  Sends a reset link; the new password is set on the web reset page.
//

import SwiftUI
import DetailCore

struct ForgotPasswordView: View {
    @State private var email: String
    @State private var showErrors = false
    @State private var errorMessage: String?
    @State private var sentTo: String?

    init(initialEmail: String = "") {
        _email = State(initialValue: initialEmail)
    }

    private var emailError: String? {
        guard showErrors else { return nil }
        return Validation.isValidEmail(email) ? nil : "Enter a valid email address."
    }

    var body: some View {
        FormScreen {
            AuthHeader(
                title: "Reset password",
                subtitle: "We'll email you a link to choose a new password."
            )
            VStack(spacing: Theme.Spacing.lg) {
                ThemedTextField(label: "Email", placeholder: "you@yourshop.com", text: $email,
                                kind: .email, error: emailError)
                if let sentTo {
                    InlineMessage(
                        text: "If an account exists for \(sentTo), a reset link is on its way.",
                        kind: .success
                    )
                }
                if let errorMessage {
                    InlineMessage(text: errorMessage, kind: .error)
                }
                AsyncButton(sentTo == nil ? "Send reset link" : "Send again") {
                    await send()
                }
            }
        }
        .navigationTitle("Reset password")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func send() async {
        showErrors = true
        errorMessage = nil
        guard Validation.isValidEmail(email) else { return }
        do {
            try await AuthService.sendPasswordReset(email: email)
            sentTo = Validation.normalizedEmail(email)
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
