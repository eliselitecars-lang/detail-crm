//
//  OpsReferralCodeRow.swift
//  DetailCRM
//
//  The customer's referral link (P-29), shown to owners, admins and
//  managers while the shop's referral program is on. Friends who book with
//  the link get the shop's new-customer discount; the customer earns store
//  credit once a friend's first job is completed. The code (and its coupon)
//  is created on the server the first time someone asks for the link. The
//  program's discount and reward are set up in the web app.
//

import SwiftUI
import UIKit
import DetailCore

struct OpsReferralCodeRow: View {
    let customer: Customer

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var code: OpsReferralService.Code?
    @State private var errorMessage: String?

    /// Shown by the customer screen only while the program is on.
    var body: some View {
        CustomersSectionCard("Referral link") {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if customer.isArchived {
                Text("Archived customers can't refer friends. Restore the customer to share a link.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Friends who book with this link get your new-customer discount, and \(customer.firstName?.trimmedNonEmpty ?? "this customer") earns store credit when a friend's first job is done.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let shownCode = code?.code ?? customer.referralCode?.trimmedNonEmpty {
                    HStack {
                        Text("Code")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: Theme.Spacing.sm)
                        Text(shownCode)
                            .font(Theme.Typography.bodyEmphasis.monospaced())
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let errorMessage {
                    InlineMessage(text: errorMessage, kind: .error)
                }
                if let code {
                    actions(for: code)
                } else {
                    AsyncButton(style: .themeSecondaryCompact) {
                        await fetchCode()
                    } label: {
                        Label(customer.referralCode == nil ? "Create referral link" : "Get referral link",
                              systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(for code: OpsReferralService.Code) -> some View {
        if let url = code.url {
            Text(url.absoluteString)
                .font(Theme.Typography.footnote.monospaced())
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            AdaptiveButtonRow(spacing: Theme.Spacing.sm) {
                ShareLink(
                    item: url,
                    message: Text("Book with \(appState.shop?.name ?? "us") using my link and get a discount on your first visit.")
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.themeSecondaryCompact)
                Button {
                    UIPasteboard.general.url = url
                    toasts.show("Referral link copied")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.themeSecondaryCompact)
            }
        } else {
            InlineMessage(
                text: "The code works when entered at booking, but the link can't be built until the shop's web address is set on the server.",
                kind: .info
            )
            Button {
                UIPasteboard.general.string = code.code
                toasts.show("Referral code copied")
            } label: {
                Label("Copy code", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.themeSecondaryCompact)
        }
    }

    private func fetchCode() async {
        errorMessage = nil
        do {
            code = try await OpsReferralService.code(customerID: customer.id)
        } catch {
            errorMessage = ErrorText.message(for: error)
        }
    }
}
