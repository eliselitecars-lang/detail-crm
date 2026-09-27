//
//  AuthService.swift
//  DetailCRM
//
//  Email/password authentication. Sign-up metadata `full_name` is copied
//  into `profiles` by the `handle_new_auth_user` trigger.
//

import Foundation
import Supabase

enum AuthService {

    /// Outcome of a sign-up: either signed in right away, or the project
    /// requires email confirmation first.
    enum SignUpOutcome: Equatable {
        case signedIn
        case confirmationRequired(email: String)
    }

    static func signIn(email: String, password: String) async throws {
        try await Supa.client.auth.signIn(
            email: normalized(email),
            password: password
        )
    }

    static func signUp(fullName: String, email: String, password: String) async throws -> SignUpOutcome {
        let address = normalized(email)
        let response = try await Supa.client.auth.signUp(
            email: address,
            password: password,
            data: ["full_name": .string(fullName.trimmingCharacters(in: .whitespacesAndNewlines))]
        )
        switch response {
        case .session:
            return .signedIn
        case .user:
            return .confirmationRequired(email: address)
        }
    }

    /// Emails a password-reset link. The link opens the web app's
    /// `/reset-password` page (configured as the project's redirect URL).
    static func sendPasswordReset(email: String) async throws {
        if let base = AppConfig.webAppURL {
            try await Supa.client.auth.resetPasswordForEmail(
                normalized(email),
                redirectTo: base.appendingPathComponent("reset-password")
            )
        } else {
            try await Supa.client.auth.resetPasswordForEmail(normalized(email))
        }
    }

    static func signOut() async throws {
        try await Supa.client.auth.signOut()
    }

    /// The signed-in user's email address, if any.
    static var currentEmail: String? {
        Supa.client.auth.currentUser?.email
    }

    private static func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
