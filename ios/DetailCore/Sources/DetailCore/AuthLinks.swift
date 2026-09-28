//
//  AuthLinks.swift
//  DetailCore
//
//  Where the iPhone app's auth emails send people. The app has no URL
//  scheme, so its links open the web app (implicit flow: the session rides
//  in the URL fragment). The web accepts link tokens only on its callback
//  pages (web/src/lib/authUrlSession.ts): a sign-up confirmation must land
//  on /auth/callback (which names the account and signs in when the person
//  continues), a password reset on /reset-password. A link to the Site URL
//  root is scrubbed and refused there, leaving the person on the sign-in
//  page with no word that the email was confirmed.
//

import Foundation

public enum AuthLinks {

    /// Web path that accepts sign-up confirmation links.
    public static let signUpCallbackPath = "auth/callback"
    /// Web path that accepts password-reset links.
    public static let passwordResetPath = "reset-password"

    /// `redirectTo` for a sign-up from the app, or nil when the build has
    /// no web app URL (Supabase then uses the Site URL).
    public static func signUpConfirmation(webAppBase: URL?) -> URL? {
        webAppBase.map { page(signUpCallbackPath, on: $0) }
    }

    /// `redirectTo` for a password-reset email from the app.
    public static func passwordReset(webAppBase: URL?) -> URL? {
        webAppBase.map { page(passwordResetPath, on: $0) }
    }

    private static func page(_ path: String, on base: URL) -> URL {
        var url = base
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }
}
