//
//  AuthFlowView.swift
//  DetailCRM
//
//  Signed-out navigation: Sign in (root) -> Create account / Forgot password.
//

import SwiftUI

enum AuthRoute: Hashable {
    case signUp
    case forgotPassword(prefilledEmail: String)
}

struct AuthFlowView: View {
    @State private var path: [AuthRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            SignInView(path: $path)
                .navigationDestination(for: AuthRoute.self) { route in
                    switch route {
                    case .signUp:
                        SignUpView()
                    case .forgotPassword(let email):
                        ForgotPasswordView(initialEmail: email)
                    }
                }
        }
    }
}

/// Shared header for the auth screens.
struct AuthHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            BrandMark(size: 52)
            Text(title)
                .font(Theme.Typography.largeTitle)
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
