//
//  LegalLinksFooter.swift
//  DetailCRM
//
//  The Privacy Policy and Terms of Service: the operator's public pages on
//  the web app (`WEB_APP_URL` + `/privacy` and `/terms`, no sign-in),
//  opened in the browser. The Terms count creating an account, joining a
//  shop's team or using the service as acceptance, so the links sit under
//  every step that does one of those — Create account, Sign in, the shop
//  picker, Create shop, Join a team — with the sentence that says so
//  (DetailCore `LegalNotice`), as under the web sign-in and sign-up pages.
//  Your account (Settings) lists them too (SettingsLegalSection).
//

import SwiftUI
import DetailCore

/// The legal pages on the web app; nil until WEB_APP_URL is configured.
enum LegalWebLinks {
    static var privacyPolicy: URL? {
        LegalNotice.privacyPolicy(webAppBase: AppConfig.webAppURL)
    }

    static var termsOfService: URL? {
        LegalNotice.termsOfService(webAppBase: AppConfig.webAppURL)
    }
}

/// "By creating an account, you agree to the Terms of Service…" with the
/// two links, centred under a form.
struct LegalLinksFooter: View {
    let step: LegalNotice.Step

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text(LegalNotice.sentence(for: step))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let privacy = LegalWebLinks.privacyPolicy, let terms = LegalWebLinks.termsOfService {
                AdaptiveButtonRow(spacing: Theme.Spacing.lg) {
                    LegalFooterLink(title: "Terms of Service", url: terms)
                    LegalFooterLink(title: "Privacy Policy", url: privacy)
                }
            } else {
                Text("The Terms of Service and Privacy Policy are on the web app.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.sm)
    }
}

/// A text link that opens in the browser (44 pt tall tap area).
private struct LegalFooterLink: View {
    let title: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            Text(title)
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.glacier)
                .underline()
                .frame(minHeight: Theme.Size.controlHeight)
                .contentShape(Rectangle())
        }
        .accessibilityHint("Opens in your browser")
    }
}
