//
//  LegalNotice.swift
//  DetailCore
//
//  The Privacy Policy and Terms of Service live on the web app
//  (`<web app>/privacy`, `<web app>/terms`, no sign-in). The Terms count
//  creating an account, joining a shop's team or using the service as
//  acceptance, so the app shows both links wherever a person takes one of
//  those steps (Create account, Sign in, the shop picker, Create shop,
//  Join a team) with the sentence that says what the step means.
//

import Foundation

public enum LegalNotice {

    /// Web path of the Privacy Policy.
    public static let privacyPath = "/privacy"
    /// Web path of the Terms of Service.
    public static let termsPath = "/terms"

    /// The step the person is about to take.
    public enum Step: Sendable {
        case createAccount
        case signIn
        case createShop
        case joinShop
        /// The shop picker: create a shop or join a team.
        case createOrJoinShop
    }

    /// The sentence shown next to the links.
    public static func sentence(for step: Step) -> String {
        switch step {
        case .createAccount:
            return "By creating an account, you agree to the Terms of Service. The Privacy Policy explains how your data is handled."
        case .signIn:
            return "By signing in, you agree to the Terms of Service. The Privacy Policy explains how your data is handled."
        case .createShop:
            return "By creating a shop, you agree to the Terms of Service for you and your shop. The Privacy Policy explains how your shop's data is handled."
        case .joinShop:
            return "By joining a team, you agree to the Terms of Service. The Privacy Policy explains how your data is handled."
        case .createOrJoinShop:
            return "By creating a shop or joining a team, you agree to the Terms of Service. The Privacy Policy explains how your data is handled."
        }
    }

    /// `path` on the web app at `base` (a base path such as `/app` is
    /// kept; its query and fragment are dropped). Nil without a web app URL.
    public static func page(_ path: String, on base: URL?) -> URL? {
        guard let base, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    public static func privacyPolicy(webAppBase: URL?) -> URL? {
        page(privacyPath, on: webAppBase)
    }

    public static func termsOfService(webAppBase: URL?) -> URL? {
        page(termsPath, on: webAppBase)
    }
}
