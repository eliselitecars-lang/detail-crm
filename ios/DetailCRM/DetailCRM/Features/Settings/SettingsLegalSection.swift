//
//  SettingsLegalSection.swift
//  DetailCRM
//
//  "Privacy Policy" and "Terms of Service": the operator's public pages on
//  the web app (`WEB_APP_URL` + `/privacy` and `/terms`, no sign-in), opened
//  in the browser. Shown on Your account, which every role reaches from the
//  More tab; before that, sign-up, sign-in, the shop picker, Create shop
//  and Join a team show them with LegalLinksFooter (same `LegalWebLinks`).
//

import SwiftUI

struct SettingsLegalSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "Legal")
            if let privacy = LegalWebLinks.privacyPolicy, let terms = LegalWebLinks.termsOfService {
                VStack(spacing: 0) {
                    LegalLinkRow(title: "Privacy Policy", systemImage: "hand.raised", url: privacy)
                    Divider()
                        .overlay(Theme.border)
                        .padding(.leading, Theme.Spacing.lg)
                    LegalLinkRow(title: "Terms of Service", systemImage: "doc.text", url: terms)
                }
                .cardStyle(padding: 0)
            } else {
                Text("The Privacy Policy and Terms of Service are on the web app.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One row that opens a web page in the browser.
private struct LegalLinkRow: View {
    let title: String
    let systemImage: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: systemImage)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.glacier)
                    .frame(width: Theme.Size.rowIcon)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: Theme.Spacing.sm)
                Image(systemName: "arrow.up.right")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(minHeight: Theme.Size.controlHeight)
            .contentShape(Rectangle())
        }
        .accessibilityHint("Opens in your browser")
    }
}
