//
//  SignInView.swift
//  DetailCRM
//

import SwiftUI
import DetailCore

struct SignInView: View {
    @Binding var path: [AuthRoute]
    @Environment(AppState.self) private var appState

    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var showErrors = false

    private var emailError: String? {
        guard showErrors else { return nil }
        return Validation.isValidEmail(email) ? nil : "Enter a valid email address."
    }

    private var passwordError: String? {
        guard showErrors else { return nil }
        return password.isEmpty ? "Enter your password." : nil
    }

    var body: some View {
        FormScreen {
            AuthHeader(
                title: "Welcome back",
                subtitle: "Sign in to run your shop — schedule, customers, invoices and payments in one place."
            )

            VStack(spacing: Theme.Spacing.lg) {
                // Why the app signed the user out (an expired session).
                if let notice = appState.signInNotice, errorMessage == nil {
                    InlineMessage(text: notice, kind: .info)
                }
                ThemedTextField(label: "Email", placeholder: "you@yourshop.com", text: $email,
                                kind: .email, error: emailError)
                ThemedTextField(label: "Password", placeholder: "Password", text: $password,
                                kind: .password, error: passwordError)
                if let errorMessage {
                    InlineMessage(text: errorMessage, kind: .error)
                }
                AsyncButton("Sign in") {
                    await signIn()
                }
                HStack {
                    Button("Forgot password?") {
                        path.append(.forgotPassword(prefilledEmail: email))
                    }
                    .buttonStyle(.themePlain)
                    .fixedSize()
                    Spacer()
                }
            }

            VStack(spacing: Theme.Spacing.sm) {
                Text("New to Detail CRM?")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Button("Create an account") {
                    path.append(.signUp)
                }
                .buttonStyle(.themeSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.sm)

            LegalLinksFooter(step: .signIn)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func signIn() async {
        showErrors = true
        errorMessage = nil
        guard Validation.isValidEmail(email), !password.isEmpty else { return }
        do {
            try await AuthService.signIn(email: email, password: password)
            // AppState's auth listener takes it from here.
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
