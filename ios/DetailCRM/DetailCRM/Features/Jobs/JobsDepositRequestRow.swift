//
//  JobsDepositRequestRow.swift
//  DetailCRM
//
//  Asking for a deposit that is due (managers+, the web MoneyCard's
//  DepositRequest): the customer pays it on their booking page
//  (`WEB_APP_URL/booking/<token>`, token from `job_booking_token`). Staff
//  send the shop's "Booking confirmed" message, which carries the link
//  (`{{booking_link}}`), as a text or email, or copy the link. The server
//  re-checks the role and the customer's consent for the channel; a
//  per-attempt nonce keeps a retried send from going out twice.
//

import SwiftUI
import UIKit
import DetailCore

struct JobsDepositRequestRow: View {
    let jobID: UUID
    /// Who the message goes to (nil when the customer isn't readable).
    let customer: JobCustomer?

    @Environment(AppState.self) private var appState
    @Environment(ToastCenter.self) private var toasts
    @State private var copiedLink: URL?
    @State private var confirmation: ConfirmationRequest?
    @State private var attempt = RequestAttempt()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label("Ask for the deposit", systemImage: "paperplane")
                .font(Theme.Typography.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("The customer pays the deposit on their booking page. Send or copy the link.")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            AdaptiveButtonRow(spacing: Theme.Spacing.sm) {
                if !channels.isEmpty {
                    sendMenu
                }
                AsyncButton(style: .themeSecondaryCompact) {
                    await copyLink()
                } label: {
                    Label("Copy booking link", systemImage: "doc.on.doc")
                }
            }
            if channels.isEmpty {
                Text("Add a phone number or email to the customer to send the link from here.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let copiedLink {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(copiedLink.absoluteString)
                        .font(Theme.Typography.footnote.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    ShareLink(item: copiedLink) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.themeSecondaryCompact)
                }
            }
        }
        .confirmation($confirmation)
    }

    private var channels: [BookingLink.Channel] {
        BookingLink.channels(
            hasPhone: customer?.phone?.trimmedNonEmpty != nil,
            hasEmail: customer?.email?.trimmedNonEmpty != nil
        )
    }

    private var sendMenu: some View {
        Menu {
            ForEach(channels, id: \.self) { channel in
                Button {
                    confirmSend(channel)
                } label: {
                    Label(channel.actionTitle, systemImage: channel == .sms ? "message" : "envelope")
                }
            }
        } label: {
            Label("Text or email booking link", systemImage: "paperplane")
        }
        .buttonStyle(.themeSecondaryCompact)
        .accessibilityLabel("Send the booking link to the customer")
    }

    private func confirmSend(_ channel: BookingLink.Channel) {
        let name: String = customer?.displayName ?? "the customer"
        let destination: String? = (channel == .sms ? customer?.phone : customer?.email)?.trimmedNonEmpty
        var recipient = name
        if let destination {
            recipient += " (\(destination))"
        }
        confirmation = ConfirmationRequest(
            title: channel == .sms ? "Text the booking link?" : "Email the booking link?",
            message: "Sends your shop's \"Booking confirmed\" message with the link to \(recipient).",
            confirmTitle: channel == .sms ? "Text link" : "Email link"
        ) {
            await send(channel)
        }
    }

    private func send(_ channel: BookingLink.Channel) async {
        do {
            let shopID = try appState.requireShopID()
            let result = try await JobService.sendBookingLink(
                shopID: shopID,
                jobID: jobID,
                channel: channel == .sms ? .sms : .email,
                nonce: attempt.nonce
            )
            attempt.succeeded()
            if result.didFail {
                toasts.show(
                    "The message could not be delivered" + (result.error.map { ": \($0)" } ?? "."),
                    style: .error,
                    duration: .seconds(6)
                )
            } else {
                toasts.show(channel.sentText)
            }
        } catch let edgeError as EdgeFunctionError {
            attempt.failed(status: edgeError.status)
            toasts.showError(edgeError)
        } catch {
            toasts.showError(error)
        }
    }

    private func copyLink() async {
        do {
            let url = try await JobService.bookingLink(jobID: jobID)
            UIPasteboard.general.url = url
            copiedLink = url
            toasts.show("Booking link copied. The customer can pay the deposit there.")
        } catch {
            toasts.showError(error)
        }
    }
}
